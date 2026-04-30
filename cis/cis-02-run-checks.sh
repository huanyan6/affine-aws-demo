#!/bin/bash
# =============================================================================
# cis-02-run-checks.sh
# Runs three CIS verification scans against the AFFiNE demo environment:
#   Layer 1 — AWS foundations (IAM, VPC, S3, CloudTrail) via Prowler
#   Layer 2 — EC2 OS hardening (Amazon Linux 2023)       via Lynis
#   Layer 3 — Docker containers (AFFiNE stack)           via docker-bench
#
# Run ON the EC2 instance as ec2-user.
# Usage: ./cis-02-run-checks.sh [--layer aws|os|docker|all] [--quick]
#
# --quick    skips slow checks (good for CI or first-time validation)
# --layer    run only one layer (default: all)
# =============================================================================
set -euo pipefail

REPORT_DIR="/opt/affine/cis-reports"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
LAYER="all"
QUICK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --layer) LAYER="$2"; shift 2 ;;
    --quick) QUICK="yes"; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$REPORT_DIR/$TIMESTAMP"
REPORT_BASE="$REPORT_DIR/$TIMESTAMP"

info()  { echo -e "\n\033[1;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
section(){ echo -e "\n\033[1;35m══ $* ══\033[0m"; }

# Load AWS config
source /opt/affine/bootstrap-outputs.env 2>/dev/null || \
  warn "bootstrap-outputs.env not found — AWS checks will use instance role"

echo ""
echo "========================================================"
echo " CIS Baseline Verification — AFFiNE Demo on AWS"
echo " Timestamp: $TIMESTAMP"
echo " Output:    $REPORT_BASE"
echo "========================================================"


# ─────────────────────────────────────────────────────────────────────────────
# LAYER 1: AWS Foundations via Prowler
# Covers CIS AWS Foundations Benchmark v4.0 / v5.0
# ─────────────────────────────────────────────────────────────────────────────
run_aws_layer() {
  section "Layer 1 — AWS Foundations (Prowler CIS)"

  # Scope checks specifically to services used in this demo
  # CIS sections: IAM (1.x), Storage/S3 (2.x), Logging/CloudTrail (3.x), VPC (5.x)
  PROWLER_SERVICES="iam,s3,ec2,vpc,cloudtrail,guardduty,config,securityhub"

  info "Running Prowler CIS AWS Foundations check..."
  info "Services in scope: $PROWLER_SERVICES"
  info "(This takes 5-10 min depending on account size)"

  # Build prowler command
  PROWLER_CMD=(
    prowler aws
    --compliance cis_level1_aws
    --services "$PROWLER_SERVICES"
    --output-formats html,json,csv
    --output-directory "$REPORT_BASE"
    --output-filename "cis-aws-layer1"
    --no-banner
  )

  # Add region filter
  [ -n "${REGION:-}" ] && PROWLER_CMD+=(--region "$REGION")

  # Quick mode: only critical/high severity
  [ -n "$QUICK" ] && PROWLER_CMD+=(--severity critical,high)

  "${PROWLER_CMD[@]}" && ok "AWS layer scan complete" || \
    warn "Prowler completed with some findings (expected for new accounts)"

  # Summary from JSON output
  JSON_OUT="$REPORT_BASE/cis-aws-layer1.json"
  if [ -f "$JSON_OUT" ]; then
    PASS=$(jq '[.[] | select(.status=="PASS")] | length' "$JSON_OUT" 2>/dev/null || echo "?")
    FAIL=$(jq '[.[] | select(.status=="FAIL")] | length' "$JSON_OUT" 2>/dev/null || echo "?")
    WARN_COUNT=$(jq '[.[] | select(.status=="WARNING")] | length' "$JSON_OUT" 2>/dev/null || echo "?")
    echo ""
    echo "  AWS layer results: PASS=$PASS  FAIL=$FAIL  WARN=$WARN_COUNT"
    echo ""

    # Show critical failures
    echo "  Critical/High failures:"
    jq -r '.[] | select(.status=="FAIL") | select(.severity=="critical" or .severity=="high") |
      "    [" + .severity + "] " + .check_id + " — " + .check_title' \
      "$JSON_OUT" 2>/dev/null | head -20 || echo "  (none found)"
  fi

  info "HTML report: $REPORT_BASE/cis-aws-layer1.html"
}


# ─────────────────────────────────────────────────────────────────────────────
# LAYER 2: OS hardening via Lynis (CIS Linux benchmark)
# ─────────────────────────────────────────────────────────────────────────────
run_os_layer() {
  section "Layer 2 — OS Hardening (Lynis CIS Linux)"

  info "Running Lynis system audit..."
  info "This takes ~3-5 min"

  LYNIS_REPORT="$REPORT_BASE/lynis-report.txt"
  LYNIS_LOG="$REPORT_BASE/lynis.log"

  # Run Lynis audit (non-interactive)
  sudo lynis audit system \
    --quiet \
    --no-colors \
    --report-file "$LYNIS_REPORT" \
    --logfile "$LYNIS_LOG" \
    2>/dev/null || true

  # Parse hardening index score
  SCORE=$(grep "^hardening_index=" "$LYNIS_REPORT" 2>/dev/null | cut -d= -f2 || echo "N/A")
  SUGGESTIONS=$(grep "^suggestion\[\]=" "$LYNIS_REPORT" 2>/dev/null | wc -l || echo "0")
  WARNINGS=$(grep "^warning\[\]=" "$LYNIS_REPORT" 2>/dev/null | wc -l || echo "0")

  echo ""
  echo "  Lynis hardening index: $SCORE / 100"
  echo "  Suggestions:           $SUGGESTIONS"
  echo "  Warnings:              $WARNINGS"
  echo ""

  if [ "$SCORE" != "N/A" ] && [ "$SCORE" -ge 65 ]; then
    ok "OS hardening score acceptable for demo ($SCORE/100)"
  elif [ "$SCORE" != "N/A" ]; then
    warn "OS hardening score below 65 ($SCORE/100) — review suggestions"
  fi

  # Show top warnings
  if [ -f "$LYNIS_REPORT" ]; then
    echo "  Top OS warnings:"
    grep "^warning\[\]=" "$LYNIS_REPORT" 2>/dev/null | \
      sed 's/^warning\[\]=//;s/|.*$//' | head -10 | \
      sed 's/^/    /' || echo "  (no warnings)"
  fi

  # Generate human-readable OS report
  {
    echo "=== Lynis OS CIS Report — $TIMESTAMP ==="
    echo "Hardening Index: $SCORE/100"
    echo "Warnings: $WARNINGS  |  Suggestions: $SUGGESTIONS"
    echo ""
    echo "=== WARNINGS ==="
    grep "^warning\[\]=" "$LYNIS_REPORT" 2>/dev/null | sed 's/^warning\[\]=//;s/|/ | /' || echo "(none)"
    echo ""
    echo "=== TOP SUGGESTIONS ==="
    grep "^suggestion\[\]=" "$LYNIS_REPORT" 2>/dev/null | sed 's/^suggestion\[\]=//;s/|/ | /' | head -20 || echo "(none)"
  } > "$REPORT_BASE/cis-os-layer2-summary.txt"

  info "OS report: $REPORT_BASE/cis-os-layer2-summary.txt"
  info "Full log:  $LYNIS_LOG"
}


# ─────────────────────────────────────────────────────────────────────────────
# LAYER 3: Docker CIS benchmark via docker-bench-security
# Covers: Docker Engine config, container isolation, image security
# ─────────────────────────────────────────────────────────────────────────────
run_docker_layer() {
  section "Layer 3 — Docker CIS Benchmark"

  BENCH_DIR="/opt/prowler/docker-bench-security"

  if [ ! -d "$BENCH_DIR" ]; then
    warn "docker-bench-security not found at $BENCH_DIR"
    warn "Run cis-01-install-prowler.sh first"
    return
  fi

  info "Running docker-bench-security CIS checks..."
  info "Containers in scope: affine_server, affine_postgres, affine_redis"

  DOCKER_REPORT="$REPORT_BASE/cis-docker-layer3.txt"
  DOCKER_JSON="$REPORT_BASE/cis-docker-layer3.json"

  cd "$BENCH_DIR"
  sudo sh docker-bench-security.sh \
    -c container_images,container_runtime,docker_security_operations \
    -t affine_server,affine_postgres,affine_redis \
    -l "$DOCKER_REPORT" \
    -f json 2>/dev/null | tee "$DOCKER_JSON" || true

  # Parse results
  if [ -f "$DOCKER_REPORT" ]; then
    PASS=$(grep -c "\[PASS\]" "$DOCKER_REPORT" 2>/dev/null || echo 0)
    FAIL=$(grep -c "\[WARN\]" "$DOCKER_REPORT" 2>/dev/null || echo 0)
    INFO=$(grep -c "\[INFO\]" "$DOCKER_REPORT" 2>/dev/null || echo 0)
    echo ""
    echo "  Docker CIS results: PASS=$PASS  WARN=$FAIL  INFO=$INFO"
    echo ""
    echo "  Warnings:"
    grep "\[WARN\]" "$DOCKER_REPORT" 2>/dev/null | head -15 | sed 's/^/    /' || echo "  (none)"
  fi

  # Also check container security config manually
  echo ""
  info "Additional container security checks..."
  {
    echo "=== Container Security Configuration ==="
    echo ""
    for CONTAINER in affine_server affine_postgres affine_redis; do
      echo "--- $CONTAINER ---"
      docker inspect "$CONTAINER" 2>/dev/null | \
        jq '.[0] | {
          ReadonlyRootfs: .HostConfig.ReadonlyRootfs,
          Privileged: .HostConfig.Privileged,
          NetworkMode: .HostConfig.NetworkMode,
          UsernsMode: .HostConfig.UsernsMode,
          PidMode: .HostConfig.PidMode,
          CapAdd: .HostConfig.CapAdd,
          CapDrop: .HostConfig.CapDrop,
          SecurityOpt: .HostConfig.SecurityOpt,
          RestartPolicy: .HostConfig.RestartPolicy.Name
        }' 2>/dev/null || echo "(container not running)"
      echo ""
    done
  } >> "$REPORT_BASE/cis-docker-layer3-detail.json"

  info "Docker report: $DOCKER_REPORT"
}


# ─────────────────────────────────────────────────────────────────────────────
# CONSOLIDATED REPORT
# ─────────────────────────────────────────────────────────────────────────────
generate_summary() {
  section "Generating Consolidated CIS Report"

  SUMMARY="$REPORT_BASE/CIS-SUMMARY-${TIMESTAMP}.txt"
  {
    echo "========================================================"
    echo " AFFiNE Demo — CIS Baseline Verification Summary"
    echo " Generated: $TIMESTAMP"
    echo " Environment: ${EIP:-'unknown IP'} (${REGION:-unknown})"
    echo "========================================================"
    echo ""

    echo "SCOPE"
    echo "  AWS Account:     CIS AWS Foundations Benchmark v4/v5 (Prowler)"
    echo "  OS:              CIS Linux Benchmark Level 1 (Lynis)"
    echo "  Containers:      CIS Docker Benchmark (docker-bench-security)"
    echo ""

    echo "LAYER 1 — AWS FOUNDATIONS"
    if [ -f "$REPORT_BASE/cis-aws-layer1.json" ]; then
      PASS=$(jq '[.[] | select(.status=="PASS")] | length' "$REPORT_BASE/cis-aws-layer1.json" 2>/dev/null || echo "?")
      FAIL=$(jq '[.[] | select(.status=="FAIL")] | length' "$REPORT_BASE/cis-aws-layer1.json" 2>/dev/null || echo "?")
      echo "  PASS: $PASS  FAIL: $FAIL"
      echo "  Report: $REPORT_BASE/cis-aws-layer1.html"
    else
      echo "  (not run)"
    fi
    echo ""

    echo "LAYER 2 — OS HARDENING"
    if [ -f "$REPORT_BASE/lynis-report.txt" ]; then
      SCORE=$(grep "^hardening_index=" "$REPORT_BASE/lynis-report.txt" 2>/dev/null | cut -d= -f2 || echo "N/A")
      echo "  Hardening index: $SCORE / 100"
      echo "  Report: $REPORT_BASE/cis-os-layer2-summary.txt"
    else
      echo "  (not run)"
    fi
    echo ""

    echo "LAYER 3 — DOCKER CONTAINERS"
    if [ -f "$REPORT_BASE/cis-docker-layer3.txt" ]; then
      PASS=$(grep -c "\[PASS\]" "$REPORT_BASE/cis-docker-layer3.txt" 2>/dev/null || echo 0)
      FAIL=$(grep -c "\[WARN\]" "$REPORT_BASE/cis-docker-layer3.txt" 2>/dev/null || echo 0)
      echo "  PASS: $PASS  WARN: $FAIL"
      echo "  Report: $REPORT_BASE/cis-docker-layer3.txt"
    else
      echo "  (not run)"
    fi
    echo ""

    echo "KNOWN ACCEPTABLE FINDINGS (demo environment)"
    cat << 'KNOWN'
  The following findings are expected/accepted for a demo deployment:
  [AWS]  CloudTrail not enabled            — not needed for single-account demo
  [AWS]  MFA not enforced on root          — acceptable; enable for production
  [AWS]  Config Recorder not enabled       — costs ~$2/mo; skipped for demo
  [AWS]  GuardDuty not enabled             — costs ~$4/mo; skipped for demo
  [OS]   AIDE/IDS not installed            — not required for demo
  [OS]   Auditd rules minimal              — acceptable for demo
  [Docker] No read-only rootfs             — AFFiNE requires write access
  [Docker] Containers run as root          — default; harden in production
KNOWN
    echo ""
    echo "NEXT STEPS FOR PRODUCTION HARDENING"
    echo "  1. Enable CloudTrail (all regions)       ~$2/mo"
    echo "  2. Enable GuardDuty                      ~$4/mo"
    echo "  3. Enable AWS Config                     ~$1/mo"
    echo "  4. Enable MFA on all IAM users           Free"
    echo "  5. Run containers as non-root user       Free"
    echo "  6. Enable EC2 IMDSv2 (already done)      Free"
    echo "  7. Enable S3 access logging              ~$0.50/mo"
    echo "  8. Set password policy (IAM)             Free"
    echo "========================================================"
  } > "$SUMMARY"

  cat "$SUMMARY"
  info "Full summary saved to: $SUMMARY"
}


# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
case "$LAYER" in
  aws)    run_aws_layer ;;
  os)     run_os_layer ;;
  docker) run_docker_layer ;;
  all)
    run_aws_layer
    run_os_layer
    run_docker_layer
    generate_summary
    ;;
  *)
    echo "Unknown layer: $LAYER. Use: aws|os|docker|all"
    exit 1
    ;;
esac

echo ""
info "All reports saved to: $REPORT_BASE"
info "To copy reports to your local machine:"
echo "  scp -r -i ~/.ssh/affine-demo-key.pem ec2-user@<EIP>:$REPORT_BASE ./cis-reports-$TIMESTAMP"
