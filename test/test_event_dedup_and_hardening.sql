-- test/test_event_dedup_and_hardening.sql
-- Tests for Step 29: Event deduplication + schema hardening
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_event_dedup_and_hardening.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_DEDUP', 'C_DEDUP', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: First app_mention event creates outbox row
DO $$
DECLARE
  result json;
  outbox_count int;
BEGIN
  result := handle_slack_event(json_build_object(
    'type', 'event_callback',
    'team_id', 'T_DEDUP',
    'event_id', 'Ev_FIRST_001',
    'event', json_build_object(
      'type', 'app_mention',
      'channel', 'C_DEDUP',
      'ts', '1700000001.000001',
      'user', 'U_DEDUP'
    )
  )::text);

  SELECT count(*) INTO outbox_count FROM adr_outbox WHERE destination = 'slack'
    AND payload::text LIKE '%C_DEDUP%' AND payload::text LIKE '%Start ADR%';

  ASSERT outbox_count >= 1, format('Should create outbox row, got count: %s', outbox_count);
  RAISE NOTICE 'PASS: Test 1 - First app_mention event creates outbox row';
END;
$$;

-- Test 2: Duplicate event_id is ignored (no second outbox row)
DO $$
DECLARE
  result json;
  outbox_before int;
  outbox_after int;
BEGIN
  SELECT count(*) INTO outbox_before FROM adr_outbox WHERE destination = 'slack'
    AND payload::text LIKE '%C_DEDUP%';

  result := handle_slack_event(json_build_object(
    'type', 'event_callback',
    'team_id', 'T_DEDUP',
    'event_id', 'Ev_FIRST_001',
    'event', json_build_object(
      'type', 'app_mention',
      'channel', 'C_DEDUP',
      'ts', '1700000001.000001',
      'user', 'U_DEDUP'
    )
  )::text);

  SELECT count(*) INTO outbox_after FROM adr_outbox WHERE destination = 'slack'
    AND payload::text LIKE '%C_DEDUP%';

  ASSERT outbox_after = outbox_before,
    format('Duplicate event should not create new outbox row: before=%s, after=%s', outbox_before, outbox_after);
  RAISE NOTICE 'PASS: Test 2 - Duplicate event_id is ignored';
END;
$$;

-- Test 3: Different event_id creates new outbox row
DO $$
DECLARE
  result json;
  outbox_before int;
  outbox_after int;
BEGIN
  SELECT count(*) INTO outbox_before FROM adr_outbox WHERE destination = 'slack'
    AND payload::text LIKE '%C_DEDUP%';

  result := handle_slack_event(json_build_object(
    'type', 'event_callback',
    'team_id', 'T_DEDUP',
    'event_id', 'Ev_SECOND_002',
    'event', json_build_object(
      'type', 'app_mention',
      'channel', 'C_DEDUP',
      'ts', '1700000002.000002',
      'user', 'U_DEDUP'
    )
  )::text);

  SELECT count(*) INTO outbox_after FROM adr_outbox WHERE destination = 'slack'
    AND payload::text LIKE '%C_DEDUP%';

  ASSERT outbox_after = outbox_before + 1,
    format('New event_id should create outbox row: before=%s, after=%s', outbox_before, outbox_after);
  RAISE NOTICE 'PASS: Test 3 - Different event_id creates new outbox row';
END;
$$;

-- Test 4: Event without event_id still processes (backwards compatible)
DO $$
DECLARE
  result json;
  outbox_before int;
  outbox_after int;
BEGIN
  SELECT count(*) INTO outbox_before FROM adr_outbox WHERE destination = 'slack'
    AND payload::text LIKE '%C_DEDUP%';

  result := handle_slack_event(json_build_object(
    'type', 'event_callback',
    'team_id', 'T_DEDUP',
    'event', json_build_object(
      'type', 'app_mention',
      'channel', 'C_DEDUP',
      'ts', '1700000003.000003',
      'user', 'U_DEDUP'
    )
  )::text);

  SELECT count(*) INTO outbox_after FROM adr_outbox WHERE destination = 'slack'
    AND payload::text LIKE '%C_DEDUP%';

  ASSERT outbox_after = outbox_before + 1,
    format('Event without event_id should still process: before=%s, after=%s', outbox_before, outbox_after);
  RAISE NOTICE 'PASS: Test 4 - Event without event_id still processes';
END;
$$;

-- Test 5: context_text NOT NULL constraint enforced
DO $$
BEGIN
  -- Attempt to insert ADR with NULL context_text via direct SQL
  BEGIN
    INSERT INTO adrs (id, version, state, team_id, channel_id, created_by, title, context_text)
    VALUES ('ADR-NULL-CTX', 1, 'DRAFT', 'T_DEDUP', 'C_DEDUP', 'U_DEDUP', 'Test', NULL);
    ASSERT false, 'Should have raised NOT NULL violation';
  EXCEPTION WHEN not_null_violation THEN
    RAISE NOTICE 'PASS: Test 5 - context_text NOT NULL constraint enforced';
  END;
END;
$$;

-- Test 6: Modal with NULL vals block returns error
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_modal_submission(json_build_object(
    'type', 'view_submission',
    'user', json_build_object('id', 'U_DEDUP'),
    'view', json_build_object(
      'private_metadata', 'C_DEDUP||',
      'state', json_build_object('values', NULL)
    )
  )::text);

  -- Should return validation error, not crash
  ASSERT result IS NOT NULL,
    format('Should handle NULL vals gracefully, got: %s', result);
  ASSERT result->>'response_action' = 'errors',
    format('Should return errors response, got: %s', result);
  RAISE NOTICE 'PASS: Test 6 - Modal with NULL vals returns error gracefully';
END;
$$;

-- Test 7: Pessimistic lock ensures apply_adr_event reads latest version
DO $$
DECLARE
  rec adrs;
  result adrs;
BEGIN
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := create_adr('T_DEDUP', 'C_DEDUP', 'U_DEDUP', 'Lock Test', 'context');

  -- Manually change version (simulates another transaction completing before us)
  UPDATE adrs SET version = 99 WHERE id = rec.id;

  -- apply_adr_event re-reads with FOR UPDATE, so it picks up version 99
  result := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_DEDUP');
  ASSERT result.version = 100,
    format('Should increment from latest version (99→100), got: %s', result.version);
  ASSERT result.state = 'ACCEPTED',
    format('Should be ACCEPTED, got: %s', result.state);
  RAISE NOTICE 'PASS: Test 7 - Pessimistic lock reads latest version';

  PERFORM set_config('app.suppress_outbox', 'false', true);
END;
$$;

-- Test 8: processed_events table exists and has unique constraint
DO $$
BEGIN
  -- Verify table exists by inserting
  INSERT INTO processed_events (event_id) VALUES ('test_event_123');
  -- Verify unique constraint
  BEGIN
    INSERT INTO processed_events (event_id) VALUES ('test_event_123');
    ASSERT false, 'Should have raised unique violation';
  EXCEPTION WHEN unique_violation THEN
    NULL; -- expected
  END;
  RAISE NOTICE 'PASS: Test 8 - processed_events table has unique constraint';
END;
$$;

ROLLBACK;
