-- test/test_transition_reason.sql
-- Tests for Step 39: Reason field on state transitions
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_transition_reason.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: /adr accept <id> <reason> stores reason in event payload
DO $$
DECLARE
  rec adrs;
  result json;
  evt_payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_TR1', 'C_TR1', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_TR1', 'C_TR1', 'U_TR1', 'Accept With Reason', 'ctx');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=accept+%s+Cost+is+acceptable&team_id=T_TR1&channel_id=C_TR1&user_id=U_TR1',
    rec.id));

  SELECT payload INTO evt_payload FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_ACCEPTED'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT evt_payload->>'reason' = 'Cost is acceptable',
    format('Should store reason, got: %s', evt_payload);
  RAISE NOTICE 'PASS: Test 1 - /adr accept stores reason in event payload';
END;
$$;

-- Test 2: /adr reject <id> <reason> stores reason
DO $$
DECLARE
  rec adrs;
  result json;
  evt_payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_TR2', 'C_TR2', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_TR2', 'C_TR2', 'U_TR2', 'Reject With Reason', 'ctx');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=reject+%s+Too+expensive&team_id=T_TR2&channel_id=C_TR2&user_id=U_TR2',
    rec.id));

  SELECT payload INTO evt_payload FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_REJECTED'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT evt_payload->>'reason' = 'Too expensive',
    format('Should store reason, got: %s', evt_payload);
  RAISE NOTICE 'PASS: Test 2 - /adr reject stores reason in event payload';
END;
$$;

-- Test 3: /adr supersede <id> <reason> stores reason
DO $$
DECLARE
  rec adrs;
  result json;
  evt_payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_TR3', 'C_TR3', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_TR3', 'C_TR3', 'U_TR3', 'Supersede With Reason', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_TR3');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=supersede+%s+Replaced+by+newer+approach&team_id=T_TR3&channel_id=C_TR3&user_id=U_TR3',
    rec.id));

  SELECT payload INTO evt_payload FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_SUPERSEDED'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT evt_payload->>'reason' = 'Replaced by newer approach',
    format('Should store reason, got: %s', evt_payload);
  RAISE NOTICE 'PASS: Test 3 - /adr supersede stores reason in event payload';
END;
$$;

-- Test 4: /adr accept <id> without reason still works (reason is optional)
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
  evt_payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_TR4', 'C_TR4', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_TR4', 'C_TR4', 'U_TR4', 'Accept Without Reason', 'ctx');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=accept+%s&team_id=T_TR4&channel_id=C_TR4&user_id=U_TR4',
    rec.id));
  result_text := result::text;

  ASSERT result_text LIKE '%ACCEPTED%',
    format('Should show ACCEPTED, got: %s', left(result_text, 200));

  SELECT payload INTO evt_payload FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_ACCEPTED'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT evt_payload IS NULL OR evt_payload->>'reason' IS NULL,
    format('No reason should be stored, got: %s', evt_payload);
  RAISE NOTICE 'PASS: Test 4 - /adr accept without reason still works';
END;
$$;

-- Test 5: /adr history shows reason when present
DO $$
DECLARE
  rec adrs;
  result json;
  history json;
  history_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_TR5', 'C_TR5', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_TR5', 'C_TR5', 'U_TR5', 'History Reason Test', 'ctx');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=accept+%s+Meets+all+requirements&team_id=T_TR5&channel_id=C_TR5&user_id=U_TR5',
    rec.id));

  history := build_adr_history('T_TR5', rec.id);
  history_text := history::text;

  ASSERT history_text LIKE '%Meets all requirements%',
    format('History should show reason, got: %s', left(history_text, 500));
  RAISE NOTICE 'PASS: Test 5 - /adr history shows reason when present';
END;
$$;

-- Test 6: Block Kit response shows reason for transition
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_TR6', 'C_TR6', true) ON CONFLICT DO NOTHING;

  rec := create_adr('T_TR6', 'C_TR6', 'U_TR6', 'Response Reason Test', 'ctx');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=reject+%s+Not+aligned+with+strategy&team_id=T_TR6&channel_id=C_TR6&user_id=U_TR6',
    rec.id));
  result_text := result::text;

  ASSERT result_text LIKE '%REJECTED%',
    format('Should show REJECTED state, got: %s', left(result_text, 200));
  RAISE NOTICE 'PASS: Test 6 - Block Kit response shows state after transition with reason';
END;
$$;

-- Test 7: Help text includes reason syntax
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := handle_slack_webhook('command=%2Fadr&text=help&team_id=T_TR7&channel_id=C_TR7&user_id=U_TR7');
  result_text := result::text;
  ASSERT result_text LIKE '%reason%',
    format('Help should mention reason, got: %s', left(result_text, 500));
  RAISE NOTICE 'PASS: Test 7 - Help text includes reason syntax';
END;
$$;

ROLLBACK;
