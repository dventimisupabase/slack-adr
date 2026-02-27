#!/usr/bin/env bash
# test/smoke_test.sh
# End-to-end smoke tests for Edge Functions against local Supabase.
# Exercises the full stack: Edge Function → PostgREST → SQL → response.
#
# Prerequisites:
#   supabase start
#   supabase db reset
#
# Usage:
#   bash test/smoke_test.sh

set -euo pipefail

BASE_URL="http://127.0.0.1:54321"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
SIGNING_SECRET="local-dev-signing-secret"
PASS=0
FAIL=0

sign_request() {
  local body="$1"
  local ts
  ts=$(date +%s)
  local sig_base="v0:${ts}:${body}"
  local hmac
  hmac=$(echo -n "$sig_base" | openssl dgst -sha256 -hmac "$SIGNING_SECRET" | awk '{print $2}')
  echo "${ts}" "v0=${hmac}"
}

assert_contains() {
  local label="$1"
  local response="$2"
  local expected="$3"
  if echo "$response" | grep -q "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected '$expected' in: $response"
    FAIL=$((FAIL + 1))
  fi
}

assert_status() {
  local label="$1"
  local status="$2"
  local expected="$3"
  if [ "$status" = "$expected" ]; then
    echo "  PASS: $label (HTTP $status)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected HTTP $expected, got $status"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== ADR Slack Bot Smoke Tests ==="
echo ""

# ------------------------------------------------------------------
echo "--- Test 1: Event proxy URL verification ---"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/event-proxy" \
  -H "Content-Type: application/json" \
  -d '{"type":"url_verification","challenge":"smoke_test_123"}')
assert_contains "URL verification returns challenge" "$RESP" "smoke_test_123"

# ------------------------------------------------------------------
echo "--- Test 2: /adr help via slack-proxy ---"
BODY='command=%2Fadr&text=help&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig1'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr help returns commands" "$RESP" "ADR Bot Commands"
assert_contains "/adr help mentions start" "$RESP" "/adr start"
assert_contains "/adr help mentions enable" "$RESP" "/adr enable"

# ------------------------------------------------------------------
echo "--- Test 3: /adr enable via slack-proxy ---"
BODY='command=%2Fadr&text=enable&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig2'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr enable confirms" "$RESP" "enabled"

# ------------------------------------------------------------------
echo "--- Test 4: /adr start via slack-proxy (modal opening, returns 200) ---"
BODY='command=%2Fadr&text=start&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig3'
read -r TS SIG <<< "$(sign_request "$BODY")"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_status "/adr start returns 200" "$STATUS" "200"

# ------------------------------------------------------------------
echo "--- Test 5: /adr list (empty) via slack-proxy ---"
BODY='command=%2Fadr&text=list&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig4'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr list shows no ADRs" "$RESP" "No ADRs found"

# ------------------------------------------------------------------
echo "--- Test 6: Direct PostgREST RPC with valid signature ---"
BODY='command=%2Fadr&text=help&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/rest/v1/rpc/handle_slack_webhook" \
  -H "Content-Type: application/json" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "{\"raw_body\": \"$BODY\"}")
assert_contains "Direct PostgREST RPC works" "$RESP" "ADR Bot Commands"

# ------------------------------------------------------------------
echo "--- Test 7: PostgREST rejects invalid signature ---"
RESP=$(curl -s -X POST "$BASE_URL/rest/v1/rpc/handle_slack_webhook" \
  -H "Content-Type: application/json" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "X-Slack-Signature: v0=invalid" \
  -H "X-Slack-Request-Timestamp: $(date +%s)" \
  -d '{"raw_body": "command=%2Fadr&text=help"}')
assert_contains "Invalid signature rejected" "$RESP" "Invalid Slack signature"

# ------------------------------------------------------------------
echo "--- Test 8: PostgREST rejects stale timestamp ---"
BODY='command=%2Fadr&text=help'
SIG_BASE="v0:1000000000:${BODY}"
HMAC=$(echo -n "$SIG_BASE" | openssl dgst -sha256 -hmac "$SIGNING_SECRET" | awk '{print $2}')
RESP=$(curl -s -X POST "$BASE_URL/rest/v1/rpc/handle_slack_webhook" \
  -H "Content-Type: application/json" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "X-Slack-Signature: v0=$HMAC" \
  -H "X-Slack-Request-Timestamp: 1000000000" \
  -d "{\"raw_body\": \"$BODY\"}")
assert_contains "Stale timestamp rejected" "$RESP" "timestamp too old"

# ------------------------------------------------------------------
echo "--- Test 9: PostgREST rejects missing signature ---"
RESP=$(curl -s -X POST "$BASE_URL/rest/v1/rpc/handle_slack_webhook" \
  -H "Content-Type: application/json" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -d '{"raw_body": "command=%2Fadr&text=help"}')
assert_contains "Missing signature rejected" "$RESP" "Missing Slack signature"

# ------------------------------------------------------------------
echo "--- Test 10: Git export callback with valid key ---"
# Create an ADR first
ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT (create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Smoke Test ADR', 'context')).id;" 2>/dev/null | tr -d ' \n')
CALLBACK_BODY="{\"adr_id\":\"$ADR_ID\",\"status\":\"complete\",\"pr_url\":\"https://github.com/test/pull/1\",\"branch\":\"adr/test\"}"
RESP=$(curl -s -X POST "$BASE_URL/rest/v1/rpc/handle_git_export_callback" \
  -H "Content-Type: application/json" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "x-export-api-key: $SERVICE_KEY" \
  -d "{\"raw_body\": $(echo "$CALLBACK_BODY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}")
assert_contains "Git export callback succeeds" "$RESP" "\"ok\" : true"

# ------------------------------------------------------------------
echo "--- Test 11: Git export callback rejected without key ---"
RESP=$(curl -s -X POST "$BASE_URL/rest/v1/rpc/handle_git_export_callback" \
  -H "Content-Type: application/json" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -d '{"raw_body": "{\"adr_id\":\"ADR-FAKE\",\"status\":\"complete\"}"}')
assert_contains "Missing export key rejected" "$RESP" "Missing export API key"

# ------------------------------------------------------------------
echo "--- Test 12: /adr disable via slack-proxy ---"
BODY='command=%2Fadr&text=disable&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig5'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr disable confirms" "$RESP" "disabled"

# ------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
