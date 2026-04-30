#!/bin/bash
# =============================================================================
# cis-03-remediate.sh
# Applies CIS hardening fixes that are safe and free for the demo environment.
# Run ON the EC2 instance as ec2-user (uses sudo where needed).
#
# Each fix is labelled with the CIS control ID it addresses.
# Fixes are idempotent — safe to run multiple times.
# =============================================================================
set -euo pipefail

info()  { echo -e "\n\033[1;36m[FIX]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[DONE]\033[0m $*"; }
skip()  { echo -e "\033[1;33m[SKIP]\033[0m $*"; }

echo ""
echo "========================================================"
echo " CIS Hardening Remediation — AFFiNE Demo"
echo " Applying safe, free, demo-compatible fixes"
echo "========================================================"


# ── CIS 1.x IAM ──────────────────────────────────────────────────────────────

info "CIS 1.10 — EC2 metadata: enforce IMDSv2 (no token = reject)"
TOKEN=$(curl -s --max-time 2 -X PUT \
  "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
if [ -n "$TOKEN" ]; then
  INSTANCE_ID=$(curl -s --max-time 2 \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || echo "")
  if [ -n "$INSTANCE_ID" ]; then
    # Load region from env
    source /opt/affine/bootstrap-outputs.env 2>/dev/null || true
    aws ec2 modify-instance-metadata-options \
      --instance-id "$INSTANCE_ID" \
      --http-tokens required \
      --http-endpoint enabled \
      --region "${REGION:-ap-southeast-2}" 2>/dev/null && \
      ok "IMDSv2 enforced on $INSTANCE_ID" || \
      skip "IMDSv2 — could not modify (may need EC2 permissions)"
  fi
fi


# ── CIS 2.x Storage / S3 ─────────────────────────────────────────────────────

info "CIS 2.1.1 — S3 bucket: enable versioning"
source /opt/affine/bootstrap-outputs.env 2>/dev/null || true
if [ -n "${S3_BUCKET:-}" ]; then
  aws s3api put-bucket-versioning \
    --bucket "$S3_BUCKET" \
    --versioning-configuration Status=Enabled \
    --region "${S3_REGION:-ap-southeast-2}" 2>/dev/null && \
    ok "S3 versioning enabled on $S3_BUCKET" || \
    skip "S3 versioning — could not enable"
fi

info "CIS 2.1.2 — S3 bucket: block all public access (confirm)"
if [ -n "${S3_BUCKET:-}" ]; then
  aws s3api put-public-access-block \
    --bucket "$S3_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
    --region "${S3_REGION:-ap-southeast-2}" 2>/dev/null && \
    ok "S3 public access blocked" || skip "S3 public access block"
fi


# ── CIS 3.x Logging ──────────────────────────────────────────────────────────

info "CIS 3.x — S3 access logging on the demo bucket (free)"
if [ -n "${S3_BUCKET:-}" ]; then
  LOG_BUCKET="${S3_BUCKET}-logs"
  # Create log bucket if needed
  aws s3api create-bucket --bucket "$LOG_BUCKET" \
    --region "${S3_REGION:-ap-southeast-2}" \
    --create-bucket-configuration LocationConstraint="${S3_REGION:-ap-southeast-2}" \
    2>/dev/null || true
  aws s3api put-bucket-logging \
    --bucket "$S3_BUCKET" \
    --bucket-logging-status \
    "{\"LoggingEnabled\":{\"TargetBucket\":\"$LOG_BUCKET\",\"TargetPrefix\":\"access-logs/\"}}" \
    --region "${S3_REGION:-ap-southeast-2}" 2>/dev/null && \
    ok "S3 access logging enabled → $LOG_BUCKET" || \
    skip "S3 access logging"
fi


# ── CIS 4.x — Network ────────────────────────────────────────────────────────

info "CIS 5.4 — VPC: enable VPC flow logs (free to create, S3 storage ~$0.50/mo)"
read -r -t 10 -p "Enable VPC flow logs? Adds ~$0.50/mo storage cost [y/N] " FLOW || FLOW="N"
if [[ "${FLOW,,}" == "y" ]]; then
  source /opt/affine/bootstrap-outputs.env 2>/dev/null || true
  FLOW_BUCKET="${S3_BUCKET}-flowlogs"
  aws s3api create-bucket --bucket "$FLOW_BUCKET" \
    --region "${REGION:-ap-southeast-2}" \
    --create-bucket-configuration LocationConstraint="${REGION:-ap-southeast-2}" \
    2>/dev/null || true
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids "$VPC_ID" \
    --traffic-type ALL \
    --log-destination-type s3 \
    --log-destination "arn:aws:s3:::${FLOW_BUCKET}" \
    --region "${REGION:-ap-southeast-2}" 2>/dev/null && \
    ok "VPC flow logs enabled → $FLOW_BUCKET" || skip "VPC flow logs"
else
  skip "VPC flow logs — skipped (confirm 'y' to enable)"
fi


# ── OS: Amazon Linux 2023 hardening ──────────────────────────────────────────

info "CIS Linux — disable unused kernel modules"
for MOD in cramfs freevxfs jffs2 hfs hfsplus squashfs udf; do
  if ! grep -q "$MOD" /etc/modprobe.d/cis-disable.conf 2>/dev/null; then
    echo "install $MOD /bin/true" | sudo tee -a /etc/modprobe.d/cis-disable.conf > /dev/null
  fi
done
ok "Unused filesystem kernel modules disabled"

info "CIS Linux — SSH hardening (sshd_config)"
SSHD="/etc/ssh/sshd_config"
apply_sshd() {
  local key="$1" val="$2"
  if sudo grep -q "^${key}" "$SSHD" 2>/dev/null; then
    sudo sed -i "s/^${key}.*/${key} ${val}/" "$SSHD"
  else
    echo "${key} ${val}" | sudo tee -a "$SSHD" > /dev/null
  fi
}
apply_sshd "Protocol" "2"
apply_sshd "LogLevel" "VERBOSE"
apply_sshd "MaxAuthTries" "4"
apply_sshd "IgnoreRhosts" "yes"
apply_sshd "HostbasedAuthentication" "no"
apply_sshd "PermitRootLogin" "no"
apply_sshd "PermitEmptyPasswords" "no"
apply_sshd "PermitUserEnvironment" "no"
apply_sshd "ClientAliveInterval" "300"
apply_sshd "ClientAliveCountMax" "3"
apply_sshd "LoginGraceTime" "60"
apply_sshd "Banner" "/etc/issue.net"
sudo systemctl reload sshd 2>/dev/null && ok "SSH hardening applied" || ok "SSH config updated"

info "CIS Linux — login banner"
echo "Authorised users only. All activity may be monitored and reported." | \
  sudo tee /etc/issue.net /etc/issue > /dev/null
ok "Login banner set"

info "CIS Linux — set umask 027 in /etc/profile.d/"
echo "umask 027" | sudo tee /etc/profile.d/cis-umask.sh > /dev/null
ok "umask 027 applied"

info "CIS Linux — configure password policies"
{
  echo "PASS_MAX_DAYS 90"
  echo "PASS_MIN_DAYS 1"
  echo "PASS_WARN_AGE 7"
} | sudo tee /etc/login.defs.cis > /dev/null
while IFS= read -r line; do
  key=$(echo "$line" | awk '{print $1}')
  val=$(echo "$line" | awk '{print $2}')
  if sudo grep -q "^${key}" /etc/login.defs; then
    sudo sed -i "s/^${key}.*/${key} ${val}/" /etc/login.defs
  fi
done < /etc/login.defs.cis
ok "Password policy updated in /etc/login.defs"

info "CIS Linux — enable auditd"
sudo systemctl enable auditd 2>/dev/null || true
sudo systemctl start auditd 2>/dev/null || true
# Basic CIS audit rules
sudo tee /etc/audit/rules.d/cis.rules > /dev/null << 'AUDITRULES'
# CIS 4.1 — Time changes
-a always,exit -F arch=b64 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex,settimeofday,stime -k time-change
-a always,exit -F arch=b64 -S clock_settime -k time-change
-w /etc/localtime -p wa -k time-change
# CIS 4.2 — Identity changes
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k identity
# CIS 4.3 — Network environment changes
-a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/network -p wa -k system-locale
# CIS 4.5 — Sudo usage
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid!=4294967295 -k privileged
# CIS 4.17 — Kernel module loading
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,delete_module -k modules
# Make rules immutable (re-run cis-03 to change)
-e 2
AUDITRULES
sudo augenrules --load 2>/dev/null && ok "Auditd CIS rules loaded" || ok "Auditd rules written"


# ── Docker hardening ──────────────────────────────────────────────────────────

info "CIS Docker — configure Docker daemon security options"
DOCKER_DAEMON="/etc/docker/daemon.json"
if [ -f "$DOCKER_DAEMON" ]; then
  sudo cp "$DOCKER_DAEMON" "${DOCKER_DAEMON}.bak"
fi
sudo tee "$DOCKER_DAEMON" > /dev/null << 'DOCKERD'
{
  "icc": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "no-new-privileges": true,
  "userland-proxy": false,
  "live-restore": true
}
DOCKERD
sudo systemctl reload docker 2>/dev/null && ok "Docker daemon hardened" || \
  warn "Docker daemon config written — restart Docker to apply: sudo systemctl restart docker"

info "CIS Docker — add swap limit to kernel params (for container resource limits)"
if ! grep -q "cgroup_enable=memory" /proc/cmdline 2>/dev/null; then
  warn "Swap limits require kernel reboot parameter — add to /etc/default/grub manually for production"
fi


# ── Final report ──────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " Remediation complete"
echo " Re-run CIS scans to verify: ./cis-02-run-checks.sh --quick"
echo "========================================================"
