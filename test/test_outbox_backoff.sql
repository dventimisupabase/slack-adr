-- test/test_outbox_backoff.sql
-- Tests for Step 17: Outbox retry backoff and ADR_UPDATED notification
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_outbox_backoff.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';
SET LOCAL app.test_secret_SUPABASE_URL = 'http://127.0.0.1:54321';
SET LOCAL app.test_secret_SUPABASE_SERVICE_ROLE_KEY = 'test-key';

-- Test 1: process_outbox skips rows that are too recent for retry
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_BO1', 'C_BO1', 'U_BO1', 'Backoff test', 'ctx');

  -- Manually insert a failed outbox row (attempt 2, should wait ~2 minutes)
  INSERT INTO adr_outbox (adr_id, destination, payload, attempts, last_error, created_at)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_BO1", "text": "test"}'::jsonb,
    2,
    'previous error',
    now() - interval '30 seconds'  -- Only 30s old, too soon for attempt 3
  )
  RETURNING id INTO ob_id;

  -- process_outbox should skip this row (needs 2^2 = 4 minute backoff)
  BEGIN
    PERFORM process_outbox();
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- pg_net may not be available
  END;

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  -- Should still have attempts=2 (not incremented)
  ASSERT ob.attempts = 2,
    format('Row should be skipped (backoff), attempts should be 2, got %s', ob.attempts);
  RAISE NOTICE 'PASS: Test 1 - process_outbox skips rows within backoff window';
END;
$$;

-- Test 2: process_outbox processes rows past their backoff window
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_BO2', 'C_BO2', 'U_BO2', 'Backoff expired test', 'ctx');

  -- Insert a failed outbox row (attempt 1, created 5 min ago — past 2^1=2 min backoff)
  INSERT INTO adr_outbox (adr_id, destination, payload, attempts, last_error, created_at)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_BO2", "text": "test"}'::jsonb,
    1,
    'previous error',
    now() - interval '5 minutes'  -- Old enough for retry
  )
  RETURNING id INTO ob_id;

  BEGIN
    PERFORM process_outbox();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  -- Should have been processed (attempts incremented or pg_net_request_id set)
  IF ob.pg_net_request_id IS NOT NULL THEN
    ASSERT ob.attempts >= 2,
      format('Attempts should be >= 2, got %s', ob.attempts);
    RAISE NOTICE 'PASS: Test 2 - process_outbox retries rows past backoff window (pg_net)';
  ELSE
    -- pg_net unavailable, check attempts incremented from error handler
    ASSERT ob.attempts >= 2,
      format('Attempts should be >= 2, got %s', ob.attempts);
    RAISE NOTICE 'PASS: Test 2 - process_outbox retries rows past backoff window (error path)';
  END IF;
END;
$$;

-- Test 3: Fresh outbox rows (attempts=0) are processed immediately
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_BO3', 'C_BO3', 'U_BO3', 'Fresh row test', 'ctx');

  -- Insert a fresh outbox row
  INSERT INTO adr_outbox (adr_id, destination, payload)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_BO3", "text": "test"}'::jsonb
  )
  RETURNING id INTO ob_id;

  BEGIN
    PERFORM process_outbox();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.attempts >= 1,
    format('Fresh row should be processed, attempts should be >= 1, got %s', ob.attempts);
  RAISE NOTICE 'PASS: Test 3 - Fresh outbox rows (attempts=0) processed immediately';
END;
$$;

-- Test 4: ADR_UPDATED creates outbox notification
DO $$
DECLARE
  rec adrs;
  cnt_before int;
  cnt_after int;
  has_update boolean;
BEGIN
  rec := create_adr('T_BO4', 'C_BO4', 'U_BO4', 'Update notify test', 'ctx');
  SELECT count(*) INTO cnt_before FROM adr_outbox WHERE adr_id = rec.id;

  -- Edit the ADR
  rec := apply_adr_event(rec.id, 'ADR_UPDATED', 'user', 'U_EDITOR',
    jsonb_build_object('title', 'Updated Title', 'context_text', 'Updated context'));

  SELECT count(*) INTO cnt_after FROM adr_outbox WHERE adr_id = rec.id;
  ASSERT cnt_after > cnt_before,
    format('ADR_UPDATED should create outbox row, before=%s after=%s', cnt_before, cnt_after);

  -- Check that at least one outbox row contains the updated title
  -- (can't rely on ORDER BY created_at since now() is transaction-scoped)
  SELECT EXISTS(
    SELECT 1 FROM adr_outbox
    WHERE adr_id = rec.id AND destination = 'slack'
      AND payload::text LIKE '%Updated Title%'
  ) INTO has_update;

  ASSERT has_update,
    'At least one outbox row should contain the updated title';
  RAISE NOTICE 'PASS: Test 4 - ADR_UPDATED creates outbox notification with Block Kit';
END;
$$;

-- Test 5: ADR_UPDATED notification is suppressed during interactive actions
DO $$
DECLARE
  rec adrs;
  cnt_before int;
  cnt_after int;
BEGIN
  rec := create_adr('T_BO5', 'C_BO5', 'U_BO5', 'Suppress update test', 'ctx');
  SELECT count(*) INTO cnt_before FROM adr_outbox WHERE adr_id = rec.id;

  -- Simulate interactive context (outbox suppressed)
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := apply_adr_event(rec.id, 'ADR_UPDATED', 'user', 'U_EDITOR',
    jsonb_build_object('title', 'Suppressed Title'));
  PERFORM set_config('app.suppress_outbox', 'false', true);

  SELECT count(*) INTO cnt_after FROM adr_outbox WHERE adr_id = rec.id;
  ASSERT cnt_after = cnt_before,
    format('Suppressed ADR_UPDATED should not create outbox row, before=%s after=%s',
      cnt_before, cnt_after);
  RAISE NOTICE 'PASS: Test 5 - ADR_UPDATED notification suppressed during interactive actions';
END;
$$;

ROLLBACK;
