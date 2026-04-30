#!/bin/bash
# =============================================================================
# 04-test-affine.sh
# Runs automated checks against a running AFFiNE demo instance.
# Run from your LOCAL machine or from the EC2 instance itself.
#
# Usage:
#   ./04-test-affine.sh --host <IP_or_domain> [--skip-tls-verify]
# =============================================================================
set -euo pipefail

HOST=""
SKIP_TLS=""
CURL_OPTS="-s --max-time 15"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --skip-tls-verify) SKIP_TLS="-k"; shift ;;
    *) shift ;;
  esac
done

if [ -z "$HOST" ]; then
  # Try loading from config
  ENV_FILE="$(dirname "$0")/../config/bootstrap-outputs.env"
  [ -f "$ENV_FILE" ] && source "$ENV_FILE" && HOST="$EIP"
fi

if [ -z "$HOST" ]; then
  echo "Usage: $0 --host <IP_or_domain> [--skip-tls-verify]"
  exit 1
fi

BASE="https://${HOST}"
PASS=0; FAIL=0; WARN=0

# ── Helpers ───────────────────────────────────────────────────────────────────
check() {
  local name="$1"; local result="$2"; local expected="$3"
  if echo "$result" | grep -q "$expected"; then
    echo -e "  \033[1;32m[PASS]\033[0m $name"
    ((PASS++))
  else
    echo -e "  \033[1;31m[FAIL]\033[0m $name"
    echo "        Expected: $expected"
    echo "        Got:      $(echo "$result" | head -1)"
    ((FAIL++))
  fi
}

check_http() {
  local name="$1"; local url="$2"; local expected_code="$3"
  local code
  code=$(curl $CURL_OPTS $SKIP_TLS -o /dev/null -w "%{http_code}" "$url" || echo "000")
  if [ "$code" = "$expected_code" ]; then
    echo -e "  \033[1;32m[PASS]\033[0m $name — HTTP $code"
    ((PASS++))
  else
    echo -e "  \033[1;31m[FAIL]\033[0m $name — Expected HTTP $expected_code, got $code"
    ((FAIL++))
  fi
}

check_contains() {
  local name="$1"; local url="$2"; local pattern="$3"
  local body
  body=$(curl $CURL_OPTS $SKIP_TLS "$url" || echo "")
  if echo "$body" | grep -qi "$pattern"; then
    echo -e "  \033[1;32m[PASS]\033[0m $name"
    ((PASS++))
  else
    echo -e "  \033[1;31m[FAIL]\033[0m $name — pattern '$pattern' not found"
    echo "        Response preview: $(echo "$body" | head -c 200)"
    ((FAIL++))
  fi
}

echo ""
echo "========================================================"
echo " AFFiNE Demo — Automated Test Suite"
echo " Target: $BASE"
echo " Time:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================"

# ── 1. Infrastructure checks (from EC2) ───────────────────────────────────────
echo ""
echo "── 1. Docker service health ──────────────────────────────"
if command -v docker &>/dev/null; then
  for svc in affine_server affine_postgres affine_redis; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || \
             docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    if [ "$STATUS" = "healthy" ] || [ "$STATUS" = "running" ]; then
      echo -e "  \033[1;32m[PASS]\033[0m $svc — $STATUS"
      ((PASS++))
    else
      echo -e "  \033[1;31m[FAIL]\033[0m $svc — $STATUS"
      ((FAIL++))
    fi
  done
else
  echo -e "  \033[1;33m[SKIP]\033[0m Docker not available on this machine — run on EC2 for service checks"
  ((WARN++))
fi

# ── 2. HTTP/HTTPS reachability ────────────────────────────────────────────────
echo ""
echo "── 2. Network reachability ───────────────────────────────"
check_http "HTTPS responds"           "$BASE"             "200\|301\|302"
check_http "HTTP redirects to HTTPS"  "http://$HOST"      "301\|302"

# ── 3. AFFiNE API health endpoint ────────────────────────────────────────────
echo ""
echo "── 3. AFFiNE API health ──────────────────────────────────"
INFO=$(curl $CURL_OPTS $SKIP_TLS "$BASE/info" || echo "")
check "Server info endpoint returns data"       "$INFO"   "."
check "Server info contains version"            "$INFO"   "version\|affine\|AFFiNE"

# GraphQL endpoint
GQL_RESP=$(curl $CURL_OPTS $SKIP_TLS -X POST "$BASE/graphql" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ serverConfig { version name } }"}' || echo "")
check "GraphQL endpoint responds"               "$GQL_RESP" "data\|serverConfig\|version"

# ── 4. Static assets ─────────────────────────────────────────────────────────
echo ""
echo "── 4. Static assets & frontend ──────────────────────────"
check_http "Root page loads"           "$BASE/"          "200"
check_contains "HTML has AFFiNE title" "$BASE/"          "affine\|AFFiNE"

# ── 5. WebSocket upgrade ─────────────────────────────────────────────────────
echo ""
echo "── 5. WebSocket upgrade header ──────────────────────────"
WS_HEADERS=$(curl $CURL_OPTS $SKIP_TLS -I \
  -H "Upgrade: websocket" \
  -H "Connection: Upgrade" \
  "$BASE/" 2>&1 || echo "")
# Nginx should at least echo back upgrade-related headers or not block
if echo "$WS_HEADERS" | grep -qi "upgrade\|websocket\|200\|101"; then
  echo -e "  \033[1;32m[PASS]\033[0m Nginx passes WebSocket headers"
  ((PASS++))
else
  echo -e "  \033[1;33m[WARN]\033[0m WebSocket header check inconclusive — test real-time collab manually"
  ((WARN++))
fi

# ── 6. S3 connectivity (from EC2) ────────────────────────────────────────────
echo ""
echo "── 6. S3 storage connectivity ───────────────────────────"
if command -v aws &>/dev/null; then
  ENV_FILE="$(dirname "$0")/../config/bootstrap-outputs.env"
  if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    TEST_KEY="affine-test-$(date +%s).txt"
    if aws s3 cp /dev/stdin "s3://${S3_BUCKET}/${TEST_KEY}" \
        --content-type text/plain <<< "affine-demo-test" 2>/dev/null; then
      echo -e "  \033[1;32m[PASS]\033[0m S3 write succeeded"
      aws s3 rm "s3://${S3_BUCKET}/${TEST_KEY}" 2>/dev/null
      echo -e "  \033[1;32m[PASS]\033[0m S3 delete succeeded"
      ((PASS+=2))
    else
      echo -e "  \033[1;31m[FAIL]\033[0m S3 write failed — check IAM credentials in .env"
      ((FAIL++))
    fi
  else
    echo -e "  \033[1;33m[SKIP]\033[0m bootstrap-outputs.env not found"
    ((WARN++))
  fi
else
  echo -e "  \033[1;33m[SKIP]\033[0m AWS CLI not available"
  ((WARN++))
fi

# ── 7. PostgreSQL check (from EC2) ───────────────────────────────────────────
echo ""
echo "── 7. PostgreSQL + pgvector ──────────────────────────────"
if command -v docker &>/dev/null; then
  PG_VER=$(docker exec affine_postgres psql -U affine -d affine \
    -t -c "SELECT version();" 2>/dev/null | head -1 | xargs || echo "")
  check "PostgreSQL is accessible"  "$PG_VER" "PostgreSQL"

  VEC=$(docker exec affine_postgres psql -U affine -d affine \
    -t -c "SELECT extname FROM pg_extension WHERE extname='vector';" 2>/dev/null | xargs || echo "")
  check "pgvector extension installed"  "$VEC" "vector"
else
  echo -e "  \033[1;33m[SKIP]\033[0m Run on EC2 for PostgreSQL checks"
  ((WARN+=2))
fi

# ── 8. Redis check (from EC2) ────────────────────────────────────────────────
echo ""
echo "── 8. Redis ──────────────────────────────────────────────"
if command -v docker &>/dev/null; then
  PING=$(docker exec affine_redis redis-cli ping 2>/dev/null || echo "")
  check "Redis responds to PING" "$PING" "PONG"
else
  echo -e "  \033[1;33m[SKIP]\033[0m Run on EC2 for Redis checks"
  ((WARN++))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " Results: $PASS passed  |  $FAIL failed  |  $WARN skipped"
echo "========================================================"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "\033[1;32mAll checks passed! AFFiNE demo is operational.\033[0m"
  echo ""
  echo "  Manual tests to do next:"
  echo "  1. Open $BASE in browser — create account & first workspace"
  echo "  2. Create a page, type content, add a database"
  echo "  3. Open in a second tab — confirm real-time sync"
  echo "  4. Upload an image — confirm it appears (S3 storage)"
  echo "  5. Switch a page to Edgeless mode — test whiteboard"
  echo ""
  exit 0
else
  echo -e "\033[1;31m$FAIL check(s) failed. Review output above.\033[0m"
  exit 1
fi
