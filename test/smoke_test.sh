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
assert_contains "/adr help mentions search" "$RESP" "/adr search"
assert_contains "/adr help mentions reject" "$RESP" "/adr reject"
assert_contains "/adr help mentions supersede" "$RESP" "/adr supersede"

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
echo "--- Test 5: /adr list (empty workspace) via slack-proxy ---"
# Use a unique team that has no ADRs (list is workspace-scoped)
BODY='command=%2Fadr&text=list&team_id=T_EMPTY_WS&channel_id=C_EMPTY&user_id=U_SMOKE&trigger_id=trig4'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr list shows no ADRs in empty workspace" "$RESP" "No ADRs found"

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
echo "--- Test 12: Modal submission (create ADR) via slack-proxy ---"
# Enable channel for team_id lookup
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_MODAL', 'C_MODAL', true) ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;" 2>/dev/null
MODAL_PAYLOAD=$(python3 -c "
import json, urllib.parse
payload = {
    'type': 'view_submission',
    'user': {'id': 'U_MODAL'},
    'view': {
        'private_metadata': 'C_MODAL||',
        'state': {
            'values': {
                'title_block': {'title_input': {'value': 'Smoke Test Modal ADR'}},
                'context_block': {'context_input': {'value': 'Testing modal submission'}},
                'decision_block': {'decision_input': {'value': None}},
                'alternatives_block': {'alternatives_input': {'value': None}},
                'consequences_block': {'consequences_input': {'value': None}},
                'open_questions_block': {'open_questions_input': {'value': None}},
                'decision_drivers_block': {'decision_drivers_input': {'value': None}},
                'implementation_plan_block': {'implementation_plan_input': {'value': None}},
                'reviewers_block': {'reviewers_input': {'value': None}}
            }
        }
    }
}
print('payload=' + urllib.parse.quote(json.dumps(payload)))
")
# Modal submission is synchronous — single request
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "$MODAL_PAYLOAD")
assert_status "Modal submission returns 200" "$STATUS" "200"
# Verify ADR was created in database
ADR_CHECK=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT count(*) FROM adrs WHERE title = 'Smoke Test Modal ADR';" 2>/dev/null | tr -d ' \n')
if [ "$ADR_CHECK" -ge 1 ]; then
  echo "  PASS: Modal submission created ADR in database"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Modal submission did not create ADR (count=$ADR_CHECK)"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
echo "--- Test 13: Interactive block action (accept_adr) via slack-proxy ---"
# Create an ADR to accept
ACCEPT_ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT (create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Accept Test ADR', 'ctx')).id;" 2>/dev/null | tr -d ' \n')
# Build signed interactive payload (Edge Function forwards headers to PostgREST)
ACCEPT_FORM=$(python3 -c "
import json, urllib.parse
payload = {
    'type': 'block_actions',
    'team': {'id': 'T_SMOKE'},
    'user': {'id': 'U_REVIEWER'},
    'actions': [{'action_id': 'accept_adr', 'value': '$ACCEPT_ADR_ID'}],
    'channel': {'id': 'C_SMOKE'},
    'trigger_id': 'trig_accept'
}
print('payload=' + urllib.parse.quote(json.dumps(payload)))
")
read -r TS SIG <<< "$(sign_request "$ACCEPT_FORM")"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$ACCEPT_FORM")
assert_status "Accept block action returns 200" "$STATUS" "200"
# Block actions are fire-and-forget — wait for background processing
sleep 2
ADR_STATE=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT state FROM adrs WHERE id = '$ACCEPT_ADR_ID';" 2>/dev/null | tr -d ' \n')
if [ "$ADR_STATE" = "ACCEPTED" ]; then
  echo "  PASS: ADR transitioned to ACCEPTED"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ADR state is '$ADR_STATE', expected 'ACCEPTED'"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
echo "--- Test 14: /adr view via slack-proxy ---"
BODY="command=%2Fadr&text=view+$ACCEPT_ADR_ID&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig6"
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr view shows ADR title" "$RESP" "Accept Test ADR"
assert_contains "/adr view shows ACCEPTED state" "$RESP" "ACCEPTED"

# ------------------------------------------------------------------
echo "--- Test 15: /adr list (with ADRs) via slack-proxy ---"
BODY='command=%2Fadr&text=list&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig7'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr list shows ADRs" "$RESP" "Accept Test ADR"

# ------------------------------------------------------------------
echo "--- Test 16: app_mention event via event-proxy ---"
# Enable a channel for mention testing
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_SMOKE', 'C_MENTION_SMOKE', true) ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;" 2>/dev/null
MENTION_BODY='{"type":"event_callback","team_id":"T_SMOKE","event":{"type":"app_mention","channel":"C_MENTION_SMOKE","ts":"8888888888.001","thread_ts":"8888888888.000","user":"U_MENTIONER","text":"<@ADR_BOT> let us record this decision"}}'
read -r TS SIG <<< "$(sign_request "$MENTION_BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/event-proxy" \
  -H "Content-Type: application/json" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$MENTION_BODY")
assert_contains "app_mention returns ok" "$RESP" "ok"
# Verify outbox row was created with Start ADR button
OUTBOX_CHECK=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT count(*) FROM adr_outbox WHERE destination = 'slack' AND payload::text LIKE '%Start ADR%' AND payload->>'channel' = 'C_MENTION_SMOKE';" 2>/dev/null | tr -d ' \n')
if [ "$OUTBOX_CHECK" -ge 1 ]; then
  echo "  PASS: app_mention created outbox row with Start ADR button"
  PASS=$((PASS + 1))
else
  echo "  FAIL: app_mention did not create outbox row (count=$OUTBOX_CHECK)"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
echo "--- Test 17: Modal submission validation errors ---"
VALIDATION_PAYLOAD=$(python3 -c "
import json, urllib.parse
payload = {
    'type': 'view_submission',
    'user': {'id': 'U_VALIDATE'},
    'view': {
        'private_metadata': 'C_MODAL||',
        'state': {
            'values': {
                'title_block': {'title_input': {'value': None}},
                'context_block': {'context_input': {'value': None}},
                'decision_block': {'decision_input': {'value': None}},
                'alternatives_block': {'alternatives_input': {'value': None}},
                'consequences_block': {'consequences_input': {'value': None}},
                'open_questions_block': {'open_questions_input': {'value': None}},
                'decision_drivers_block': {'decision_drivers_input': {'value': None}},
                'implementation_plan_block': {'implementation_plan_input': {'value': None}},
                'reviewers_block': {'reviewers_input': {'value': None}}
            }
        }
    }
}
print('payload=' + urllib.parse.quote(json.dumps(payload)))
")
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "$VALIDATION_PAYLOAD")
assert_contains "Validation returns response_action errors" "$RESP" "response_action"
assert_contains "Validation flags title_block" "$RESP" "title_block"
assert_contains "Validation flags context_block" "$RESP" "context_block"

# ------------------------------------------------------------------
echo "--- Test 18: Edit ADR modal submission via slack-proxy ---"
# Create an ADR to edit
EDIT_ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT (create_adr('T_MODAL', 'C_MODAL', 'U_EDITOR', 'Original Smoke Title', 'Original context')).id;" 2>/dev/null | tr -d ' \n')
EDIT_PAYLOAD=$(python3 -c "
import json, urllib.parse
payload = {
    'type': 'view_submission',
    'user': {'id': 'U_EDITOR'},
    'view': {
        'private_metadata': 'C_MODAL||$EDIT_ADR_ID',
        'state': {
            'values': {
                'title_block': {'title_input': {'value': 'Updated Smoke Title'}},
                'context_block': {'context_input': {'value': 'Updated smoke context'}},
                'decision_block': {'decision_input': {'value': 'New decision'}},
                'alternatives_block': {'alternatives_input': {'value': None}},
                'consequences_block': {'consequences_input': {'value': None}},
                'open_questions_block': {'open_questions_input': {'value': None}},
                'decision_drivers_block': {'decision_drivers_input': {'value': None}},
                'implementation_plan_block': {'implementation_plan_input': {'value': None}},
                'reviewers_block': {'reviewers_input': {'value': None}}
            }
        }
    }
}
print('payload=' + urllib.parse.quote(json.dumps(payload)))
")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "$EDIT_PAYLOAD")
assert_status "Edit modal submission returns 200" "$STATUS" "200"
# Verify ADR was updated
UPDATED_TITLE=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qtA -c \
  "SELECT title FROM adrs WHERE id = '$EDIT_ADR_ID';" 2>/dev/null)
if [ "$UPDATED_TITLE" = "Updated Smoke Title" ]; then
  echo "  PASS: Edit modal updated ADR title in database"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ADR title is '$UPDATED_TITLE', expected 'Updated Smoke Title'"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
echo "--- Test 19: /adr search via slack-proxy ---"
# Search for the ADR created in test 12
BODY='command=%2Fadr&text=search+Smoke+Test+Modal&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_search'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr search finds ADR" "$RESP" "Smoke Test Modal"

# ------------------------------------------------------------------
echo "--- Test 20: /adr search with no results ---"
BODY='command=%2Fadr&text=search+xyznonexistent99&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_search2'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr search no results" "$RESP" "No ADRs found"

# ------------------------------------------------------------------
echo "--- Test 21: /adr reject via slack-proxy ---"
# Create an ADR to reject
REJECT_ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT (create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Reject Smoke ADR', 'ctx')).id;" 2>/dev/null | tr -d ' \n')
BODY="command=%2Fadr&text=reject+$REJECT_ADR_ID&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_reject"
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr reject shows REJECTED" "$RESP" "REJECTED"
# Verify state in DB
REJECT_STATE=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qtA -c \
  "SELECT state FROM adrs WHERE id = '$REJECT_ADR_ID';" 2>/dev/null)
if [ "$REJECT_STATE" = "REJECTED" ]; then
  echo "  PASS: ADR transitioned to REJECTED via slash command"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ADR state is '$REJECT_STATE', expected 'REJECTED'"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
echo "--- Test 22: /adr supersede via slack-proxy ---"
# Create and accept an ADR to supersede
SUPERSEDE_ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT (create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Supersede Smoke ADR', 'ctx')).id;" 2>/dev/null | tr -d ' \n')
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT apply_adr_event('$SUPERSEDE_ADR_ID', 'ADR_ACCEPTED', 'user', 'U_SMOKE');" 2>/dev/null
BODY="command=%2Fadr&text=supersede+$SUPERSEDE_ADR_ID&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_supersede"
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr supersede shows SUPERSEDED" "$RESP" "SUPERSEDED"
# Verify state in DB
SUPERSEDE_STATE=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qtA -c \
  "SELECT state FROM adrs WHERE id = '$SUPERSEDE_ADR_ID';" 2>/dev/null)
if [ "$SUPERSEDE_STATE" = "SUPERSEDED" ]; then
  echo "  PASS: ADR transitioned to SUPERSEDED via slash command"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ADR state is '$SUPERSEDE_STATE', expected 'SUPERSEDED'"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
echo "--- Test 23: /adr accept via slack-proxy ---"
ACCEPT_ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qtA -c \
  "SELECT (create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Accept Smoke ADR', 'ctx')).id;" 2>/dev/null)
BODY="command=%2Fadr&text=accept+$ACCEPT_ADR_ID&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_accept"
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr accept shows ACCEPTED" "$RESP" "ACCEPTED"
# Verify state in DB
ACCEPT_STATE=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qtA -c \
  "SELECT state FROM adrs WHERE id = '$ACCEPT_ADR_ID';" 2>/dev/null)
if [ "$ACCEPT_STATE" = "ACCEPTED" ]; then
  echo "  PASS: ADR transitioned to ACCEPTED via slash command"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ADR state is '$ACCEPT_STATE', expected 'ACCEPTED'"
  FAIL=$((FAIL + 1))
fi

# ------------------------------------------------------------------
echo "--- Test 24: Help text includes /adr accept ---"
BODY='command=%2Fadr&text=help&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_help2'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "Help includes /adr accept" "$RESP" "/adr accept"

# ------------------------------------------------------------------
echo "--- Test 25: /adr list draft via slack-proxy ---"
# Create a draft ADR
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qtA -c \
  "SELECT (create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Filter Draft ADR', 'ctx')).id;" 2>/dev/null
BODY='command=%2Fadr&text=list+draft&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_listdraft'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr list draft shows DRAFT ADRs" "$RESP" "DRAFT"

# ------------------------------------------------------------------
echo "--- Test 26: /adr list accepted filters correctly ---"
BODY='command=%2Fadr&text=list+accepted&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_listacc'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr list accepted shows ACCEPTED heading" "$RESP" "ACCEPTED"

# ------------------------------------------------------------------
echo "--- Test 27: /adr stats via slack-proxy ---"
BODY='command=%2Fadr&text=stats&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_stats'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr stats shows overview" "$RESP" "Workspace ADR Overview"

# ------------------------------------------------------------------
echo "--- Test 28: /adr list pagination hint via slack-proxy ---"
# Create enough ADRs to trigger pagination (need >20 in T_SMOKE workspace)
for i in $(seq 1 21); do
  psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
    "SELECT create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Bulk ADR $i', 'ctx');" 2>/dev/null >/dev/null
done
BODY='command=%2Fadr&text=list&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_page'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr list shows page hint" "$RESP" "page"

# ------------------------------------------------------------------
echo "--- Test 29: /adr help includes page syntax ---"
BODY='command=%2Fadr&text=help&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_help2'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr help includes page syntax" "$RESP" "page N"

# ------------------------------------------------------------------
echo "--- Test 30: /adr disable via slack-proxy ---"
# Re-enable first since Test 16 added the channel, and /adr disable needs it enabled
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "UPDATE channel_config SET enabled = true WHERE team_id = 'T_SMOKE' AND channel_id = 'C_SMOKE';" 2>/dev/null
BODY='command=%2Fadr&text=disable&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig5'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr disable confirms" "$RESP" "disabled"

# ------------------------------------------------------------------
echo "--- Test 31: /adr health via slack-proxy ---"
BODY='command=%2Fadr&text=health&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_health'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr health shows system status" "$RESP" "System Health"

# ------------------------------------------------------------------
echo "--- Test 32: /adr export via slack-proxy ---"
# Create an ADR to export
EXPORT_ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT (create_adr('T_SMOKE', 'C_SMOKE', 'U_SMOKE', 'Export Smoke ADR', 'ctx')).id;" 2>/dev/null | tr -d ' \n')
BODY="command=%2Fadr&text=export+${EXPORT_ADR_ID}&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_export"
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr export starts export" "$RESP" "Export started"

# ------------------------------------------------------------------
echo "--- Test 33: /adr help includes export command ---"
BODY='command=%2Fadr&text=help&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_helpexp'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr help includes export" "$RESP" "export"

# ------------------------------------------------------------------
echo "--- Test 34: /adr history via slack-proxy ---"
# Use an ADR created earlier in the smoke test (from Test 12's modal submission)
HISTORY_ADR_ID=$(psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -qt -c \
  "SELECT id FROM adrs WHERE team_id = 'T_SMOKE' ORDER BY created_at LIMIT 1;" 2>/dev/null | tr -d ' \n')
BODY="command=%2Fadr&text=history+${HISTORY_ADR_ID}&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_hist"
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr history shows events" "$RESP" "ADR_CREATED"
assert_contains "/adr history shows history header" "$RESP" "History for"

# ------------------------------------------------------------------
echo "--- Test 35: /adr help includes history command ---"
BODY='command=%2Fadr&text=help&team_id=T_SMOKE&channel_id=C_SMOKE&user_id=U_SMOKE&trigger_id=trig_helphist'
read -r TS SIG <<< "$(sign_request "$BODY")"
RESP=$(curl -s -X POST "$BASE_URL/functions/v1/slack-proxy" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-Slack-Signature: $SIG" \
  -H "X-Slack-Request-Timestamp: $TS" \
  -d "$BODY")
assert_contains "/adr help includes history" "$RESP" "history"

# ------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
