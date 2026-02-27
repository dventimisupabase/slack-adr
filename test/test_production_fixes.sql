-- test/test_production_fixes.sql
-- Tests for Step 18: Production readiness fixes
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_production_fixes.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: check_outbox_deliveries does NOT delete net._http_response rows
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  resp_exists boolean;
BEGIN
  rec := create_adr('T_PF1', 'C_PF1', 'U_PF1', 'Response retention test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts)
  VALUES (rec.id, 'slack', '{"channel":"C_PF1","text":"test"}'::jsonb, -900, 1)
  RETURNING id INTO ob_id;

  INSERT INTO net._http_response (id, status_code, content, headers, timed_out)
  VALUES (-900, 200, '{"ok": true, "ts": "111.222"}', '{}'::jsonb, false);

  PERFORM check_outbox_deliveries();

  -- Response row should still exist for capture_thread_timestamps
  SELECT EXISTS(SELECT 1 FROM net._http_response WHERE id = -900) INTO resp_exists;
  ASSERT resp_exists,
    'net._http_response row should NOT be deleted by check_outbox_deliveries';
  RAISE NOTICE 'PASS: Test 1 - check_outbox_deliveries preserves net._http_response rows';

  DELETE FROM net._http_response WHERE id = -900;
END;
$$;

-- Test 2: capture_thread_timestamps reads ts from retained response
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ts_val text;
BEGIN
  rec := create_adr('T_PF2', 'C_PF2', 'U_PF2', 'Thread TS capture test', 'ctx');

  -- Simulate a delivered outbox row with response available
  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts, delivered_at)
  VALUES (rec.id, 'slack', '{"channel":"C_PF2","text":"test"}'::jsonb, -901, 1, now())
  RETURNING id INTO ob_id;

  INSERT INTO net._http_response (id, status_code, content, headers, timed_out)
  VALUES (-901, 200, '{"ok": true, "ts": "333.444"}', '{}'::jsonb, false);

  PERFORM capture_thread_timestamps();

  SELECT slack_message_ts INTO ts_val FROM adrs WHERE id = rec.id;
  ASSERT ts_val = '333.444',
    format('slack_message_ts should be 333.444, got %s', ts_val);
  RAISE NOTICE 'PASS: Test 2 - capture_thread_timestamps reads ts from response';

  DELETE FROM net._http_response WHERE id = -901;
END;
$$;

-- Test 3: Modal submission rejects channel with no config (team_id NULL)
DO $$
DECLARE
  result json;
  payload text;
BEGIN
  -- No channel_config for C_NOCONFIG — team_id lookup will be NULL
  payload := '{"type":"view_submission","user":{"id":"U_PF3"},"view":{"private_metadata":"C_NOCONFIG||","state":{"values":{"title_block":{"title_input":{"value":"Test ADR"}},"context_block":{"context_input":{"value":"ctx"}},"decision_block":{"decision_input":{"value":null}},"alternatives_block":{"alternatives_input":{"value":null}},"consequences_block":{"consequences_input":{"value":null}},"open_questions_block":{"open_questions_input":{"value":null}},"decision_drivers_block":{"decision_drivers_input":{"value":null}},"implementation_plan_block":{"implementation_plan_input":{"value":null}},"reviewers_block":{"reviewers_input":{"value":null}}}}}}';

  result := handle_slack_modal_submission(payload);

  -- Should return validation error, not NULL (not create ADR)
  ASSERT result IS NOT NULL,
    'Should return error for channel without config';
  ASSERT result::text LIKE '%enable%' OR result::text LIKE '%errors%',
    format('Should mention enable or return errors, got %s', result::text);

  -- Verify no ADR was created
  PERFORM 1 FROM adrs WHERE channel_id = 'C_NOCONFIG';
  ASSERT NOT FOUND,
    'No ADR should be created for unconfigured channel';
  RAISE NOTICE 'PASS: Test 3 - Modal submission rejects channel with no config';
END;
$$;

-- Test 4: recover_stuck_exports fails ADRs stuck in EXPORT_REQUESTED
DO $$
DECLARE
  rec adrs;
  recovered_state adr_state;
  outbox_count_before int;
  outbox_count_after int;
BEGIN
  rec := create_adr('T_PF4', 'C_PF4', 'U_PF4', 'Stuck export test', 'ctx');
  rec := apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_PF4');

  -- Backdate the export event to simulate stuck state
  UPDATE adr_events SET created_at = now() - interval '1 hour'
  WHERE adr_id = rec.id AND event_type = 'EXPORT_REQUESTED';

  SELECT count(*) INTO outbox_count_before FROM adr_outbox
  WHERE adr_id = rec.id AND destination = 'slack';

  PERFORM recover_stuck_exports();

  SELECT state INTO recovered_state FROM adrs WHERE id = rec.id;
  ASSERT recovered_state = 'DRAFT',
    format('Stuck export should be recovered to DRAFT, got %s', recovered_state);

  -- Should have enqueued a failure notification
  SELECT count(*) INTO outbox_count_after FROM adr_outbox
  WHERE adr_id = rec.id AND destination = 'slack';
  ASSERT outbox_count_after > outbox_count_before,
    'Should enqueue failure notification';

  RAISE NOTICE 'PASS: Test 4 - recover_stuck_exports fails stuck exports';
END;
$$;

-- Test 5: recover_stuck_exports ignores recent exports
DO $$
DECLARE
  rec adrs;
  rec_state adr_state;
BEGIN
  rec := create_adr('T_PF5', 'C_PF5', 'U_PF5', 'Recent export test', 'ctx');
  rec := apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_PF5');

  -- Event is recent (just created), should not be recovered
  PERFORM recover_stuck_exports();

  SELECT state INTO rec_state FROM adrs WHERE id = rec.id;
  ASSERT rec_state = 'DRAFT',
    format('Recent export should still be DRAFT, got %s', rec_state);

  -- Check no EXPORT_FAILED event was created
  PERFORM 1 FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'EXPORT_FAILED';
  ASSERT NOT FOUND,
    'Recent export should not have EXPORT_FAILED event';
  RAISE NOTICE 'PASS: Test 5 - recover_stuck_exports ignores recent exports';
END;
$$;

ROLLBACK;
