#!/bin/bash
# =============================================================================
# 02-launch-ec2.sh  (v2.1)
# Launches a t2.micro EC2 instance (Free Tier) and injects a user-data script
# that automatically installs Docker, Docker Compose, Nginx, Certbot, and
# clones the AFFiNE docker-compose config on first boot.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/bootstrap-outputs.env"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }

# EC2_USER is set in bootstrap-outputs.env by 01-aws-bootstrap.sh
EC2_USER="${EC2_USER:-ec2-user}"
ok "Using EC2 OS username: $EC2_USER  (set during bootstrap)"

# ── AMI: Latest Amazon Linux 2023 ─────────────────────────────────────────────
info "Resolving latest Amazon Linux 2023 AMI in $REGION..."
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-2023*-x86_64" \
    "Name=state,Values=available" \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' \
  --output text \
  --region "$REGION")
ok "AMI: $AMI_ID"

# ── User-data (runs as root on first boot) ────────────────────────────────────
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/affine-setup.log) 2>&1
echo "=== AFFiNE demo setup started: $(date) ==="

# 1. System update
dnf update -y
# curl-minimal is pre-installed on AL2023 and conflicts with full curl — omit it
dnf install -y git wget unzip python3-pip

# 2. Docker
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker __EC2_USER__

# 3. Docker Compose v2
COMPOSE_VERSION="2.24.6"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -sSL \
  "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose

# 4. Nginx + Certbot
dnf install -y nginx
pip3 install certbot certbot-nginx

# 5. AFFiNE directory
mkdir -p /opt/affine
chown __EC2_USER__:__EC2_USER__ /opt/affine

echo "=== AFFiNE setup complete: $(date) ==="
echo "=== Next: SSH in and run 03-configure-affine.sh ==="
USERDATA
)

# Substitute the EC2 OS username into the user-data
USER_DATA="${USER_DATA//__EC2_USER__/$EC2_USER}"

# ── Launch instance ────────────────────────────────────────────────────────────
info "Launching EC2 t2.micro..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t2.micro \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --user-data "$USER_DATA" \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT}-server},{Key=Project,Value=${PROJECT}}]" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$REGION")
ok "Instance launched: $INSTANCE_ID"

# ── Wait for running ───────────────────────────────────────────────────────────
info "Waiting for instance to reach 'running' state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
ok "Instance is running"

# ── Associate Elastic IP ───────────────────────────────────────────────────────
info "Associating Elastic IP $EIP..."
aws ec2 associate-address \
  --instance-id "$INSTANCE_ID" \
  --allocation-id "$EIP_ALLOC" \
  --region "$REGION"
ok "Elastic IP associated: $EIP"

# ── Wait for status checks ─────────────────────────────────────────────────────
info "Waiting for instance status checks (may take 2-3 min)..."
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"
ok "Instance status checks passed"

# ── Append to outputs file ─────────────────────────────────────────────────────
cat >> "$SCRIPT_DIR/../config/bootstrap-outputs.env" <<EOF

# Added by 02-launch-ec2.sh
AMI_ID=$AMI_ID
INSTANCE_ID=$INSTANCE_ID
EOF

info "================================================================"
info "EC2 ready!  Public IP: $EIP"
info ""
info "Wait ~2 min for user-data to finish, then SSH:"
info "  ssh -i $KEY_FILE ${EC2_USER}@$EIP"
info ""
info "Next: copy config files and run 03-configure-affine.sh"
info "================================================================"
