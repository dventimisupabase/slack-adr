-- test/test_stats_and_errors.sql
-- Tests for Step 25: /adr stats command + friendly state transition errors
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_stats_and_errors.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_STAT', 'C_STAT', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Seed ADRs in various states
DO $$
DECLARE r adrs;
BEGIN
  PERFORM create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Stats Draft 1', 'ctx');
  PERFORM create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Stats Draft 2', 'ctx');
  PERFORM create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Stats Draft 3', 'ctx');

  PERFORM set_config('app.suppress_outbox', 'true', true);

  r := create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Stats Accepted 1', 'ctx');
  PERFORM apply_adr_event(r.id, 'ADR_ACCEPTED', 'user', 'U_STAT');
  r := create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Stats Accepted 2', 'ctx');
  PERFORM apply_adr_event(r.id, 'ADR_ACCEPTED', 'user', 'U_STAT');

  r := create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Stats Rejected 1', 'ctx');
  PERFORM apply_adr_event(r.id, 'ADR_REJECTED', 'user', 'U_STAT');

  r := create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Stats Superseded 1', 'ctx');
  PERFORM apply_adr_event(r.id, 'ADR_ACCEPTED', 'user', 'U_STAT');
  PERFORM apply_adr_event(r.id, 'ADR_SUPERSEDED', 'user', 'U_STAT');

  PERFORM set_config('app.suppress_outbox', 'false', true);
END;
$$;

-- Test 1: /adr stats shows count per state
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=stats&team_id=T_STAT&channel_id=C_STAT&user_id=U_STAT&trigger_id=t1'
  );
  ASSERT result->>'text' LIKE '%DRAFT%' AND result->>'text' LIKE '%3%',
    format('Should show 3 drafts, got: %s', result->>'text');
  ASSERT result->>'text' LIKE '%ACCEPTED%' AND result->>'text' LIKE '%2%',
    format('Should show 2 accepted, got: %s', result->>'text');
  ASSERT result->>'text' LIKE '%REJECTED%' AND result->>'text' LIKE '%1%',
    format('Should show 1 rejected, got: %s', result->>'text');
  ASSERT result->>'text' LIKE '%SUPERSEDED%' AND result->>'text' LIKE '%1%',
    format('Should show 1 superseded, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 1 - /adr stats shows count per state';
END;
$$;

-- Test 2: /adr stats for empty workspace
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=stats&team_id=T_EMPTY_STATS&channel_id=C_EMPTY&user_id=U_STAT&trigger_id=t2'
  );
  ASSERT result->>'text' LIKE '%No ADRs%' OR result->>'text' LIKE '%0%',
    format('Empty workspace should show no ADRs, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 2 - /adr stats for empty workspace';
END;
$$;

-- Test 3: /adr stats shows total count
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=stats&team_id=T_STAT&channel_id=C_STAT&user_id=U_STAT&trigger_id=t3'
  );
  ASSERT result->>'text' LIKE '%7%',
    format('Should show 7 total, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 3 - /adr stats shows total count';
END;
$$;

-- Test 4: /adr accept on already-accepted ADR shows friendly error
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Already Accepted', 'ctx');
  PERFORM set_config('app.suppress_outbox', 'true', true);
  PERFORM apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_STAT');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=accept+%s&team_id=T_STAT&channel_id=C_STAT&user_id=U_STAT&trigger_id=t4', rec.id)
  );
  ASSERT result->>'text' LIKE '%currently ACCEPTED%' OR result->>'text' LIKE '%cannot%accept%' OR result->>'text' LIKE '%Invalid transition%',
    format('Should show friendly error for already accepted, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 4 - /adr accept on already-accepted shows friendly error';
END;
$$;

-- Test 5: /adr reject on rejected ADR shows friendly error
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Already Rejected', 'ctx');
  PERFORM set_config('app.suppress_outbox', 'true', true);
  PERFORM apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_STAT');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=reject+%s&team_id=T_STAT&channel_id=C_STAT&user_id=U_STAT&trigger_id=t5', rec.id)
  );
  ASSERT result->>'text' LIKE '%currently REJECTED%' OR result->>'text' LIKE '%cannot%reject%' OR result->>'text' LIKE '%Invalid transition%',
    format('Should explain the error, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 5 - /adr reject on rejected ADR shows friendly error';
END;
$$;

-- Test 6: /adr supersede on draft ADR shows friendly error
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_STAT', 'C_STAT', 'U_STAT', 'Draft Supersede Attempt', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=supersede+%s&team_id=T_STAT&channel_id=C_STAT&user_id=U_STAT&trigger_id=t6', rec.id)
  );
  ASSERT result->>'text' LIKE '%currently DRAFT%' OR result->>'text' LIKE '%cannot%supersede%' OR result->>'text' LIKE '%Invalid transition%',
    format('Should explain cannot supersede draft, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 6 - /adr supersede on draft shows friendly error';
END;
$$;

-- Test 7: Help text includes stats command
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_STAT&channel_id=C_STAT&user_id=U_STAT&trigger_id=t7'
  );
  ASSERT result->>'text' LIKE '%stats%',
    format('Help should mention stats, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 7 - Help text includes stats command';
END;
$$;

ROLLBACK;
