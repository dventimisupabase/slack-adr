-- test/test_rate_limiting.sql
-- Tests for Step 27: Per-team rate limiting on slash commands
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_rate_limiting.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_RATE', 'C_RATE', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: check_rate_limit allows first request
DO $$
DECLARE ok boolean;
BEGIN
  ok := check_rate_limit('T_RATE', 'slash_command');
  ASSERT ok = true, 'First request should be allowed';
  RAISE NOTICE 'PASS: Test 1 - check_rate_limit allows first request';
END;
$$;

-- Test 2: check_rate_limit allows requests under the limit
DO $$
DECLARE ok boolean;
BEGIN
  -- Make 9 more requests (total 10 including test 1, but in separate transaction block)
  FOR i IN 1..9 LOOP
    ok := check_rate_limit('T_RATE', 'slash_command');
  END LOOP;
  ASSERT ok = true, 'Under-limit requests should be allowed';
  RAISE NOTICE 'PASS: Test 2 - check_rate_limit allows requests under limit';
END;
$$;

-- Test 3: check_rate_limit rejects requests over the limit
DO $$
DECLARE ok boolean;
BEGIN
  -- Fill up to limit
  FOR i IN 1..30 LOOP
    PERFORM check_rate_limit('T_RATE', 'slash_command');
  END LOOP;
  -- This one should be rejected
  ok := check_rate_limit('T_RATE', 'slash_command');
  ASSERT ok = false, format('Over-limit request should be rejected, got: %s', ok);
  RAISE NOTICE 'PASS: Test 3 - check_rate_limit rejects over-limit requests';
END;
$$;

-- Test 4: Rate limit is per-team (different team unaffected)
DO $$
DECLARE ok boolean;
BEGIN
  ok := check_rate_limit('T_RATE_OTHER', 'slash_command');
  ASSERT ok = true, 'Different team should not be rate-limited';
  RAISE NOTICE 'PASS: Test 4 - Rate limit is per-team';
END;
$$;

-- Test 5: handle_slack_webhook returns rate limit message
DO $$
DECLARE result json;
BEGIN
  -- Exhaust the limit for T_RL team
  FOR i IN 1..50 LOOP
    PERFORM check_rate_limit('T_RL', 'slash_command');
  END LOOP;

  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_RL&channel_id=C_RATE&user_id=U_RATE&trigger_id=t5'
  );
  ASSERT result->>'text' LIKE '%rate%limit%' OR result->>'text' LIKE '%slow down%' OR result->>'text' LIKE '%too many%',
    format('Should show rate limit message, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 5 - handle_slack_webhook returns rate limit message';
END;
$$;

-- Test 6: Rate limit window expires (simulated by cleaning old entries)
DO $$
DECLARE ok boolean;
BEGIN
  -- Clear old entries for T_RATE by backdating them
  UPDATE rate_limit_buckets SET window_start = now() - interval '2 minutes'
  WHERE team_id = 'T_RATE';

  ok := check_rate_limit('T_RATE', 'slash_command');
  ASSERT ok = true, 'Expired window should allow new requests';
  RAISE NOTICE 'PASS: Test 6 - Rate limit window expires and resets';
END;
$$;

ROLLBACK;
