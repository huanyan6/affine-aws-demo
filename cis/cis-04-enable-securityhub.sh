#!/bin/bash
# =============================================================================
# cis-04-enable-securityhub.sh  [OPTIONAL]
# Enables AWS Security Hub with CIS AWS Foundations Benchmark v5.0
# for the 30-day free trial period.
#
# Cost:  $0 during 30-day trial
#        ~$1–3/mo after trial for single account (demo size)
#        Disable before day 30 to avoid charges.
#
# Run from your LOCAL machine (needs AWS CLI with admin credentials).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/bootstrap-outputs.env"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }

echo ""
echo "========================================================"
echo " AWS Security Hub — CIS v5.0 Setup (30-day free trial)"
echo " Region: $REGION"
echo "========================================================"
echo ""
warn "After the 30-day trial, Security Hub costs ~$1–3/mo for this demo size."
warn "This script will remind you to disable it. Continue? [y/N]"
read -r CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── 1. Enable AWS Config (required by Security Hub) ──────────────────────────
info "Setting up AWS Config (Security Hub dependency)..."

# Create Config S3 bucket
CONFIG_BUCKET="${PROJECT}-config-$(aws sts get-caller-identity --query Account --output text)"
aws s3api create-bucket --bucket "$CONFIG_BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || \
  warn "Config bucket may already exist"

# Config bucket policy (allows Config service to write)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3api put-bucket-policy --bucket "$CONFIG_BUCKET" --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Sid\": \"AWSConfigBucketPermissionsCheck\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"config.amazonaws.com\"},
      \"Action\": \"s3:GetBucketAcl\",
      \"Resource\": \"arn:aws:s3:::${CONFIG_BUCKET}\"
    },
    {
      \"Sid\": \"AWSConfigBucketDelivery\",
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"config.amazonaws.com\"},
      \"Action\": \"s3:PutObject\",
      \"Resource\": \"arn:aws:s3:::${CONFIG_BUCKET}/AWSLogs/${ACCOUNT_ID}/Config/*\",
      \"Condition\": {\"StringEquals\": {\"s3:x-amz-acl\": \"bucket-owner-full-control\"}}
    }
  ]
}" 2>/dev/null

# Create Config recorder
CONFIG_ROLE_ARN=$(aws iam create-role \
  --role-name "AWSConfigRole-${PROJECT}" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"config.amazonaws.com"},
    "Action":"sts:AssumeRole"}]}' \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name "AWSConfigRole-${PROJECT}" --query 'Role.Arn' --output text)

aws iam attach-role-policy \
  --role-name "AWSConfigRole-${PROJECT}" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWS_ConfigRole 2>/dev/null || true

aws configservice put-configuration-recorder \
  --configuration-recorder \
    "name=default,roleARN=${CONFIG_ROLE_ARN},recordingGroup={allSupported=false,resourceTypes=[\"AWS::IAM::User\",\"AWS::IAM::Role\",\"AWS::IAM::Policy\",\"AWS::EC2::SecurityGroup\",\"AWS::EC2::VPC\",\"AWS::EC2::Subnet\",\"AWS::S3::Bucket\"]}" \
  --region "$REGION"

aws configservice put-delivery-channel \
  --delivery-channel "name=default,s3BucketName=${CONFIG_BUCKET}" \
  --region "$REGION"

aws configservice start-configuration-recorder \
  --configuration-recorder-name default \
  --region "$REGION"
ok "AWS Config recorder started"

# ── 2. Enable Security Hub ────────────────────────────────────────────────────
info "Enabling AWS Security Hub..."
aws securityhub enable-security-hub \
  --enable-default-standards \
  --region "$REGION" 2>/dev/null || warn "Security Hub may already be enabled"
ok "Security Hub enabled"

# ── 3. Enable CIS v5.0 standard ──────────────────────────────────────────────
info "Enabling CIS AWS Foundations Benchmark v5.0..."
CIS_ARN="arn:aws:securityhub:${REGION}::standards/cis-aws-foundations-benchmark/v/5.0.0"
aws securityhub batch-enable-standards \
  --standards-subscription-requests "[{\"StandardsArn\":\"${CIS_ARN}\"}]" \
  --region "$REGION" 2>/dev/null || warn "CIS standard may already be enabled"
ok "CIS v5.0 standard enabled"

# ── 4. Set a billing reminder ─────────────────────────────────────────────────
info "Setting cost reminder..."
END_DATE=$(date -d "+30 days" +"%Y-%m-%d" 2>/dev/null || \
           date -v +30d +"%Y-%m-%d" 2>/dev/null || echo "30 days from now")
echo ""
echo "========================================================"
ok " Security Hub enabled — 30-day free trial active"
echo ""
echo "  CIS findings appear in 24 hours:"
echo "  https://console.aws.amazon.com/securityhub/home?region=${REGION}#/standards"
echo ""
warn " REMINDER: Disable Security Hub by $END_DATE to avoid charges."
warn " Disable with:  ./cis-04-enable-securityhub.sh --disable"
echo "========================================================"

# ── --disable flag ────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--disable" ]]; then
  info "Disabling Security Hub and Config recorder..."
  aws securityhub disable-security-hub --region "$REGION" 2>/dev/null && ok "Security Hub disabled"
  aws configservice stop-configuration-recorder \
    --configuration-recorder-name default --region "$REGION" 2>/dev/null && ok "Config recorder stopped"
  echo ""
  warn "Config recorder stopped but NOT deleted — run manually to avoid $0.003/config-item charges"
fi
