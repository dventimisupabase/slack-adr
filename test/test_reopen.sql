-- test/test_reopen.sql
-- Tests for Step 41: /adr reopen command
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_reopen.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: REJECTED + ADR_REOPENED → DRAFT
DO $$
BEGIN
  ASSERT compute_adr_next_state('REJECTED', 'ADR_REOPENED') = 'DRAFT',
    'REJECTED + ADR_REOPENED should return DRAFT';
  RAISE NOTICE 'PASS: Test 1 - REJECTED + ADR_REOPENED → DRAFT';
END;
$$;

-- Test 2: DRAFT + ADR_REOPENED is invalid
DO $$
DECLARE
  result adr_state;
BEGIN
  result := compute_adr_next_state('DRAFT', 'ADR_REOPENED');
  RAISE NOTICE 'FAIL: Test 2 - Should have raised exception';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'PASS: Test 2 - DRAFT + ADR_REOPENED raises exception';
END;
$$;

-- Test 3: ACCEPTED + ADR_REOPENED is invalid
DO $$
DECLARE
  result adr_state;
BEGIN
  result := compute_adr_next_state('ACCEPTED', 'ADR_REOPENED');
  RAISE NOTICE 'FAIL: Test 3 - Should have raised exception';
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'PASS: Test 3 - ACCEPTED + ADR_REOPENED raises exception';
END;
$$;

-- Test 4: /adr reopen transitions REJECTED → DRAFT
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_RO4', 'C_RO4', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_RO4', 'C_RO4', 'U_RO4', 'Reopen Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_RO4',
    jsonb_build_object('reason', 'Too early'));

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=reopen+%s+Revisiting+after+feedback&team_id=T_RO4&channel_id=C_RO4&user_id=U_RO4',
    rec.id));
  result_text := result::text;

  ASSERT result_text LIKE '%DRAFT%',
    format('Should show DRAFT, got: %s', left(result_text, 200));

  SELECT state INTO rec.state FROM adrs WHERE id = rec.id;
  ASSERT rec.state = 'DRAFT', format('ADR should be DRAFT, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 4 - /adr reopen transitions REJECTED → DRAFT';
END;
$$;

-- Test 5: /adr reopen with reason stores reason
DO $$
DECLARE
  rec adrs;
  result json;
  evt_payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_RO5', 'C_RO5', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_RO5', 'C_RO5', 'U_RO5', 'Reopen Reason', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_RO5');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=reopen+%s+New+evidence+available&team_id=T_RO5&channel_id=C_RO5&user_id=U_RO5',
    rec.id));

  SELECT payload INTO evt_payload FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_REOPENED'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT evt_payload->>'reason' = 'New evidence available',
    format('Should store reason, got: %s', evt_payload);
  RAISE NOTICE 'PASS: Test 5 - /adr reopen stores reason in event payload';
END;
$$;

-- Test 6: /adr reopen on DRAFT fails
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_RO6', 'C_RO6', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_RO6', 'C_RO6', 'U_RO6', 'Already Draft', 'ctx');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=reopen+%s&team_id=T_RO6&channel_id=C_RO6&user_id=U_RO6',
    rec.id));
  result_text := result::text;

  ASSERT result_text LIKE '%Error%' OR result_text LIKE '%Invalid%',
    format('Should show error for DRAFT reopen, got: %s', left(result_text, 200));
  RAISE NOTICE 'PASS: Test 6 - /adr reopen on DRAFT fails';
END;
$$;

-- Test 7: Help text includes reopen command
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := handle_slack_webhook('command=%2Fadr&text=help&team_id=T_RO7&channel_id=C_RO7&user_id=U_RO7');
  result_text := result::text;
  ASSERT result_text LIKE '%reopen%',
    format('Help should include reopen, got: %s', left(result_text, 500));
  RAISE NOTICE 'PASS: Test 7 - Help text includes reopen command';
END;
$$;

ROLLBACK;
