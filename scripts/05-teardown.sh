#!/bin/bash
# =============================================================================
# 05-teardown.sh  (v2.1)
# Destroys ALL AWS resources created by this demo to avoid charges.
# Uses tag-based discovery so duplicate resources from repeated runs
# are all cleaned up, not just the ones recorded in bootstrap-outputs.env.
# Run from your local machine. Prompts for confirmation before deleting.
# =============================================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../config/bootstrap-outputs.env"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
skip()  { echo -e "\033[1;33m[SKIP]\033[0m $*"; }

# Load env file if present (for REGION, PROJECT, KEY_FILE, IAM names)
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
fi

REGION="${REGION:-ap-southeast-2}"
PROJECT="${PROJECT:-affine-demo}"
IAM_USER="${IAM_USER:-affine-demo-deployer}"
IAM_GROUP="${IAM_GROUP:-affine-demo-group}"
IAM_POLICY="${IAM_POLICY:-affine-demo-policy}"
KEY_NAME="${KEY_NAME:-affine-demo-key}"
KEY_FILE="${KEY_FILE:-}"

echo ""
echo "========================================================"
echo " AFFiNE Demo — TEARDOWN (tag-based, finds ALL duplicates)"
echo " Project : $PROJECT"
echo " Region  : $REGION"
echo " This will delete EVERY resource tagged or named for"
echo " this project, including duplicates from repeated runs."
echo "========================================================"
echo ""
read -p "Type 'yes' to confirm teardown: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }

# ── EC2 Instances ─────────────────────────────────────────────────────────────
info "Finding all EC2 instances tagged for $PROJECT..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text --region "$REGION" 2>/dev/null || true)

if [ -n "$INSTANCE_IDS" ]; then
  echo "  Found: $INSTANCE_IDS"
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION"
  info "Waiting for all instances to terminate..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
  ok "EC2 instances terminated"
else
  skip "No EC2 instances found"
fi

# ── Elastic IPs ───────────────────────────────────────────────────────────────
info "Finding all Elastic IPs tagged for $PROJECT..."
EIP_ALLOC_IDS=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PROJECT}-eip" \
  --query 'Addresses[*].AllocationId' \
  --output text --region "$REGION" 2>/dev/null || true)

if [ -n "$EIP_ALLOC_IDS" ]; then
  for alloc in $EIP_ALLOC_IDS; do
    echo "  Releasing: $alloc"
    aws ec2 release-address --allocation-id "$alloc" --region "$REGION" 2>/dev/null || \
      warn "Could not release $alloc — may already be released"
  done
  ok "Elastic IPs released"
else
  skip "No Elastic IPs found"
fi

# ── Security Groups ───────────────────────────────────────────────────────────
info "Finding all security groups tagged for $PROJECT..."
SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=${PROJECT}-sg" \
  --query 'SecurityGroups[*].GroupId' \
  --output text --region "$REGION" 2>/dev/null || true)

if [ -n "$SG_IDS" ]; then
  for sg in $SG_IDS; do
    echo "  Deleting: $sg"
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || \
      warn "Could not delete $sg"
  done
  ok "Security groups deleted"
else
  skip "No security groups found"
fi

# ── Subnets ───────────────────────────────────────────────────────────────────
info "Finding all subnets tagged for $PROJECT..."
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=${PROJECT}-public-subnet" \
  --query 'Subnets[*].SubnetId' \
  --output text --region "$REGION" 2>/dev/null || true)

if [ -n "$SUBNET_IDS" ]; then
  for subnet in $SUBNET_IDS; do
    echo "  Deleting: $subnet"
    aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION" 2>/dev/null || \
      warn "Could not delete $subnet"
  done
  ok "Subnets deleted"
else
  skip "No subnets found"
fi

# ── VPCs (route tables + IGWs first, then VPC) ────────────────────────────────
info "Finding all VPCs tagged for $PROJECT..."
VPC_IDS=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query 'Vpcs[*].VpcId' \
  --output text --region "$REGION" 2>/dev/null || true)

if [ -n "$VPC_IDS" ]; then
  for vpc in $VPC_IDS; do
    echo "  Processing VPC: $vpc"

    # Route tables (skip the main/default one)
    RT_IDS=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$vpc" "Name=tag:Name,Values=${PROJECT}-rt" \
      --query 'RouteTables[*].RouteTableId' \
      --output text --region "$REGION" 2>/dev/null || true)
    for rt in $RT_IDS; do
      [ -z "$rt" ] || [ "$rt" = "None" ] && continue
      aws ec2 delete-route-table --route-table-id "$rt" --region "$REGION" 2>/dev/null || true
    done

    # Internet Gateways
    IGW_IDS=$(aws ec2 describe-internet-gateways \
      --filters "Name=attachment.vpc-id,Values=$vpc" \
      --query 'InternetGateways[*].InternetGatewayId' \
      --output text --region "$REGION" 2>/dev/null || true)
    for igw in $IGW_IDS; do
      [ -z "$igw" ] || [ "$igw" = "None" ] && continue
      aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
      aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION" 2>/dev/null || true
    done

    # VPC itself
    aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>/dev/null || \
      warn "Could not delete VPC $vpc"
  done
  ok "VPCs (+ route tables + IGWs) deleted"
else
  skip "No VPCs found"
fi

# ── Key Pair ──────────────────────────────────────────────────────────────────
info "Deleting key pair $KEY_NAME..."
aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>/dev/null || true
ok "Key pair deleted"

# ── S3 Buckets ────────────────────────────────────────────────────────────────
info "Finding all S3 buckets for $PROJECT..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
S3_PREFIX="${PROJECT}-files-"
ALL_BUCKETS=$(aws s3api list-buckets --query 'Buckets[*].Name' --output text 2>/dev/null || true)

FOUND_BUCKETS=""
for bucket in $ALL_BUCKETS; do
  if [[ "$bucket" == ${S3_PREFIX}* ]]; then
    FOUND_BUCKETS="$FOUND_BUCKETS $bucket"
  fi
done

if [ -n "$FOUND_BUCKETS" ]; then
  for bucket in $FOUND_BUCKETS; do
    echo "  Emptying and deleting: $bucket"
    aws s3 rm "s3://$bucket" --recursive 2>/dev/null || true
    aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null || \
      warn "Could not delete bucket $bucket"
  done
  ok "S3 buckets deleted"
else
  skip "No S3 buckets found matching ${S3_PREFIX}*"
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
info "Cleaning up IAM resources..."

# Find and delete all policies named affine-demo-policy (there may be duplicates)
POLICY_ARNS=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='${IAM_POLICY}'].Arn" \
  --output text 2>/dev/null || true)

# Delete IAM user
KEYS=$(aws iam list-access-keys --user-name "$IAM_USER" \
  --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || echo "")
for k in $KEYS; do
  aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$k" 2>/dev/null || true
done
aws iam remove-user-from-group --user-name "$IAM_USER" --group-name "$IAM_GROUP" 2>/dev/null || true
aws iam delete-user --user-name "$IAM_USER" 2>/dev/null || true

# Delete IAM group
for arn in $POLICY_ARNS; do
  aws iam detach-group-policy --group-name "$IAM_GROUP" --policy-arn "$arn" 2>/dev/null || true
done
aws iam delete-group --group-name "$IAM_GROUP" 2>/dev/null || true

# Delete all duplicate policies
for arn in $POLICY_ARNS; do
  echo "  Deleting policy: $arn"
  aws iam delete-policy --policy-arn "$arn" 2>/dev/null || true
done

ok "IAM resources deleted"

info "================================================================"
info "Teardown complete. All AWS resources for '$PROJECT' removed."
[ -n "$KEY_FILE" ] && info "Local key file (if it exists): $KEY_FILE"
info "================================================================"
