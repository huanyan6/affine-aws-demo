#!/bin/bash
# =============================================================================
# 05-teardown.sh  (v2.1)
# Destroys ALL AWS resources created by this demo to avoid charges.
# Run from your local machine. Prompts for confirmation before deleting.
# Safe to run even if the deployment was only partially completed.
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../config/bootstrap-outputs.env"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; exit 1; }
source "$ENV_FILE"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
skip()  { echo -e "\033[1;33m[SKIP]\033[0m $* (not found in env — already deleted or never created)"; }

# Default all variables to empty so missing ones don't crash the script
INSTANCE_ID="${INSTANCE_ID:-}"
EIP_ALLOC="${EIP_ALLOC:-}"
EIP="${EIP:-}"
SG_ID="${SG_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
VPC_ID="${VPC_ID:-}"
IGW_ID="${IGW_ID:-}"
KEY_NAME="${KEY_NAME:-}"
KEY_FILE="${KEY_FILE:-}"
S3_BUCKET="${S3_BUCKET:-}"
IAM_USER="${IAM_USER:-}"
IAM_GROUP="${IAM_GROUP:-}"
POLICY_ARN="${POLICY_ARN:-}"
REGION="${REGION:-ap-southeast-2}"
PROJECT="${PROJECT:-affine-demo}"

echo ""
echo "========================================================"
echo " AFFiNE Demo — TEARDOWN"
echo " This will permanently delete:"
echo "   EC2 instance: ${INSTANCE_ID:-(not recorded)}"
echo "   Elastic IP:   ${EIP:-(not recorded)}"
echo "   S3 bucket:    ${S3_BUCKET:-(not recorded)}"
echo "   VPC:          ${VPC_ID:-(not recorded)}"
echo "   IAM:          user ${IAM_USER:-(not recorded)}, group, policy"
echo "   Key pair:     ${KEY_NAME:-(not recorded)}"
echo "========================================================"
echo ""
read -p "Type 'yes' to confirm teardown: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }

# ── EC2 ───────────────────────────────────────────────────────────────────────
if [ -n "$INSTANCE_ID" ]; then
  info "Terminating EC2 instance $INSTANCE_ID..."
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  ok "EC2 terminated"
else
  skip "EC2 instance"
fi

# ── Elastic IP ────────────────────────────────────────────────────────────────
if [ -n "$EIP_ALLOC" ]; then
  info "Releasing Elastic IP $EIP_ALLOC..."
  aws ec2 release-address --allocation-id "$EIP_ALLOC" --region "$REGION" 2>/dev/null || \
    warn "Elastic IP may already be released"
  ok "Elastic IP released"
else
  skip "Elastic IP"
fi

# ── Security Group ────────────────────────────────────────────────────────────
if [ -n "$SG_ID" ]; then
  info "Deleting security group $SG_ID..."
  aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || \
    warn "Security group may already be deleted"
  ok "Security group deleted"
else
  skip "Security group"
fi

# ── Subnet ────────────────────────────────────────────────────────────────────
if [ -n "$SUBNET_ID" ]; then
  info "Deleting subnet $SUBNET_ID..."
  aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$REGION" 2>/dev/null || \
    warn "Subnet may already be deleted"
  ok "Subnet deleted"
else
  skip "Subnet"
fi

# ── Route Table ───────────────────────────────────────────────────────────────
if [ -n "$VPC_ID" ]; then
  info "Deleting route table..."
  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT}-rt" \
    --query 'RouteTables[0].RouteTableId' --output text --region "$REGION" 2>/dev/null || echo "None")
  if [ -n "$RT_ID" ] && [ "$RT_ID" != "None" ]; then
    aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$REGION" 2>/dev/null || true
    ok "Route table deleted"
  else
    warn "Route table not found — skipping"
  fi
fi

# ── Internet Gateway ──────────────────────────────────────────────────────────
if [ -n "$VPC_ID" ]; then
  info "Detaching and deleting Internet Gateway..."
  FOUND_IGW=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION" 2>/dev/null || echo "None")
  if [ -n "$FOUND_IGW" ] && [ "$FOUND_IGW" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$FOUND_IGW" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$FOUND_IGW" --region "$REGION" 2>/dev/null || true
    ok "Internet Gateway deleted"
  else
    warn "Internet Gateway not found — skipping"
  fi
fi

# ── VPC ───────────────────────────────────────────────────────────────────────
if [ -n "$VPC_ID" ]; then
  info "Deleting VPC $VPC_ID..."
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null || \
    warn "VPC may already be deleted"
  ok "VPC deleted"
else
  skip "VPC"
fi

# ── Key Pair ──────────────────────────────────────────────────────────────────
if [ -n "$KEY_NAME" ]; then
  info "Deleting key pair $KEY_NAME..."
  aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>/dev/null || true
  ok "Key pair deleted"
else
  skip "Key pair"
fi

# ── S3 ────────────────────────────────────────────────────────────────────────
if [ -n "$S3_BUCKET" ]; then
  info "Emptying and deleting S3 bucket $S3_BUCKET..."
  aws s3 rm "s3://$S3_BUCKET" --recursive 2>/dev/null || true
  aws s3api delete-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null || \
    warn "S3 bucket may already be deleted"
  ok "S3 bucket deleted"
else
  skip "S3 bucket"
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
info "Cleaning up IAM..."
if [ -n "$IAM_USER" ]; then
  KEYS=$(aws iam list-access-keys --user-name "$IAM_USER" \
    --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || echo "")
  for k in $KEYS; do
    aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k" 2>/dev/null || true
  done
  aws iam remove-user-from-group --user-name "$IAM_USER" --group-name "${IAM_GROUP:-}" 2>/dev/null || true
  aws iam delete-user --user-name "$IAM_USER" 2>/dev/null || true
fi
[ -n "$IAM_GROUP" ]  && { aws iam detach-group-policy --group-name "$IAM_GROUP" --policy-arn "${POLICY_ARN:-dummy}" 2>/dev/null || true; aws iam delete-group --group-name "$IAM_GROUP" 2>/dev/null || true; }
[ -n "$POLICY_ARN" ] && { aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true; }
ok "IAM resources deleted"

info "================================================================"
info "Teardown complete. All AWS resources have been removed."
[ -n "$KEY_FILE" ] && info "Your local key file remains at: $KEY_FILE"
info "================================================================"
