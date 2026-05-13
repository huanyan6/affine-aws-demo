#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/affine-setup.log) 2>&1
echo "=== AFFiNE setup started: $(date) ==="

# 1. System packages
dnf update -y
# curl-minimal is pre-installed on AL2023; installing full curl would conflict
dnf install -y git wget unzip python3-pip docker nginx

# 2. Docker
systemctl enable --now docker
usermod -aG docker ${ec2_user}

# 3. Docker Compose v2
mkdir -p /usr/local/lib/docker/cli-plugins
curl -sSL \
  "https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

# 4. Certbot
pip3 install certbot certbot-nginx

# 5. AFFiNE directories
AFFINE_DIR="${affine_dir}"
mkdir -p "$AFFINE_DIR/storage" "$AFFINE_DIR/config" "$AFFINE_DIR/db"
chown -R ${ec2_user}:${ec2_user} "$AFFINE_DIR"

# 6. .env — all values substituted by Terraform at apply time
cat > "$AFFINE_DIR/.env" <<'ENVEOF'
AFFINE_REVISION=${affine_revision}
PORT=3010
UPLOAD_LOCATION=${affine_dir}/storage
CONFIG_LOCATION=${affine_dir}/config
DB_DATA_LOCATION=${affine_dir}/db
DB_USERNAME=affine
DB_PASSWORD=${postgres_password}
DB_DATABASE=affine
NODE_ENV=production
AFFINE_SERVER_HTTPS=true
AFFINE_SERVER_HOST=0.0.0.0
AFFINE_SERVER_EXTERNAL_URL=https://${public_host}
AFFINE_SECRET=${affine_secret}
STORAGE_PROVIDER=aws-s3
AWS_S3_BUCKET=${s3_bucket}
AWS_S3_REGION=${s3_region}
AWS_ACCESS_KEY_ID=${aws_access_key}
AWS_SECRET_ACCESS_KEY=${aws_secret_key}
TELEMETRY_ENABLE=false
AFFINE_INDEXER_ENABLED=false
ENVEOF
chmod 600 "$AFFINE_DIR/.env"
chown ${ec2_user}:${ec2_user} "$AFFINE_DIR/.env"

# 7. docker-compose.yml — values hardcoded from Terraform to avoid docker-compose variable escaping
cat > "$AFFINE_DIR/docker-compose.yml" <<'COMPOSEEOF'
name: affine

services:
  affine:
    image: ghcr.io/toeverything/affine:${affine_revision}
    container_name: affine_server
    restart: unless-stopped
    ports:
      - "3010:3010"
    depends_on:
      redis:
        condition: service_healthy
      postgres:
        condition: service_healthy
      affine_migration:
        condition: service_completed_successfully
    volumes:
      - ${affine_dir}/storage:/root/.affine/storage
      - ${affine_dir}/config:/root/.affine/config
    env_file:
      - ${affine_dir}/.env
    environment:
      - REDIS_SERVER_HOST=redis
      - DATABASE_URL=postgresql://affine:${postgres_password}@postgres:5432/affine
      - AFFINE_INDEXER_ENABLED=false

  affine_migration:
    image: ghcr.io/toeverything/affine:${affine_revision}
    container_name: affine_migration_job
    volumes:
      - ${affine_dir}/storage:/root/.affine/storage
      - ${affine_dir}/config:/root/.affine/config
    command: ['sh', '-c', 'node ./scripts/self-host-predeploy.js']
    env_file:
      - ${affine_dir}/.env
    environment:
      - REDIS_SERVER_HOST=redis
      - DATABASE_URL=postgresql://affine:${postgres_password}@postgres:5432/affine
      - AFFINE_INDEXER_ENABLED=false
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: pgvector/pgvector:pg16
    container_name: affine_postgres
    restart: unless-stopped
    volumes:
      - ${affine_dir}/db:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: affine
      POSTGRES_PASSWORD: "${postgres_password}"
      POSTGRES_DB: affine
      POSTGRES_INITDB_ARGS: '--data-checksums'
      POSTGRES_HOST_AUTH_METHOD: trust
    healthcheck:
      test: ['CMD', 'pg_isready', '-U', 'affine', '-d', 'affine']
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis
    container_name: affine_redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    healthcheck:
      test: ['CMD', 'redis-cli', '--raw', 'incr', 'ping']
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  redis_data:
COMPOSEEOF
chown ${ec2_user}:${ec2_user} "$AFFINE_DIR/docker-compose.yml"

# 8. Nginx — self-signed cert first, replaced by certbot if domain is provided
mkdir -p /etc/nginx/conf.d /etc/nginx/ssl

cat > /etc/nginx/conf.d/affine.conf <<NGINXEOF
server {
    listen 80;
    server_name ${nginx_server_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${nginx_server_name};

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
NGINXEOF

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/key.pem \
    -out /etc/nginx/ssl/cert.pem \
    -subj "/CN=${public_host}/O=AFFiNEDemo/C=AU"

systemctl enable nginx
systemctl restart nginx

%{ if affine_domain != "" ~}
# Replace self-signed cert with Let's Encrypt certificate
certbot --nginx -d "${affine_domain}" \
    --non-interactive --agree-tos \
    --register-unsafely-without-email \
    --redirect \
  || echo "Certbot failed — DNS may not point to this IP yet; self-signed cert still active"
%{ endif ~}

# 9. Pull images and start AFFiNE stack
cd "$AFFINE_DIR"
docker compose pull
docker compose up -d

# 10. Wait for AFFiNE to respond on port 3010
echo "Waiting for AFFiNE on port 3010 (migration + startup takes 3-5 min)..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:3010/info -o /dev/null 2>/dev/null; then
        echo "AFFiNE is up and responding!"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARNING: AFFiNE did not respond after 10 min — check: docker compose logs"
    fi
    echo "  Attempt $i/60 — waiting 10s..."
    sleep 10
done

echo "=== AFFiNE setup complete: $(date) ==="
