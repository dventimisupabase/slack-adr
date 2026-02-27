-- test/test_outbox.sql
-- Tests for Step 6: Transactional outbox
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_outbox.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- ============================================================
-- Outbox table tests
-- ============================================================

-- Test 1: enqueue_outbox inserts a row
DO $$
DECLARE
  rec adrs;
  outbox_id uuid;
BEGIN
  rec := create_adr('T_OB', 'C_OB', 'U_OB', 'Outbox test', 'ctx');
  outbox_id := enqueue_outbox(
    rec.id, NULL, 'slack',
    '{"channel": "C_OB", "text": "hello"}'::jsonb
  );
  ASSERT outbox_id IS NOT NULL, 'enqueue_outbox should return an ID';

  PERFORM 1 FROM adr_outbox WHERE id = outbox_id AND destination = 'slack';
  ASSERT FOUND, 'Outbox row should exist';
  RAISE NOTICE 'PASS: Test 1 - enqueue_outbox inserts a row';
END;
$$;

-- Test 2: dispatch_side_effects creates outbox row on ADR_CREATED
DO $$
DECLARE
  rec adrs;
  outbox_count int;
BEGIN
  -- Count outbox rows before
  SELECT count(*) INTO outbox_count FROM adr_outbox;

  rec := create_adr('T_OB2', 'C_OB2', 'U_OB2', 'Dispatch test', 'ctx');

  -- Should have new outbox rows (ADR_CREATED triggers side effects)
  PERFORM 1 FROM adr_outbox
  WHERE adr_id = rec.id AND destination = 'slack';
  ASSERT FOUND, 'ADR_CREATED should enqueue a Slack outbox row';
  RAISE NOTICE 'PASS: Test 2 - dispatch_side_effects creates outbox row on ADR_CREATED';
END;
$$;

-- Test 3: dispatch_side_effects creates outbox row on state transition
DO $$
DECLARE
  rec adrs;
  outbox_count_before int;
  outbox_count_after int;
BEGIN
  rec := create_adr('T_OB3', 'C_OB3', 'U_OB3', 'Transition test', 'ctx');
  SELECT count(*) INTO outbox_count_before FROM adr_outbox WHERE adr_id = rec.id;

  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_REVIEWER');

  SELECT count(*) INTO outbox_count_after FROM adr_outbox WHERE adr_id = rec.id;
  ASSERT outbox_count_after > outbox_count_before,
    format('Expected more outbox rows after accept: before=%s after=%s',
      outbox_count_before, outbox_count_after);
  RAISE NOTICE 'PASS: Test 3 - dispatch_side_effects creates outbox row on state transition';
END;
$$;

-- Test 4: EXPORT_REQUESTED enqueues git-export outbox row
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_OB4', 'C_OB4', 'U_OB4', 'Export outbox test', 'ctx');
  rec := apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_OB4');

  PERFORM 1 FROM adr_outbox
  WHERE adr_id = rec.id AND destination = 'git-export';
  ASSERT FOUND, 'EXPORT_REQUESTED should enqueue a git-export outbox row';
  RAISE NOTICE 'PASS: Test 4 - EXPORT_REQUESTED enqueues git-export outbox row';
END;
$$;

-- Test 5: Outbox rows have correct default values
DO $$
DECLARE
  rec adrs;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_OB5', 'C_OB5', 'U_OB5', 'Defaults test', 'ctx');
  SELECT * INTO ob FROM adr_outbox WHERE adr_id = rec.id LIMIT 1;
  ASSERT ob.delivered_at IS NULL, 'delivered_at should be NULL';
  ASSERT ob.attempts = 0, format('attempts should be 0, got %s', ob.attempts);
  ASSERT ob.max_attempts = 5, format('max_attempts should be 5, got %s', ob.max_attempts);
  ASSERT ob.pg_net_request_id IS NULL, 'pg_net_request_id should be NULL';
  RAISE NOTICE 'PASS: Test 5 - Outbox rows have correct default values';
END;
$$;

ROLLBACK;
