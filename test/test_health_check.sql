-- test/test_health_check.sql
-- Tests for Step 28: /adr health command (admin monitoring)
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_health_check.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_HEALTH', 'C_HEALTH', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: /adr health shows system status when healthy
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=health&team_id=T_HEALTH&channel_id=C_HEALTH&user_id=U_HEALTH&trigger_id=t1'
  );
  ASSERT result->>'text' LIKE '%System Health%' OR result->>'text' LIKE '%health%' OR result->>'text' LIKE '%Status%',
    format('Should show health status, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 1 - /adr health shows system status';
END;
$$;

-- Test 2: /adr health shows outbox pending count
DO $$
DECLARE result json;
BEGIN
  -- Create some outbox entries
  PERFORM set_config('app.suppress_outbox', 'false', true);
  PERFORM create_adr('T_HEALTH', 'C_HEALTH', 'U_HEALTH', 'Health Test ADR', 'ctx');

  result := handle_slack_webhook(
    'command=%2Fadr&text=health&team_id=T_HEALTH&channel_id=C_HEALTH&user_id=U_HEALTH&trigger_id=t2'
  );
  ASSERT result->>'text' LIKE '%outbox%' OR result->>'text' LIKE '%pending%' OR result->>'text' LIKE '%queue%',
    format('Should show outbox status, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 2 - /adr health shows outbox status';
END;
$$;

-- Test 3: /adr health shows dead letter count
DO $$
DECLARE result json;
BEGIN
  -- Create a dead letter entry
  INSERT INTO adr_outbox (adr_id, destination, payload, attempts, max_attempts, last_error)
  SELECT id, 'slack', '{}', 5, 5, 'test error'
  FROM adrs WHERE team_id = 'T_HEALTH' LIMIT 1;

  result := handle_slack_webhook(
    'command=%2Fadr&text=health&team_id=T_HEALTH&channel_id=C_HEALTH&user_id=U_HEALTH&trigger_id=t3'
  );
  ASSERT result->>'text' LIKE '%dead%letter%' OR result->>'text' LIKE '%failed%',
    format('Should show dead letter status, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 3 - /adr health shows dead letter count';
END;
$$;

-- Test 4: Help text includes health command
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_HEALTH&channel_id=C_HEALTH&user_id=U_HEALTH&trigger_id=t4'
  );
  ASSERT result->>'text' LIKE '%health%',
    format('Help should mention health, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 4 - Help text includes health command';
END;
$$;

-- Test 5: build_system_health returns structured data
DO $$
DECLARE result json;
BEGIN
  result := build_system_health();
  ASSERT result IS NOT NULL, 'build_system_health should return JSON';
  ASSERT result->>'text' IS NOT NULL, 'Should have text field';
  RAISE NOTICE 'PASS: Test 5 - build_system_health returns structured data';
END;
$$;

ROLLBACK;
