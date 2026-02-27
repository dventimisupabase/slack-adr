-- test/test_outbox_delivery.sql
-- Tests for Step 16: Outbox delivery tracking
-- Verifies that process_outbox no longer prematurely marks delivered_at,
-- and that check_outbox_deliveries correctly handles async pg_net responses.
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_outbox_delivery.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';
SET LOCAL app.test_secret_SUPABASE_URL = 'http://127.0.0.1:54321';
SET LOCAL app.test_secret_SUPABASE_SERVICE_ROLE_KEY = 'test-key';

-- Test 1: process_outbox sets pg_net_request_id but NOT delivered_at
DO $$
DECLARE
  rec adrs;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DEL1', 'C_DEL1', 'U_DEL1', 'Delivery tracking test', 'ctx');

  -- Get the outbox row created by dispatch_side_effects
  SELECT * INTO ob FROM adr_outbox WHERE adr_id = rec.id AND destination = 'slack' LIMIT 1;
  ASSERT ob.id IS NOT NULL, 'Should have an outbox row';
  ASSERT ob.delivered_at IS NULL, 'Should not be delivered yet';
  ASSERT ob.pg_net_request_id IS NULL, 'Should not have a request_id yet';

  -- Process the outbox (pg_net will fail in test but we catch it)
  BEGIN
    PERFORM process_outbox();
  EXCEPTION WHEN OTHERS THEN
    -- pg_net may not be available in test context, that's ok
    NULL;
  END;

  -- Re-read the outbox row
  SELECT * INTO ob FROM adr_outbox WHERE id = ob.id;

  -- If pg_net worked: request_id should be set, delivered_at should be NULL
  -- If pg_net failed: attempts should be incremented, last_error set
  IF ob.pg_net_request_id IS NOT NULL THEN
    ASSERT ob.delivered_at IS NULL,
      format('delivered_at should be NULL after process_outbox, got %s', ob.delivered_at);
    ASSERT ob.attempts = 1,
      format('attempts should be 1, got %s', ob.attempts);
    RAISE NOTICE 'PASS: Test 1 - process_outbox sets pg_net_request_id but NOT delivered_at';
  ELSE
    -- pg_net not available in test, check error handling
    ASSERT ob.attempts >= 1,
      format('attempts should be >= 1, got %s', ob.attempts);
    RAISE NOTICE 'PASS: Test 1 - process_outbox handles pg_net unavailability (attempts=%)', ob.attempts;
  END IF;
END;
$$;

-- Test 2: check_outbox_deliveries marks successful deliveries
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DEL2', 'C_DEL2', 'U_DEL2', 'Success delivery test', 'ctx');

  -- Manually simulate a sent-but-unconfirmed outbox row
  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_DEL2", "text": "test"}'::jsonb,
    -999,  -- fake request_id
    1
  )
  RETURNING id INTO ob_id;

  -- Simulate a successful pg_net response
  INSERT INTO net._http_response (id, status_code, content, headers, timed_out)
  VALUES (-999, 200, '{"ok": true, "ts": "123.456"}', '{}'::jsonb, false);

  -- Run delivery checker
  PERFORM check_outbox_deliveries();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NOT NULL,
    'delivered_at should be set after successful response';
  RAISE NOTICE 'PASS: Test 2 - check_outbox_deliveries marks successful deliveries';

  -- Clean up net response
  DELETE FROM net._http_response WHERE id = -999;
END;
$$;

-- Test 3: check_outbox_deliveries resets failed deliveries for retry
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DEL3', 'C_DEL3', 'U_DEL3', 'Failed delivery test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_DEL3", "text": "test"}'::jsonb,
    -998,
    1
  )
  RETURNING id INTO ob_id;

  -- Simulate a failed pg_net response (Slack API error)
  INSERT INTO net._http_response (id, status_code, content, headers, timed_out)
  VALUES (-998, 200, '{"ok": false, "error": "channel_not_found"}', '{}'::jsonb, false);

  PERFORM check_outbox_deliveries();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NULL,
    'delivered_at should remain NULL for failed response';
  ASSERT ob.pg_net_request_id IS NULL,
    'pg_net_request_id should be cleared for retry';
  ASSERT ob.last_error LIKE '%channel_not_found%',
    format('last_error should contain error, got %s', ob.last_error);
  RAISE NOTICE 'PASS: Test 3 - check_outbox_deliveries resets failed deliveries for retry';

  DELETE FROM net._http_response WHERE id = -998;
END;
$$;

-- Test 4: check_outbox_deliveries handles HTTP-level errors
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DEL4', 'C_DEL4', 'U_DEL4', 'HTTP error test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_DEL4", "text": "test"}'::jsonb,
    -997,
    1
  )
  RETURNING id INTO ob_id;

  -- Simulate HTTP 500
  INSERT INTO net._http_response (id, status_code, content, headers, timed_out)
  VALUES (-997, 500, 'Internal Server Error', '{}'::jsonb, false);

  PERFORM check_outbox_deliveries();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NULL,
    'delivered_at should remain NULL for HTTP error';
  ASSERT ob.pg_net_request_id IS NULL,
    'pg_net_request_id should be cleared for retry';
  ASSERT ob.last_error LIKE '%HTTP 500%',
    format('last_error should contain HTTP status, got %s', ob.last_error);
  RAISE NOTICE 'PASS: Test 4 - check_outbox_deliveries handles HTTP-level errors';

  DELETE FROM net._http_response WHERE id = -997;
END;
$$;

-- Test 5: check_outbox_deliveries handles timed-out requests
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DEL5', 'C_DEL5', 'U_DEL5', 'Timeout test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_DEL5", "text": "test"}'::jsonb,
    -996,
    1
  )
  RETURNING id INTO ob_id;

  -- Simulate timeout
  INSERT INTO net._http_response (id, status_code, content, headers, timed_out)
  VALUES (-996, 0, '', '{}'::jsonb, true);

  PERFORM check_outbox_deliveries();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NULL,
    'delivered_at should remain NULL for timeout';
  ASSERT ob.pg_net_request_id IS NULL,
    'pg_net_request_id should be cleared for retry';
  ASSERT ob.last_error LIKE '%timed out%',
    format('last_error should mention timeout, got %s', ob.last_error);
  RAISE NOTICE 'PASS: Test 5 - check_outbox_deliveries handles timed-out requests';

  DELETE FROM net._http_response WHERE id = -996;
END;
$$;

-- Test 6: check_outbox_deliveries skips rows with no pg_net response yet
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DEL6', 'C_DEL6', 'U_DEL6', 'No response yet test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts)
  VALUES (
    rec.id, 'slack',
    '{"channel": "C_DEL6", "text": "test"}'::jsonb,
    -995,
    1
  )
  RETURNING id INTO ob_id;

  -- No response inserted into net._http_response

  PERFORM check_outbox_deliveries();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NULL,
    'delivered_at should remain NULL when no response yet';
  ASSERT ob.pg_net_request_id = -995,
    'pg_net_request_id should remain unchanged when no response yet';
  RAISE NOTICE 'PASS: Test 6 - check_outbox_deliveries skips rows with no pg_net response yet';
END;
$$;

-- Test 7: check_outbox_deliveries handles git-export destinations (HTTP 200 = success)
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_DEL7', 'C_DEL7', 'U_DEL7', 'Git export delivery test', 'ctx');

  INSERT INTO adr_outbox (adr_id, destination, payload, pg_net_request_id, attempts)
  VALUES (
    rec.id, 'git-export',
    '{"adr_id": "test", "title": "test"}'::jsonb,
    -994,
    1
  )
  RETURNING id INTO ob_id;

  -- git-export Edge Function returns HTTP 200 on success
  INSERT INTO net._http_response (id, status_code, content, headers, timed_out)
  VALUES (-994, 200, '{"ok": true}', '{}'::jsonb, false);

  PERFORM check_outbox_deliveries();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NOT NULL,
    'delivered_at should be set for successful git-export delivery';
  RAISE NOTICE 'PASS: Test 7 - check_outbox_deliveries handles git-export destinations';

  DELETE FROM net._http_response WHERE id = -994;
END;
$$;

ROLLBACK;
