#!/bin/bash
# =============================================================================
# 05-teardown.sh
# Destroys ALL AWS resources created by this demo to avoid charges.
# Run from your local machine. Prompts for confirmation before deleting.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../config/bootstrap-outputs.env"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found"; exit 1; }
source "$ENV_FILE"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }

echo ""
echo "========================================================"
echo " AFFiNE Demo — TEARDOWN"
echo " This will permanently delete:"
echo "   EC2 instance: $INSTANCE_ID"
echo "   Elastic IP:   $EIP"
echo "   S3 bucket:    $S3_BUCKET (ALL contents)"
echo "   VPC:          $VPC_ID (subnet, IGW, SG, route table)"
echo "   IAM:          user $IAM_USER, group $IAM_GROUP, policy"
echo "   Key pair:     $KEY_NAME"
echo "========================================================"
echo ""
read -p "Type 'yes' to confirm teardown: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }

# ── EC2 ───────────────────────────────────────────────────────────────────────
info "Terminating EC2 instance $INSTANCE_ID..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
ok "EC2 terminated"

# ── Elastic IP ────────────────────────────────────────────────────────────────
info "Releasing Elastic IP..."
aws ec2 release-address --allocation-id "$EIP_ALLOC" --region "$REGION"
ok "Elastic IP released"

# ── Security Group ────────────────────────────────────────────────────────────
info "Deleting security group $SG_ID..."
aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"
ok "Security group deleted"

# ── Subnet ────────────────────────────────────────────────────────────────────
info "Deleting subnet $SUBNET_ID..."
aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$REGION"
ok "Subnet deleted"

# ── Route Table ───────────────────────────────────────────────────────────────
info "Deleting route table..."
RT_ID=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${PROJECT}-rt" \
  --query 'RouteTables[0].RouteTableId' --output text --region "$REGION")
[ "$RT_ID" != "None" ] && aws ec2 delete-route-table --route-table-id "$RT_ID" --region "$REGION"
ok "Route table deleted"

# ── Internet Gateway ──────────────────────────────────────────────────────────
info "Detaching and deleting Internet Gateway $IGW_ID..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' --output text --region "$REGION")
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION"
ok "Internet Gateway deleted"

# ── VPC ───────────────────────────────────────────────────────────────────────
info "Deleting VPC $VPC_ID..."
aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
ok "VPC deleted"

# ── Key Pair ──────────────────────────────────────────────────────────────────
info "Deleting key pair $KEY_NAME..."
aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION"
ok "Key pair deleted"

# ── S3 ────────────────────────────────────────────────────────────────────────
info "Emptying and deleting S3 bucket $S3_BUCKET..."
aws s3 rm "s3://$S3_BUCKET" --recursive 2>/dev/null || true
aws s3api delete-bucket --bucket "$S3_BUCKET" --region "$REGION"
ok "S3 bucket deleted"

# ── IAM ───────────────────────────────────────────────────────────────────────
info "Cleaning up IAM..."
KEYS=$(aws iam list-access-keys --user-name "$IAM_USER" \
  --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || echo "")
for k in $KEYS; do
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k"
done
aws iam remove-user-from-group --user-name "$IAM_USER" --group-name "$IAM_GROUP" 2>/dev/null || true
aws iam delete-user --user-name "$IAM_USER" 2>/dev/null || true
aws iam detach-group-policy --group-name "$IAM_GROUP" --policy-arn "$POLICY_ARN" 2>/dev/null || true
aws iam delete-group --group-name "$IAM_GROUP" 2>/dev/null || true
aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
ok "IAM resources deleted"

info "================================================================"
info "Teardown complete. All AWS resources have been removed."
info "Your local key file remains at: $KEY_FILE"
info "================================================================"
