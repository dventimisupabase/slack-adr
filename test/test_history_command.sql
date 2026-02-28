-- test/test_history_command.sql
-- Tests for Step 33: /adr history <id> command
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_history_command.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: /adr history shows event timeline for an ADR
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_HI1', 'C_HI1', true);

  rec := create_adr('T_HI1', 'C_HI1', 'U_HI1', 'History Test ADR', 'Some context');
  rec := apply_adr_event(rec.id, 'ADR_UPDATED', 'user', 'U_HI2', '{"title":"Updated Title"}'::jsonb);
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_HI3');

  result := build_adr_history('T_HI1', rec.id);
  result_text := result::text;

  ASSERT result_text LIKE '%History Test ADR%' OR result_text LIKE '%Updated Title%',
    format('Should contain ADR title, got: %s', left(result_text, 200));
  ASSERT result_text LIKE '%ADR_CREATED%',
    format('Should show ADR_CREATED event, got: %s', left(result_text, 200));
  ASSERT result_text LIKE '%ADR_UPDATED%',
    format('Should show ADR_UPDATED event, got: %s', left(result_text, 200));
  ASSERT result_text LIKE '%ADR_ACCEPTED%',
    format('Should show ADR_ACCEPTED event, got: %s', left(result_text, 200));
  RAISE NOTICE 'PASS: Test 1 - /adr history shows event timeline';
END;
$$;

-- Test 2: /adr history shows actor IDs
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_HI2', 'C_HI2', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_HI2', 'C_HI2', 'U_CREATOR', 'Actor Test ADR', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_ACCEPTER');

  result := build_adr_history('T_HI2', rec.id);
  result_text := result::text;

  ASSERT result_text LIKE '%U_CREATOR%',
    format('Should show creator actor, got: %s', left(result_text, 200));
  ASSERT result_text LIKE '%U_ACCEPTER%',
    format('Should show accepter actor, got: %s', left(result_text, 200));
  RAISE NOTICE 'PASS: Test 2 - /adr history shows actor IDs';
END;
$$;

-- Test 3: /adr history for nonexistent ADR returns friendly error
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := build_adr_history('T_HI3', 'ADR-0000-000000');
  result_text := result::text;
  ASSERT result_text LIKE '%not found%',
    format('Should return not found, got: %s', result_text);
  RAISE NOTICE 'PASS: Test 3 - /adr history returns friendly error for nonexistent ADR';
END;
$$;

-- Test 4: /adr history enforces team ownership
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_HI4', 'C_HI4', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_HI4', 'C_HI4', 'U_HI4', 'Other Team ADR', 'ctx');

  -- Try to view from a different team
  result := build_adr_history('T_OTHER', rec.id);
  result_text := result::text;
  ASSERT result_text LIKE '%not found%',
    format('Wrong team should get not found, got: %s', result_text);
  RAISE NOTICE 'PASS: Test 4 - /adr history enforces team ownership';
END;
$$;

-- Test 5: /adr history with empty ID returns usage hint
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := build_adr_history('T_HI5', '');
  result_text := result::text;
  ASSERT result_text LIKE '%Usage%' OR result_text LIKE '%history%',
    format('Empty ID should return usage hint, got: %s', result_text);
  RAISE NOTICE 'PASS: Test 5 - /adr history with empty ID returns usage hint';
END;
$$;

-- Test 6: Help text includes /adr history
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := handle_slack_webhook('command=%2Fadr&text=help&team_id=T_HI6&channel_id=C_HI6&user_id=U_HI6');
  result_text := result::text;
  ASSERT result_text LIKE '%history%',
    format('Help should mention history, got: %s', left(result_text, 300));
  RAISE NOTICE 'PASS: Test 6 - Help text includes /adr history';
END;
$$;

ROLLBACK;
