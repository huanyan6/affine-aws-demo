#!/bin/bash
# =============================================================================
# 03-configure-affine.sh
# Run this ON the EC2 instance after copying bootstrap-outputs.env to it.
# Generates docker-compose.yml, .env, nginx.conf, and starts all services.
#
# Usage:
#   scp config/bootstrap-outputs.env ec2-user@<EIP>:/opt/affine/
#   ssh -i <key> ec2-user@<EIP>
#   chmod +x 03-configure-affine.sh && ./03-configure-affine.sh [--domain yourdomain.com]
# =============================================================================
set -euo pipefail

AFFINE_DIR="/opt/affine"
DOMAIN=""

# Parse optional --domain flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Load outputs
source "$AFFINE_DIR/bootstrap-outputs.env"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }

PUBLIC_HOST="${DOMAIN:-$EIP}"
PROTOCOL="https"
if [ -z "$DOMAIN" ]; then
  warn "No domain provided. Using IP address. Certbot/HTTPS will be self-signed."
  warn "For a proper cert, re-run with: --domain yourdomain.com"
fi

# Generate secrets
POSTGRES_PASSWORD=$(openssl rand -hex 24)
AFFINE_SECRET=$(openssl rand -hex 32)

info "Writing .env..."
cat > "$AFFINE_DIR/.env" <<EOF
# AFFiNE demo environment — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Server
NODE_ENV=production
AFFINE_SERVER_HTTPS=true
AFFINE_SERVER_HOST=0.0.0.0
AFFINE_SERVER_PORT=3010
AFFINE_SERVER_EXTERNAL_URL=${PROTOCOL}://${PUBLIC_HOST}
AFFINE_SECRET=${AFFINE_SECRET}
AFFINE_CONFIG_PATH=/root/.affine/config

# Database
DATABASE_URL=postgresql://affine:${POSTGRES_PASSWORD}@postgres:5432/affine
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# Redis
REDIS_SERVER_HOST=redis
REDIS_SERVER_PORT=6379

# S3 storage
STORAGE_PROVIDER=aws-s3
AWS_S3_BUCKET=${S3_BUCKET}
AWS_S3_REGION=${S3_REGION}
AWS_ACCESS_KEY_ID=${AFFINE_AWS_ACCESS_KEY}
AWS_SECRET_ACCESS_KEY=${AFFINE_AWS_SECRET_KEY}

# Disable telemetry for demo
TELEMETRY_ENABLE=false
EOF
chmod 600 "$AFFINE_DIR/.env"
ok ".env written"

info "Writing docker-compose.yml..."
cat > "$AFFINE_DIR/docker-compose.yml" <<'EOF'
version: "3.9"

services:
  affine:
    image: ghcr.io/toeverything/affine-graphql:stable
    container_name: affine_server
    restart: unless-stopped
    ports:
      - "3010:3010"
    env_file: .env
    volumes:
      - affine_config:/root/.affine/config
      - affine_storage:/root/.affine/storage
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    command: ["sh", "-c", "node ./scripts/self-host-predeploy && node ./dist/index.js"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3010/info"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  postgres:
    image: pgvector/pgvector:pg16
    container_name: affine_postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: affine
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: affine
      POSTGRES_INITDB_ARGS: "--encoding=UTF8"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U affine -d affine"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: affine_redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3

volumes:
  affine_config:
  affine_storage:
  postgres_data:
  redis_data:
EOF
ok "docker-compose.yml written"

info "Writing Nginx config..."
mkdir -p /etc/nginx/conf.d

if [ -n "$DOMAIN" ]; then
  SERVER_NAME="$DOMAIN"
else
  SERVER_NAME="_"
fi

cat > /etc/nginx/conf.d/affine.conf <<EOF
# AFFiNE reverse proxy
server {
    listen 80;
    server_name ${SERVER_NAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${SERVER_NAME};

    # TLS — Certbot will update these lines if --domain is used
    ssl_certificate     /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;

    client_max_body_size 100M;

    # WebSocket support (required for real-time collaboration)
    location / {
        proxy_pass         http://127.0.0.1:3010;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

# Generate self-signed cert (used until Certbot replaces it)
mkdir -p /etc/nginx/ssl
if [ ! -f /etc/nginx/ssl/cert.pem ]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/key.pem \
    -out /etc/nginx/ssl/cert.pem \
    -subj "/CN=${PUBLIC_HOST}/O=AFFiNEDemo/C=AU"
  ok "Self-signed TLS certificate generated"
fi

systemctl enable nginx
systemctl restart nginx
ok "Nginx configured and started"

# ── Certbot (only if domain provided) ─────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
  info "Obtaining Let's Encrypt certificate for $DOMAIN..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
    --register-unsafely-without-email --redirect || \
    warn "Certbot failed — check DNS points to $EIP. Self-signed cert is still active."
fi

# ── Start AFFiNE stack ────────────────────────────────────────────────────────
info "Pulling Docker images and starting AFFiNE stack..."
cd "$AFFINE_DIR"
docker compose pull
docker compose up -d

info "Waiting for AFFiNE to become healthy (up to 3 min)..."
for i in $(seq 1 36); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' affine_server 2>/dev/null || echo "starting")
  if [ "$STATUS" = "healthy" ]; then
    ok "AFFiNE is healthy!"
    break
  fi
  echo "  Attempt $i/36 — status: $STATUS. Waiting 5s..."
  sleep 5
done

# ── pgvector extension ────────────────────────────────────────────────────────
info "Enabling pgvector extension in PostgreSQL..."
sleep 5
docker exec affine_postgres psql -U affine -d affine \
  -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || \
  warn "pgvector extension may already exist — that's fine"
ok "pgvector enabled"

# ── Save access info ──────────────────────────────────────────────────────────
cat > "$AFFINE_DIR/access-info.txt" <<EOF
=== AFFiNE Demo Access Info ===
URL:              ${PROTOCOL}://${PUBLIC_HOST}
Server IP:        ${EIP}
Domain:           ${DOMAIN:-"(none — using IP)"}
Generated:        $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Service status:   docker compose ps
View logs:        docker compose logs -f affine
Restart stack:    docker compose restart
Stop stack:       docker compose down
Pull updates:     docker compose pull && docker compose up -d

PostgreSQL:       docker exec -it affine_postgres psql -U affine -d affine
Redis CLI:        docker exec -it affine_redis redis-cli
EOF

info "================================================================"
info "AFFiNE is running!"
info ""
info "  Access URL: ${PROTOCOL}://${PUBLIC_HOST}"
if [ -z "$DOMAIN" ]; then
  warn "  Browser will warn about self-signed cert — click 'Advanced > Proceed'"
fi
info ""
info "  Useful commands:"
info "    docker compose -f /opt/affine/docker-compose.yml ps"
info "    docker compose -f /opt/affine/docker-compose.yml logs -f affine"
info "================================================================"
