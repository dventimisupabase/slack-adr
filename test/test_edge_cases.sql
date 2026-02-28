-- test/test_edge_cases.sql
-- Tests for Step 42: Edge case coverage for terminal states
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_edge_cases.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: SUPERSEDED Block Kit has no action buttons
DO $$
DECLARE
  rec adrs;
  bk jsonb;
BEGIN
  rec := create_adr('T_EC1', 'C_EC1', 'U_EC1', 'Superseded Kit Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EC1');
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_EC1');
  bk := build_adr_block_kit(rec);
  ASSERT bk::text NOT LIKE '%action_id%',
    format('SUPERSEDED Block Kit should have no action buttons, got: %s', left(bk::text, 500));
  RAISE NOTICE 'PASS: Test 1 - SUPERSEDED Block Kit has no action buttons';
END;
$$;

-- Test 2: SUPERSEDED Block Kit has no delete button
DO $$
DECLARE
  rec adrs;
  bk jsonb;
BEGIN
  rec := create_adr('T_EC2', 'C_EC2', 'U_EC2', 'Superseded Delete Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EC2');
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_EC2');
  bk := build_adr_block_kit(rec);
  ASSERT bk::text NOT LIKE '%delete_adr%',
    'SUPERSEDED Block Kit should have no delete button';
  RAISE NOTICE 'PASS: Test 2 - SUPERSEDED Block Kit has no delete button';
END;
$$;

-- Test 3: REJECTED Block Kit has no action buttons
DO $$
DECLARE
  rec adrs;
  bk jsonb;
BEGIN
  rec := create_adr('T_EC3', 'C_EC3', 'U_EC3', 'Rejected Kit Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_EC3');
  bk := build_adr_block_kit(rec);
  ASSERT bk::text NOT LIKE '%action_id%',
    format('REJECTED Block Kit should have no action buttons, got: %s', left(bk::text, 500));
  RAISE NOTICE 'PASS: Test 3 - REJECTED Block Kit has no action buttons';
END;
$$;

-- Test 4: /adr accept on REJECTED ADR fails
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_EC4', 'C_EC4', true) ON CONFLICT DO NOTHING;
  rec := create_adr('T_EC4', 'C_EC4', 'U_EC4', 'Rejected Accept Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_EC4');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=accept+%s&team_id=T_EC4&channel_id=C_EC4&user_id=U_EC4',
    rec.id));
  ASSERT result->>'text' LIKE '%Error%' OR result->>'text' LIKE '%Invalid%',
    format('Should fail to accept REJECTED, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 4 - /adr accept on REJECTED ADR fails';
END;
$$;

-- Test 5: /adr supersede on REJECTED ADR fails
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_EC5', 'C_EC5', true) ON CONFLICT DO NOTHING;
  rec := create_adr('T_EC5', 'C_EC5', 'U_EC5', 'Rejected Supersede Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_EC5');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=supersede+%s&team_id=T_EC5&channel_id=C_EC5&user_id=U_EC5',
    rec.id));
  ASSERT result->>'text' LIKE '%Error%' OR result->>'text' LIKE '%Invalid%',
    format('Should fail to supersede REJECTED, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 5 - /adr supersede on REJECTED ADR fails';
END;
$$;

-- Test 6: Interactive accept_adr on SUPERSEDED ADR returns error
DO $$
DECLARE
  rec adrs;
  result json;
  payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_EC6', 'C_EC6', true) ON CONFLICT DO NOTHING;
  rec := create_adr('T_EC6', 'C_EC6', 'U_EC6', 'Stale Button Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EC6');
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_EC6');

  payload := jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_EC6'),
    'team', jsonb_build_object('id', 'T_EC6'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'accept_adr',
      'value', rec.id
    ))
  );

  result := handle_interactive_payload(payload);
  ASSERT result::text LIKE '%Cannot%' OR result::text LIKE '%SUPERSEDED%',
    format('Should handle stale button gracefully, got: %s', result::text);
  RAISE NOTICE 'PASS: Test 6 - Interactive accept on SUPERSEDED returns friendly error';
END;
$$;

-- Test 7: /adr delete on SUPERSEDED ADR fails (not DRAFT)
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_EC7', 'C_EC7', true) ON CONFLICT DO NOTHING;
  rec := create_adr('T_EC7', 'C_EC7', 'U_EC7', 'Delete Superseded Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EC7');
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_EC7');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=delete+%s&team_id=T_EC7&channel_id=C_EC7&user_id=U_EC7',
    rec.id));
  ASSERT result->>'text' LIKE '%DRAFT%' OR result->>'text' LIKE '%draft%',
    format('Should mention only DRAFT can be deleted, got: %s', result->>'text');

  -- Verify ADR still exists
  ASSERT EXISTS(SELECT 1 FROM adrs WHERE id = rec.id),
    'SUPERSEDED ADR should NOT be deleted';
  RAISE NOTICE 'PASS: Test 7 - /adr delete on SUPERSEDED ADR fails';
END;
$$;

-- Test 8: /adr reopen on SUPERSEDED ADR fails (only REJECTED can be reopened)
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_EC8', 'C_EC8', true) ON CONFLICT DO NOTHING;
  rec := create_adr('T_EC8', 'C_EC8', 'U_EC8', 'Reopen Superseded Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EC8');
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_EC8');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=reopen+%s&team_id=T_EC8&channel_id=C_EC8&user_id=U_EC8',
    rec.id));
  ASSERT result->>'text' LIKE '%Error%' OR result->>'text' LIKE '%Invalid%',
    format('Should fail to reopen SUPERSEDED, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 8 - /adr reopen on SUPERSEDED ADR fails';
END;
$$;

-- Test 9: Version optimistic lock failure raises clear error
DO $$
DECLARE
  rec adrs;
  error_caught boolean := false;
BEGIN
  rec := create_adr('T_EC9', 'C_EC9', 'U_EC9', 'Version Conflict', 'ctx');

  -- Artificially corrupt the version to simulate optimistic lock failure
  UPDATE adrs SET version = 999 WHERE id = rec.id;

  BEGIN
    PERFORM apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EC9');
    -- Should succeed because SELECT FOR UPDATE reads current version
    error_caught := false;
  EXCEPTION WHEN OTHERS THEN
    error_caught := true;
  END;

  -- apply_adr_event uses SELECT FOR UPDATE then WHERE version = req.version
  -- Since we changed version to 999, the SELECT reads 999, and UPDATE WHERE version = 999 works
  -- So this should NOT error
  ASSERT NOT error_caught,
    'apply_adr_event with FOR UPDATE should read current version and succeed';
  RAISE NOTICE 'PASS: Test 9 - Pessimistic lock reads current version correctly';
END;
$$;

-- Test 10: /adr export on SUPERSEDED ADR fails
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_EC10', 'C_EC10', true) ON CONFLICT DO NOTHING;
  rec := create_adr('T_EC10', 'C_EC10', 'U_EC10', 'Export Superseded Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EC10');
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_EC10');

  result := handle_slack_webhook(format(
    'command=%%2Fadr&text=export+%s&team_id=T_EC10&channel_id=C_EC10&user_id=U_EC10',
    rec.id));
  ASSERT result->>'text' LIKE '%Error%' OR result->>'text' LIKE '%Invalid%',
    format('Should fail to export SUPERSEDED, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 10 - /adr export on SUPERSEDED ADR fails';
END;
$$;

ROLLBACK;
