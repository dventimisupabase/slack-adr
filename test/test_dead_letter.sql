-- test/test_dead_letter.sql
-- Tests for Step 19: Dead-letter handling and outbox hygiene
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_dead_letter.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';
SET LOCAL app.test_secret_SUPABASE_URL = 'http://127.0.0.1:54321';
SET LOCAL app.test_secret_SUPABASE_SERVICE_ROLE_KEY = 'test-key';

-- Test 1: dead_letter_outbox marks exhausted rows as dead-lettered
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DL1', 'C_DL1', 'U_DL1', 'Dead letter test', 'ctx');

  -- Insert an exhausted outbox row (attempts >= max_attempts)
  INSERT INTO adr_outbox (adr_id, destination, payload, attempts, max_attempts, last_error, created_at)
  VALUES (rec.id, 'slack', '{"channel":"C_DL1","text":"test"}'::jsonb, 5, 5, 'HTTP 500: Server Error', now() - interval '1 hour')
  RETURNING id INTO ob_id;

  PERFORM dead_letter_outbox();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NOT NULL,
    'Dead-lettered row should have delivered_at set';
  ASSERT ob.last_error LIKE '%DEAD_LETTER%',
    format('last_error should be marked DEAD_LETTER, got %s', ob.last_error);
  RAISE NOTICE 'PASS: Test 1 - dead_letter_outbox marks exhausted rows';
END;
$$;

-- Test 2: dead_letter_outbox ignores rows that still have retries remaining
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DL2', 'C_DL2', 'U_DL2', 'Not exhausted test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, attempts, max_attempts, last_error, created_at)
  VALUES (rec.id, 'slack', '{"channel":"C_DL2","text":"test"}'::jsonb, 3, 5, 'HTTP 500: temp', now() - interval '1 hour')
  RETURNING id INTO ob_id;

  PERFORM dead_letter_outbox();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NULL,
    'Row with retries remaining should NOT be dead-lettered';
  RAISE NOTICE 'PASS: Test 2 - dead_letter_outbox ignores rows with retries remaining';
END;
$$;

-- Test 3: dead_letter_outbox ignores already delivered rows
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
  orig_error text;
BEGIN
  rec := create_adr('T_DL3', 'C_DL3', 'U_DL3', 'Already delivered test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, attempts, max_attempts, delivered_at, last_error)
  VALUES (rec.id, 'slack', '{"channel":"C_DL3","text":"test"}'::jsonb, 5, 5, now(), NULL)
  RETURNING id INTO ob_id;

  PERFORM dead_letter_outbox();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.last_error IS NULL,
    'Already delivered row should not be modified';
  RAISE NOTICE 'PASS: Test 3 - dead_letter_outbox ignores already delivered rows';
END;
$$;

-- Test 4: purge_old_outbox removes delivered rows older than retention period
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  cnt int;
BEGIN
  rec := create_adr('T_DL4', 'C_DL4', 'U_DL4', 'Purge test', 'ctx');

  -- Insert a very old delivered row
  INSERT INTO adr_outbox (adr_id, destination, payload, delivered_at, created_at)
  VALUES (rec.id, 'slack', '{"channel":"C_DL4","text":"old"}'::jsonb,
          now() - interval '31 days', now() - interval '31 days')
  RETURNING id INTO ob_id;

  PERFORM purge_old_outbox();

  SELECT count(*) INTO cnt FROM adr_outbox WHERE id = ob_id;
  ASSERT cnt = 0,
    'Old delivered row should be purged';
  RAISE NOTICE 'PASS: Test 4 - purge_old_outbox removes old delivered rows';
END;
$$;

-- Test 5: purge_old_outbox keeps recent delivered rows
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  cnt int;
BEGIN
  rec := create_adr('T_DL5', 'C_DL5', 'U_DL5', 'Keep recent test', 'ctx');

  -- Insert a recently delivered row
  INSERT INTO adr_outbox (adr_id, destination, payload, delivered_at, created_at)
  VALUES (rec.id, 'slack', '{"channel":"C_DL5","text":"recent"}'::jsonb,
          now() - interval '1 day', now() - interval '1 day')
  RETURNING id INTO ob_id;

  PERFORM purge_old_outbox();

  SELECT count(*) INTO cnt FROM adr_outbox WHERE id = ob_id;
  ASSERT cnt = 1,
    'Recently delivered row should be kept';
  RAISE NOTICE 'PASS: Test 5 - purge_old_outbox keeps recent delivered rows';
END;
$$;

-- Test 6: purge_old_outbox keeps undelivered rows regardless of age
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  cnt int;
BEGIN
  rec := create_adr('T_DL6', 'C_DL6', 'U_DL6', 'Keep undelivered test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, created_at)
  VALUES (rec.id, 'slack', '{"channel":"C_DL6","text":"stuck"}'::jsonb,
          now() - interval '60 days')
  RETURNING id INTO ob_id;

  PERFORM purge_old_outbox();

  SELECT count(*) INTO cnt FROM adr_outbox WHERE id = ob_id;
  ASSERT cnt = 1,
    'Undelivered rows should NOT be purged regardless of age';
  RAISE NOTICE 'PASS: Test 6 - purge_old_outbox keeps undelivered rows';
END;
$$;

ROLLBACK;
