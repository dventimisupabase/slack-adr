-- test/test_team_scoping.sql
-- Tests for Step 22: Team ownership verification and /adr accept command
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_team_scoping.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Seed test data
INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_OWN', 'C_OWN', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: /adr view rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OTHER_TEAM', 'C_OTHER', 'U_OTHER', 'Other Team ADR', 'ctx');

  result := build_adr_view('T_OWN', rec.id);
  ASSERT result->>'text' LIKE '%not found%',
    format('Should not show ADR from other team, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 1 - /adr view rejects ADR from different team';
END;
$$;

-- Test 2: /adr view shows ADR from same team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OWN', 'C_OWN', 'U_OWN', 'Own Team ADR', 'ctx');

  result := build_adr_view('T_OWN', rec.id);
  ASSERT result::text LIKE '%Own Team ADR%',
    format('Should show ADR from same team, got: %s', left(result::text, 200));
  RAISE NOTICE 'PASS: Test 2 - /adr view shows ADR from same team';
END;
$$;

-- Test 3: /adr reject rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OTHER_TEAM', 'C_OTHER', 'U_OTHER', 'Cross-team reject target', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=reject+%s&team_id=T_OWN&channel_id=C_OWN&user_id=U_OWN&trigger_id=trig1', rec.id)
  );

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team operation, got: %s', result->>'text');

  -- ADR should still be DRAFT
  SELECT * INTO rec FROM adrs WHERE id = rec.id;
  ASSERT rec.state = 'DRAFT',
    format('ADR should still be DRAFT, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 3 - /adr reject rejects ADR from different team';
END;
$$;

-- Test 4: /adr supersede rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OTHER_TEAM', 'C_OTHER', 'U_OTHER', 'Cross-team supersede target', 'ctx');
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_OTHER');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=supersede+%s&team_id=T_OWN&channel_id=C_OWN&user_id=U_OWN&trigger_id=trig2', rec.id)
  );

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team operation, got: %s', result->>'text');

  SELECT * INTO rec FROM adrs WHERE id = rec.id;
  ASSERT rec.state = 'ACCEPTED',
    format('ADR should still be ACCEPTED, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 4 - /adr supersede rejects ADR from different team';
END;
$$;

-- Test 5: /adr accept <id> transitions DRAFT to ACCEPTED
DO $$
DECLARE
  rec adrs;
  result json;
  updated_state adr_state;
BEGIN
  rec := create_adr('T_OWN', 'C_OWN', 'U_OWN', 'Accept command test', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=accept+%s&team_id=T_OWN&channel_id=C_OWN&user_id=U_OWN&trigger_id=trig3', rec.id)
  );

  SELECT state INTO updated_state FROM adrs WHERE id = rec.id;
  ASSERT updated_state = 'ACCEPTED',
    format('ADR should be ACCEPTED, got %s', updated_state);
  ASSERT result::text LIKE '%ACCEPTED%',
    format('Response should mention ACCEPTED, got: %s', left(result::text, 200));
  RAISE NOTICE 'PASS: Test 5 - /adr accept transitions DRAFT to ACCEPTED';
END;
$$;

-- Test 6: /adr accept with missing ID shows usage
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=accept&team_id=T_OWN&channel_id=C_OWN&user_id=U_OWN&trigger_id=trig4'
  );

  ASSERT result->>'text' LIKE '%Usage%',
    format('Missing ID should show usage, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 6 - /adr accept with missing ID shows usage';
END;
$$;

-- Test 7: /adr accept rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OTHER_TEAM', 'C_OTHER', 'U_OTHER', 'Cross-team accept target', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=accept+%s&team_id=T_OWN&channel_id=C_OWN&user_id=U_OWN&trigger_id=trig5', rec.id)
  );

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team accept, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 7 - /adr accept rejects ADR from different team';
END;
$$;

-- Test 8: /adr list shows origin channel
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OWN', 'C_ORIGIN', 'U_OWN', 'Channel Origin Test', 'ctx');

  result := handle_slack_webhook(
    'command=%2Fadr&text=list&team_id=T_OWN&channel_id=C_OWN&user_id=U_OWN&trigger_id=trig6'
  );

  ASSERT result->>'text' LIKE '%#C_ORIGIN%' OR result->>'text' LIKE '%C_ORIGIN%',
    format('List should show origin channel, got: %s', left(result->>'text', 300));
  RAISE NOTICE 'PASS: Test 8 - /adr list shows origin channel';
END;
$$;

-- Test 9: Help text includes accept command
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_OWN&channel_id=C_OWN&user_id=U_OWN&trigger_id=trig7'
  );

  ASSERT result->>'text' LIKE '%/adr accept%',
    format('Help should mention accept, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 9 - Help text includes accept command';
END;
$$;

ROLLBACK;
