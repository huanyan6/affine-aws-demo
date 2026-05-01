#!/bin/bash
# =============================================================================
# 01-aws-bootstrap.sh  (v2.1)
# Creates all AWS prerequisites: IAM group/user/policy, VPC, subnet,
# internet gateway, route table, security group, S3 bucket, Elastic IP.
# Run this ONCE from your local machine with admin credentials.
# =============================================================================
set -euo pipefail

# ── HELPER ────────────────────────────────────────────────────────────────────
info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# ── USERNAME SETUP (set once, used by all scripts) ────────────────────────────
echo ""
echo "========================================================="
echo " Step 0: Configure usernames for this deployment"
echo "========================================================="

# Local username (WSL / macOS / Linux)
DETECTED_USER=$(whoami)
echo ""
echo "  [1/2] Local machine username"
echo "        Detected : $DETECTED_USER"
echo "        (WSL e.g. huan_y  |  macOS/Linux e.g. john)"
read -rp "        Press Enter to use '$DETECTED_USER', or type a different name: " INPUT_USER
LOCAL_USER="${INPUT_USER:-$DETECTED_USER}"

# Determine home directory based on OS
case "$(uname -s)" in
  Darwin) LOCAL_HOME="/Users/${LOCAL_USER}" ;;
  *)      LOCAL_HOME="/home/${LOCAL_USER}" ;;
esac

ok "Local username : $LOCAL_USER  (home: $LOCAL_HOME)"

# EC2 OS username
echo ""
echo "  [2/2] EC2 instance OS username"
echo "        Amazon Linux 2023 → ec2-user (default)"
echo "        Ubuntu            → ubuntu"
echo "        RHEL / CentOS     → ec2-user or centos"
read -rp "        Press Enter for 'ec2-user', or type a different name: " INPUT_EC2_USER
EC2_USER="${INPUT_EC2_USER:-ec2-user}"

ok "EC2 OS username : $EC2_USER"
echo ""

# ── CONFIGURATION ─────────────────────────────────────────────────────────────
PROJECT="affine-demo"
REGION="${AWS_DEFAULT_REGION:-ap-southeast-2}"   # change to your preferred region
VPC_CIDR="10.10.0.0/16"
SUBNET_CIDR="10.10.1.0/24"
AZ="${REGION}a"                                  # first AZ in the region
IAM_GROUP="affine-demo-group"
IAM_USER="affine-demo-deployer"
IAM_POLICY="affine-demo-policy"
SG_NAME="affine-demo-sg"
KEY_NAME="affine-demo-key"
S3_BUCKET="${PROJECT}-files-$(aws sts get-caller-identity --query Account --output text)"

# Your local machine's public IP — restricts SSH access
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
echo ">> Your public IP for SSH: $MY_IP"

# ── 1. VPC ────────────────────────────────────────────────────────────────────
info "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT}-vpc}]" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
ok "VPC: $VPC_ID"

# ── 2. Internet Gateway ───────────────────────────────────────────────────────
info "Creating Internet Gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
ok "IGW: $IGW_ID"

# ── 3. Public Subnet ──────────────────────────────────────────────────────────
info "Creating public subnet..."
SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-public-subnet}]" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
ok "Subnet: $SUBNET_ID"

# ── 4. Route Table ────────────────────────────────────────────────────────────
info "Creating route table..."
RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rt}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID"
ok "Route table: $RT_ID"

# ── 5. Security Group ─────────────────────────────────────────────────────────
info "Creating security group..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "AFFiNE demo - HTTPS public, SSH restricted" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}}]" \
  --query 'GroupId' --output text)

# HTTPS from anywhere
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

# HTTP (redirect to HTTPS via Nginx)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# SSH from your IP only
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$MY_IP"

ok "Security group: $SG_ID  (SSH allowed from $MY_IP only)"

# ── 6. Key Pair ───────────────────────────────────────────────────────────────
info "Creating SSH key pair..."
KEY_FILE="${LOCAL_HOME}/.ssh/${KEY_NAME}.pem"
mkdir -p "${LOCAL_HOME}/.ssh"
chmod 700 "${LOCAL_HOME}/.ssh"

AWS_KEY_EXISTS=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" \
  --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")

if [ "$AWS_KEY_EXISTS" = "$KEY_NAME" ] && [ -f "$KEY_FILE" ]; then
  warn "Key pair already exists in AWS and local key file found — skipping"
else
  # Stale local file or missing AWS key pair — recreate both
  [ -f "$KEY_FILE" ] && { warn "Stale local key file found (AWS key missing) — removing and re-creating"; rm -f "$KEY_FILE"; }
  aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  ok "Key pair created and saved to $KEY_FILE"
fi

# ── 7. IAM Policy ─────────────────────────────────────────────────────────────
info "Creating IAM policy (S3 access for AFFiNE file uploads)..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AFFiNES3Access",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
    }
  ]
}
EOF
)

POLICY_ARN=$(aws iam create-policy \
  --policy-name "$IAM_POLICY" \
  --policy-document "$POLICY_DOC" \
  --query 'Policy.Arn' --output text)
ok "Policy ARN: $POLICY_ARN"

# ── 8. IAM Group & User ───────────────────────────────────────────────────────
info "Creating IAM group and user..."
aws iam create-group --group-name "$IAM_GROUP"
aws iam attach-group-policy --group-name "$IAM_GROUP" --policy-arn "$POLICY_ARN"

aws iam create-user --user-name "$IAM_USER" \
  --tags Key=Project,Value="$PROJECT"
aws iam add-user-to-group --user-name "$IAM_USER" --group-name "$IAM_GROUP"

# Create access keys for S3 usage inside EC2
CREDS=$(aws iam create-access-key --user-name "$IAM_USER" --query 'AccessKey')
AWS_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['AccessKeyId'])")
AWS_SECRET_KEY=$(echo "$CREDS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['SecretAccessKey'])")
ok "IAM user: $IAM_USER"

# ── 9. S3 Bucket ─────────────────────────────────────────────────────────────
info "Creating S3 bucket: $S3_BUCKET..."
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION"
else
  aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
aws s3api put-public-access-block --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
ok "S3 bucket: $S3_BUCKET"

# ── 10. Elastic IP ────────────────────────────────────────────────────────────
info "Allocating Elastic IP..."
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip}]" \
  --query 'AllocationId' --output text)
EIP=$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC" \
  --query 'Addresses[0].PublicIp' --output text)
ok "Elastic IP: $EIP  (AllocationId: $EIP_ALLOC)"

# ── 11. Save outputs ──────────────────────────────────────────────────────────
OUTFILE="$(dirname "$0")/../config/bootstrap-outputs.env"
cat > "$OUTFILE" <<EOF
# Generated by 01-aws-bootstrap.sh — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOCAL_USER=$LOCAL_USER
LOCAL_HOME=$LOCAL_HOME
EC2_USER=$EC2_USER
PROJECT=$PROJECT
REGION=$REGION
VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
SG_ID=$SG_ID
KEY_NAME=$KEY_NAME
KEY_FILE=$KEY_FILE
IAM_USER=$IAM_USER
IAM_GROUP=$IAM_GROUP
POLICY_ARN=$POLICY_ARN
S3_BUCKET=$S3_BUCKET
S3_REGION=$REGION
EIP=$EIP
EIP_ALLOC=$EIP_ALLOC
AFFINE_AWS_ACCESS_KEY=$AWS_ACCESS_KEY
AFFINE_AWS_SECRET_KEY=$AWS_SECRET_KEY
EOF
chmod 600 "$OUTFILE"

info "================================================================"
info "Bootstrap complete. Outputs saved to: $OUTFILE"
info "Next: run  02-launch-ec2.sh"
info "================================================================"
