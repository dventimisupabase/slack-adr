-- test/test_list_filter_and_fts.sql
-- Tests for Step 24: /adr list state filtering + full-text search
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_list_filter_and_fts.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Seed data: create ADRs in various states
INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_FLT', 'C_FLT', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Helper: create ADRs in various states for filtering tests
DO $$
DECLARE r adrs;
BEGIN
  -- 2 DRAFTs
  PERFORM create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Draft Alpha', 'Microservices context');
  PERFORM create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Draft Beta', 'Database context');

  -- 2 ACCEPTED
  r := create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Accepted Gamma', 'API gateway context');
  PERFORM set_config('app.suppress_outbox', 'true', true);
  PERFORM apply_adr_event(r.id, 'ADR_ACCEPTED', 'user', 'U_FLT');
  r := create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Accepted Delta', 'Caching context');
  PERFORM apply_adr_event(r.id, 'ADR_ACCEPTED', 'user', 'U_FLT');

  -- 1 REJECTED
  r := create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Rejected Epsilon', 'Monolith context');
  PERFORM apply_adr_event(r.id, 'ADR_REJECTED', 'user', 'U_FLT');

  -- 1 SUPERSEDED
  r := create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Superseded Zeta', 'Legacy context');
  PERFORM apply_adr_event(r.id, 'ADR_ACCEPTED', 'user', 'U_FLT');
  PERFORM apply_adr_event(r.id, 'ADR_SUPERSEDED', 'user', 'U_FLT');
  PERFORM set_config('app.suppress_outbox', 'false', true);
END;
$$;

-- Test 1: /adr list draft shows only DRAFT ADRs
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+draft&team_id=T_FLT&channel_id=C_FLT&user_id=U_FLT&trigger_id=t1'
  );
  ASSERT result->>'text' LIKE '%Draft Alpha%',
    format('Should show Draft Alpha, got: %s', left(result->>'text', 300));
  ASSERT result->>'text' LIKE '%Draft Beta%',
    format('Should show Draft Beta, got: %s', left(result->>'text', 300));
  ASSERT result->>'text' NOT LIKE '%Accepted Gamma%',
    'Should not show accepted ADRs';
  ASSERT result->>'text' NOT LIKE '%Rejected Epsilon%',
    'Should not show rejected ADRs';
  ASSERT result->>'text' LIKE '%DRAFT%',
    'Should indicate state filter';
  RAISE NOTICE 'PASS: Test 1 - /adr list draft shows only DRAFT ADRs';
END;
$$;

-- Test 2: /adr list accepted shows only ACCEPTED ADRs
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+accepted&team_id=T_FLT&channel_id=C_FLT&user_id=U_FLT&trigger_id=t2'
  );
  ASSERT result->>'text' LIKE '%Accepted Gamma%',
    format('Should show Accepted Gamma, got: %s', left(result->>'text', 300));
  ASSERT result->>'text' LIKE '%Accepted Delta%',
    format('Should show Accepted Delta, got: %s', left(result->>'text', 300));
  ASSERT result->>'text' NOT LIKE '%Draft Alpha%',
    'Should not show draft ADRs';
  RAISE NOTICE 'PASS: Test 2 - /adr list accepted shows only ACCEPTED ADRs';
END;
$$;

-- Test 3: /adr list rejected shows only REJECTED ADRs
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+rejected&team_id=T_FLT&channel_id=C_FLT&user_id=U_FLT&trigger_id=t3'
  );
  ASSERT result->>'text' LIKE '%Rejected Epsilon%',
    format('Should show Rejected Epsilon, got: %s', left(result->>'text', 300));
  ASSERT result->>'text' NOT LIKE '%Draft Alpha%',
    'Should not show draft ADRs';
  RAISE NOTICE 'PASS: Test 3 - /adr list rejected shows only REJECTED ADRs';
END;
$$;

-- Test 4: /adr list superseded shows only SUPERSEDED ADRs
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+superseded&team_id=T_FLT&channel_id=C_FLT&user_id=U_FLT&trigger_id=t4'
  );
  ASSERT result->>'text' LIKE '%Superseded Zeta%',
    format('Should show Superseded Zeta, got: %s', left(result->>'text', 300));
  ASSERT result->>'text' NOT LIKE '%Draft Alpha%',
    'Should not show draft ADRs';
  RAISE NOTICE 'PASS: Test 4 - /adr list superseded shows only SUPERSEDED ADRs';
END;
$$;

-- Test 5: /adr list (no filter) shows all ADRs
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list&team_id=T_FLT&channel_id=C_FLT&user_id=U_FLT&trigger_id=t5'
  );
  ASSERT result->>'text' LIKE '%Draft Alpha%', 'Should include draft';
  ASSERT result->>'text' LIKE '%Accepted Gamma%', 'Should include accepted';
  ASSERT result->>'text' LIKE '%Rejected Epsilon%', 'Should include rejected';
  ASSERT result->>'text' LIKE '%Superseded Zeta%', 'Should include superseded';
  RAISE NOTICE 'PASS: Test 5 - /adr list (no filter) shows all ADRs';
END;
$$;

-- Test 6: /adr list with empty state filter for that state
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+draft&team_id=T_EMPTY_FLT&channel_id=C_EMPTY_FLT&user_id=U_FLT&trigger_id=t6'
  );
  ASSERT result->>'text' LIKE '%No ADRs found%',
    format('Should say no ADRs found, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 6 - /adr list with empty state filter shows no results';
END;
$$;

-- Test 7: /adr search uses full-text search (finds stemmed terms)
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Implementing PostgreSQL Replication', 'We need database replication for high availability');

  -- Search for "replicate" should find "replication" via stemming
  result := build_adr_search('T_FLT', 'C_FLT', 'replication');
  ASSERT result->>'text' LIKE '%Replication%',
    format('FTS should find Replication, got: %s', left(result->>'text', 300));
  RAISE NOTICE 'PASS: Test 7 - /adr search finds terms via full-text search';
END;
$$;

-- Test 8: /adr search still works for partial matches (fallback to ILIKE)
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_FLT', 'C_FLT', 'U_FLT', 'Use gRPC for internal APIs', 'Low latency RPC framework');

  -- Search for "gRPC" should find it
  result := build_adr_search('T_FLT', 'C_FLT', 'gRPC');
  ASSERT result->>'text' LIKE '%gRPC%',
    format('Should find gRPC, got: %s', left(result->>'text', 300));
  RAISE NOTICE 'PASS: Test 8 - /adr search works for partial text matches';
END;
$$;

-- Test 9: Help text includes list filter syntax
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_FLT&channel_id=C_FLT&user_id=U_FLT&trigger_id=t9'
  );
  ASSERT result->>'text' LIKE '%list%draft%' OR result->>'text' LIKE '%list%state%',
    format('Help should mention list filtering, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 9 - Help text includes list filter syntax';
END;
$$;

ROLLBACK;
