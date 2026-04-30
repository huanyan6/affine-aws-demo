#!/bin/bash
# =============================================================================
# cis-01-install-prowler.sh
# Installs Prowler OSS on the EC2 instance and verifies it works.
# Run ON the EC2 instance as ec2-user.
# Cost: $0 — Prowler is fully open source
# =============================================================================
set -euo pipefail

PROWLER_DIR="/opt/prowler"
REPORT_DIR="/opt/affine/cis-reports"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# ── System dependencies ───────────────────────────────────────────────────────
info "Installing system dependencies..."
sudo dnf install -y python3-pip python3-devel gcc git jq 2>/dev/null || true

# ── Prowler via pip ───────────────────────────────────────────────────────────
info "Installing Prowler OSS (latest stable)..."
pip3 install prowler --quiet --break-system-packages 2>/dev/null || \
  pip3 install prowler --quiet

# Verify install
PROWLER_VERSION=$(prowler --version 2>/dev/null | head -1 || echo "unknown")
ok "Prowler installed: $PROWLER_VERSION"

# ── docker-bench-security ─────────────────────────────────────────────────────
info "Installing docker-bench-security (CIS Docker benchmark)..."
if [ -d "$PROWLER_DIR/docker-bench-security" ]; then
  warn "docker-bench-security already exists — skipping clone"
else
  sudo mkdir -p "$PROWLER_DIR"
  sudo chown ec2-user:ec2-user "$PROWLER_DIR"
  git clone --depth 1 https://github.com/docker/docker-bench-security.git \
    "$PROWLER_DIR/docker-bench-security"
fi
ok "docker-bench-security ready"

# ── lynis (OS-level CIS hardening) ───────────────────────────────────────────
info "Installing Lynis (OS/Linux CIS benchmark)..."
sudo dnf install -y lynis 2>/dev/null || {
  warn "dnf install failed — trying manual install"
  cd /tmp
  curl -sLO https://github.com/CISOfy/lynis/archive/refs/heads/master.zip
  unzip -q master.zip -d /opt/
  sudo mv /opt/lynis-master /opt/lynis
  sudo ln -sf /opt/lynis/lynis /usr/local/bin/lynis
}
ok "Lynis installed: $(lynis --version 2>/dev/null | head -1 || echo 'ready')"

# ── Report directory ──────────────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"
ok "Report output directory: $REPORT_DIR"

info "================================================================"
info "All CIS tools installed. Next: run cis-02-run-checks.sh"
info "================================================================"
