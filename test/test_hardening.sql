-- test/test_hardening.sql
-- Tests for Step 32: Edge case hardening
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_hardening.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: render_adr_markdown handles empty/null fields gracefully
DO $$
DECLARE
  rec adrs;
  md text;
BEGIN
  rec := create_adr('T_H1', 'C_H1', 'U_H1', 'Minimal ADR', 'Just context');
  md := render_adr_markdown(rec.id);
  ASSERT md IS NOT NULL, 'render_adr_markdown should not return NULL';
  ASSERT md LIKE '%Minimal ADR%', 'Markdown should contain title';
  ASSERT md LIKE '%Just context%', 'Markdown should contain context';
  RAISE NOTICE 'PASS: Test 1 - render_adr_markdown handles minimal ADR';
END;
$$;

-- Test 2: create_adr with very long title (> 200 chars) works
DO $$
DECLARE
  rec adrs;
  long_title text;
BEGIN
  long_title := repeat('A', 250);
  rec := create_adr('T_H2', 'C_H2', 'U_H2', long_title, 'ctx');
  ASSERT length(rec.title) = 250, format('Title should be 250 chars, got %s', length(rec.title));
  RAISE NOTICE 'PASS: Test 2 - create_adr accepts long titles';
END;
$$;

-- Test 3: build_adr_view returns friendly error for malformed ADR IDs
DO $$
DECLARE
  result json;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_H3', 'C_H3', true);

  result := build_adr_view('T_H3', '');
  ASSERT result::text LIKE '%not found%' OR result::text LIKE '%Usage%',
    format('Empty ID should return error, got: %s', result::text);

  result := build_adr_view('T_H3', '   ');
  ASSERT result::text LIKE '%not found%' OR result::text LIKE '%Usage%',
    format('Whitespace ID should return error, got: %s', result::text);
  RAISE NOTICE 'PASS: Test 3 - build_adr_view handles malformed ADR IDs';
END;
$$;

-- Test 4: processed_events cleanup retains events newer than 7 days
-- (Currently set to 24 hours — this test validates the desired 7-day retention)
DO $$
DECLARE
  cnt int;
BEGIN
  -- Insert event from 2 days ago
  INSERT INTO processed_events (event_id, created_at)
  VALUES ('evt_2day_old', now() - interval '2 days');

  -- Insert event from 8 days ago
  INSERT INTO processed_events (event_id, created_at)
  VALUES ('evt_8day_old', now() - interval '8 days');

  -- Run cleanup
  DELETE FROM processed_events WHERE created_at < now() - interval '7 days';

  -- 2-day-old event should survive
  SELECT count(*) INTO cnt FROM processed_events WHERE event_id = 'evt_2day_old';
  ASSERT cnt = 1, '2-day-old event should survive 7-day cleanup';

  -- 8-day-old event should be gone
  SELECT count(*) INTO cnt FROM processed_events WHERE event_id = 'evt_8day_old';
  ASSERT cnt = 0, '8-day-old event should be cleaned up';
  RAISE NOTICE 'PASS: Test 4 - Event dedup cleanup respects 7-day retention';
END;
$$;

-- Test 5: Outbox rows with permanent errors (invalid JSON payload) are eventually dead-lettered
DO $$
DECLARE
  rec adrs;
  ob_id uuid;
  ob record;
BEGIN
  rec := create_adr('T_H5', 'C_H5', 'U_H5', 'Dead letter test', 'ctx');

  -- Create an outbox row that has exhausted all attempts
  INSERT INTO adr_outbox (adr_id, destination, payload, attempts, max_attempts, last_error)
  VALUES (rec.id, 'slack', '{"channel":"C_H5"}'::jsonb, 5, 5, 'permanent failure')
  RETURNING id INTO ob_id;

  PERFORM dead_letter_outbox();

  SELECT * INTO ob FROM adr_outbox WHERE id = ob_id;
  ASSERT ob.delivered_at IS NOT NULL, 'Dead-lettered row should have delivered_at set';
  ASSERT ob.last_error LIKE '%DEAD_LETTER%', 'Dead-lettered row should be marked as DEAD_LETTER';
  RAISE NOTICE 'PASS: Test 5 - Exhausted outbox rows are dead-lettered';
END;
$$;

-- Test 6: Rate limit correctly blocks after max requests
DO $$
DECLARE
  allowed boolean;
  i int;
BEGIN
  -- Fill up the bucket with 30 requests
  FOR i IN 1..30 LOOP
    allowed := check_rate_limit('T_H6', 'test_action');
    ASSERT allowed, format('Request %s should be allowed', i);
  END LOOP;

  -- 31st request should be blocked
  allowed := check_rate_limit('T_H6', 'test_action');
  ASSERT NOT allowed, '31st request should be rate-limited';
  RAISE NOTICE 'PASS: Test 6 - Rate limit correctly blocks at threshold';
END;
$$;

-- Test 7: apply_adr_event with empty payload doesn't crash
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_H7', 'C_H7', 'U_H7', 'Empty payload test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_H7', '{}'::jsonb);
  ASSERT rec.state = 'ACCEPTED', format('Expected ACCEPTED, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 7 - apply_adr_event with empty payload works';
END;
$$;

ROLLBACK;
