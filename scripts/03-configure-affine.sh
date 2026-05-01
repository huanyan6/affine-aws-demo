#!/bin/bash
# =============================================================================
# 03-configure-affine.sh  (v2.1)
# Run this LOCALLY after 02-launch-ec2.sh.
# Automatically waits for the EC2 user-data to finish, SCPs config
# files via the home directory (avoids permission issues), then
# configures and starts AFFiNE over SSH.
#
# Usage:
#   ./scripts/03-configure-affine.sh [--domain yourdomain.com]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/bootstrap-outputs.env"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# ── Parse args ────────────────────────────────────────────────────────────────
DOMAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

AFFINE_DIR="/opt/affine"
EC2_USER="${EC2_USER:-ec2-user}"
# LogLevel=ERROR suppresses SSH client warnings (e.g. post-quantum key exchange noise)
SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"
REMOTE="${EC2_USER}@${EIP}"
PUBLIC_HOST="${DOMAIN:-$EIP}"
PROTOCOL="https"

[ -z "$DOMAIN" ] && warn "No domain provided — will use IP with a self-signed cert (browser will warn)"

# ── 1. Wait for SSH ───────────────────────────────────────────────────────────
info "Waiting for SSH on $EIP to become available..."
for i in $(seq 1 30); do
  if ssh $SSH_OPTS "$REMOTE" "echo ready" &>/dev/null; then
    ok "SSH is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: SSH not available after 5 minutes. Check security group and instance state." >&2
    exit 1
  fi
  echo "  Attempt $i/30 — not ready yet, retrying in 10s..."
  sleep 10
done

# ── 2. Wait for user-data (Docker/Nginx install) to complete ──────────────────
info "Waiting for EC2 user-data setup to complete (installs Docker, Nginx)..."
for i in $(seq 1 60); do
  # Use sudo — the log is owned by root (user-data runs as root)
  if ssh $SSH_OPTS "$REMOTE" "sudo grep -q 'AFFiNE setup complete' /var/log/affine-setup.log 2>/dev/null"; then
    ok "User-data complete"
    break
  fi
  if [ "$i" -eq 60 ]; then
    # Show last log lines to help diagnose failures
    echo ""
    warn "User-data did not finish in 10 minutes. Last log lines:"
    ssh $SSH_OPTS "$REMOTE" "sudo tail -20 /var/log/affine-setup.log 2>/dev/null || echo '(log not found)'"
    echo ""
    read -rp "Continue anyway? [y/N]: " CONT
    [ "${CONT,,}" = "y" ] || { echo "Aborted."; exit 1; }
    break
  fi
  LAST=$(ssh $SSH_OPTS "$REMOTE" "sudo tail -1 /var/log/affine-setup.log 2>/dev/null || echo '(waiting for log...)'")
  echo "  Attempt $i/60 — $LAST"
  sleep 10
done

# ── 3. Generate secrets locally ───────────────────────────────────────────────
POSTGRES_PASSWORD=$(openssl rand -hex 24)
AFFINE_SECRET=$(openssl rand -hex 32)

# ── 4. SCP bootstrap-outputs.env to home dir, then move to /opt/affine ───────
info "Copying bootstrap config to EC2..."
scp -i "$KEY_FILE" -o StrictHostKeyChecking=no \
  "$SCRIPT_DIR/../config/bootstrap-outputs.env" \
  "${REMOTE}:~/bootstrap-outputs.env"
ssh $SSH_OPTS "$REMOTE" "sudo mv ~/bootstrap-outputs.env $AFFINE_DIR/ && sudo chmod 600 $AFFINE_DIR/bootstrap-outputs.env && sudo chown ${EC2_USER}:${EC2_USER} $AFFINE_DIR/bootstrap-outputs.env"
ok "Config copied to $AFFINE_DIR"

# ── 5. Generate and push all config files via SSH ─────────────────────────────
info "Writing .env on EC2..."
ssh $SSH_OPTS "$REMOTE" "cat > ~/affine.env" <<EOF
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
ssh $SSH_OPTS "$REMOTE" "sudo mv ~/affine.env $AFFINE_DIR/.env && sudo chmod 600 $AFFINE_DIR/.env && sudo chown ${EC2_USER}:${EC2_USER} $AFFINE_DIR/.env"
ok ".env written"

info "Writing docker-compose.yml on EC2..."
ssh $SSH_OPTS "$REMOTE" 'cat > ~/docker-compose.yml' <<'COMPOSE'
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
COMPOSE
ssh $SSH_OPTS "$REMOTE" "sudo mv ~/docker-compose.yml $AFFINE_DIR/docker-compose.yml && sudo chown ${EC2_USER}:${EC2_USER} $AFFINE_DIR/docker-compose.yml"
ok "docker-compose.yml written"

# ── 6. Nginx + TLS setup on EC2 ───────────────────────────────────────────────
info "Configuring Nginx on EC2..."
SERVER_NAME="${DOMAIN:-_}"
ssh $SSH_OPTS "$REMOTE" "sudo bash -s" <<NGINX
set -e
mkdir -p /etc/nginx/conf.d /etc/nginx/ssl

cat > /tmp/affine.conf <<'NGINXCONF'
server {
    listen 80;
    server_name ${SERVER_NAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${SERVER_NAME};

    ssl_certificate     /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;

    client_max_body_size 100M;

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
NGINXCONF
mv /tmp/affine.conf /etc/nginx/conf.d/affine.conf

if [ ! -f /etc/nginx/ssl/cert.pem ]; then
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/key.pem \
    -out /etc/nginx/ssl/cert.pem \
    -subj "/CN=${PUBLIC_HOST}/O=AFFiNEDemo/C=AU"
fi

systemctl enable nginx
systemctl restart nginx
NGINX
ok "Nginx configured and started"

# ── Certbot (only if domain provided) ─────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
  info "Obtaining Let's Encrypt certificate for $DOMAIN..."
  ssh $SSH_OPTS "$REMOTE" "sudo certbot --nginx -d '$DOMAIN' --non-interactive --agree-tos \
    --register-unsafely-without-email --redirect" || \
    warn "Certbot failed — check DNS points to $EIP. Self-signed cert is still active."
fi

# ── 7. Start AFFiNE stack ─────────────────────────────────────────────────────
info "Pulling Docker images and starting AFFiNE stack..."
ssh $SSH_OPTS "$REMOTE" "cd $AFFINE_DIR && docker compose pull && docker compose up -d"

info "Waiting for AFFiNE to become healthy (up to 3 min)..."
for i in $(seq 1 36); do
  STATUS=$(ssh $SSH_OPTS "$REMOTE" "docker inspect --format='{{.State.Health.Status}}' affine_server 2>/dev/null || echo starting")
  if [ "$STATUS" = "healthy" ]; then
    ok "AFFiNE is healthy!"
    break
  fi
  if [ "$i" -eq 36 ]; then
    warn "AFFiNE did not reach healthy state in 3 min — check logs: ssh ... 'docker compose -f $AFFINE_DIR/docker-compose.yml logs affine'"
    break
  fi
  echo "  Attempt $i/36 — status: $STATUS. Waiting 5s..."
  sleep 5
done

# ── 8. Enable pgvector ────────────────────────────────────────────────────────
info "Enabling pgvector extension in PostgreSQL..."
sleep 5
ssh $SSH_OPTS "$REMOTE" \
  "docker exec affine_postgres psql -U affine -d affine -c 'CREATE EXTENSION IF NOT EXISTS vector;'" \
  2>/dev/null || warn "pgvector may already exist — that's fine"
ok "pgvector enabled"

# ── 9. Print access info ──────────────────────────────────────────────────────
info "================================================================"
info "AFFiNE is running!"
info ""
info "  Access URL : ${PROTOCOL}://${PUBLIC_HOST}"
[ -z "$DOMAIN" ] && warn "  Browser will warn about self-signed cert — click 'Advanced > Proceed'"
info ""
info "  SSH access : ssh -i $KEY_FILE ${EC2_USER}@${EIP}"
info ""
info "  Useful commands (run via SSH):"
info "    docker compose -f $AFFINE_DIR/docker-compose.yml ps"
info "    docker compose -f $AFFINE_DIR/docker-compose.yml logs -f affine"
info "================================================================"
