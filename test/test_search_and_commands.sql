-- test/test_search_and_commands.sql
-- Tests for Step 20: /adr search, /adr supersede, /adr reject, Block Kit fields
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_search_and_commands.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Seed test data
INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_SC', 'C_SC', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: /adr search finds ADRs by title fragment
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_SC', 'C_SC', 'U_SC1', 'Use Redis for session caching', 'Need fast session store');

  result := handle_slack_webhook(
    'command=%2Fadr&text=search+Redis&team_id=T_SC&channel_id=C_SC&user_id=U_SC1&trigger_id=trig1'
  );

  ASSERT result->>'text' LIKE '%Redis%',
    format('Search should find Redis ADR, got: %s', left(result->>'text', 200));
  ASSERT result->>'text' LIKE '%' || rec.id || '%',
    format('Search should include ADR ID, got: %s', left(result->>'text', 200));
  RAISE NOTICE 'PASS: Test 1 - /adr search finds ADRs by title fragment';
END;
$$;

-- Test 2: /adr search finds ADRs by context fragment
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_SC', 'C_SC', 'U_SC2', 'Adopt gRPC for microservices', 'Internal service communication needs low latency');

  result := handle_slack_webhook(
    'command=%2Fadr&text=search+latency&team_id=T_SC&channel_id=C_SC&user_id=U_SC2&trigger_id=trig2'
  );

  ASSERT result->>'text' LIKE '%gRPC%',
    format('Search should find gRPC ADR via context, got: %s', left(result->>'text', 200));
  RAISE NOTICE 'PASS: Test 2 - /adr search finds ADRs by context fragment';
END;
$$;

-- Test 3: /adr search with no results
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=search+xyznonexistent99&team_id=T_SC&channel_id=C_SC&user_id=U_SC3&trigger_id=trig3'
  );

  ASSERT result->>'text' LIKE '%No ADRs found%',
    format('Search with no results should say so, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 3 - /adr search with no results shows message';
END;
$$;

-- Test 4: /adr search with empty query shows help
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=search&team_id=T_SC&channel_id=C_SC&user_id=U_SC4&trigger_id=trig4'
  );

  ASSERT result->>'text' LIKE '%Usage%' OR result->>'text' LIKE '%search%',
    format('Empty search should show usage hint, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 4 - /adr search with empty query shows usage';
END;
$$;

-- Test 5: /adr reject <id> transitions ADR to REJECTED
DO $$
DECLARE
  rec adrs;
  result json;
  updated_state adr_state;
BEGIN
  rec := create_adr('T_SC', 'C_SC', 'U_SC5', 'Reject test ADR', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=reject+%s&team_id=T_SC&channel_id=C_SC&user_id=U_SC5&trigger_id=trig5', rec.id)
  );

  SELECT state INTO updated_state FROM adrs WHERE id = rec.id;
  ASSERT updated_state = 'REJECTED',
    format('ADR should be REJECTED, got %s', updated_state);
  ASSERT result::text LIKE '%REJECTED%',
    format('Response should mention REJECTED, got: %s', left(result::text, 200));
  RAISE NOTICE 'PASS: Test 5 - /adr reject transitions ADR to REJECTED';
END;
$$;

-- Test 6: /adr supersede <id> transitions ACCEPTED ADR to SUPERSEDED
DO $$
DECLARE
  rec adrs;
  result json;
  updated_state adr_state;
BEGIN
  rec := create_adr('T_SC', 'C_SC', 'U_SC6', 'Supersede test ADR', 'ctx');
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_SC6');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=supersede+%s&team_id=T_SC&channel_id=C_SC&user_id=U_SC6&trigger_id=trig6', rec.id)
  );

  SELECT state INTO updated_state FROM adrs WHERE id = rec.id;
  ASSERT updated_state = 'SUPERSEDED',
    format('ADR should be SUPERSEDED, got %s', updated_state);
  ASSERT result::text LIKE '%SUPERSEDED%',
    format('Response should mention SUPERSEDED, got: %s', left(result::text, 200));
  RAISE NOTICE 'PASS: Test 6 - /adr supersede transitions ACCEPTED ADR to SUPERSEDED';
END;
$$;

-- Test 7: /adr reject with missing ID shows error
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=reject&team_id=T_SC&channel_id=C_SC&user_id=U_SC7&trigger_id=trig7'
  );

  ASSERT result->>'text' LIKE '%Usage%' OR result->>'text' LIKE '%ID%',
    format('Missing ID should show usage, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 7 - /adr reject with missing ID shows error';
END;
$$;

-- Test 8: /adr supersede with invalid ID shows error
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=supersede+ADR-FAKE-999&team_id=T_SC&channel_id=C_SC&user_id=U_SC8&trigger_id=trig8'
  );

  ASSERT result->>'text' LIKE '%not found%' OR result->>'text' LIKE '%error%' OR result->>'text' LIKE '%Error%',
    format('Invalid ID should show error, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 8 - /adr supersede with invalid ID shows error';
END;
$$;

-- Test 9: Block Kit includes additional fields when populated
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  bk_text text;
BEGIN
  rec := create_adr(
    p_team_id := 'T_SC', p_channel_id := 'C_SC', p_created_by := 'U_SC9',
    p_title := 'Full fields ADR', p_context_text := 'Context here',
    p_decision := 'Decision here', p_alternatives := 'Alt A, Alt B',
    p_consequences := 'Good and bad effects', p_decision_drivers := 'Speed, cost',
    p_reviewers := 'Tech Lead'
  );

  bk := build_adr_block_kit(rec, NULL, NULL);
  bk_text := bk::text;

  ASSERT bk_text LIKE '%Alternatives%',
    format('Block Kit should include Alternatives, got: %s', left(bk_text, 500));
  ASSERT bk_text LIKE '%Consequences%',
    format('Block Kit should include Consequences, got: %s', left(bk_text, 500));
  ASSERT bk_text LIKE '%Decision Drivers%',
    format('Block Kit should include Decision Drivers, got: %s', left(bk_text, 500));
  ASSERT bk_text LIKE '%Reviewers%',
    format('Block Kit should include Reviewers, got: %s', left(bk_text, 500));
  RAISE NOTICE 'PASS: Test 9 - Block Kit includes additional fields when populated';
END;
$$;

-- Test 10: Block Kit omits empty additional fields
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  bk_text text;
BEGIN
  rec := create_adr('T_SC', 'C_SC', 'U_SC10', 'Minimal ADR', 'Just context');

  bk := build_adr_block_kit(rec, NULL, NULL);
  bk_text := bk::text;

  ASSERT bk_text NOT LIKE '%Alternatives%',
    'Block Kit should omit empty Alternatives';
  ASSERT bk_text NOT LIKE '%Consequences%',
    'Block Kit should omit empty Consequences';
  RAISE NOTICE 'PASS: Test 10 - Block Kit omits empty additional fields';
END;
$$;

-- Test 11: Help text includes new commands
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_SC&channel_id=C_SC&user_id=U_SC11&trigger_id=trig11'
  );

  ASSERT result->>'text' LIKE '%search%',
    format('Help should mention search, got: %s', result->>'text');
  ASSERT result->>'text' LIKE '%reject%',
    format('Help should mention reject, got: %s', result->>'text');
  ASSERT result->>'text' LIKE '%supersede%',
    format('Help should mention supersede, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 11 - Help text includes new commands';
END;
$$;

ROLLBACK;
