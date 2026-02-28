-- test/test_delete_command.sql
-- Tests for Step 34: /adr delete <id> command
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_delete_command.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: /adr delete on a DRAFT ADR succeeds
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
  adr_exists boolean;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_DEL1', 'C_DEL1', true);

  rec := create_adr('T_DEL1', 'C_DEL1', 'U_DEL1', 'Delete Me ADR', 'ctx');
  ASSERT rec.state = 'DRAFT', 'ADR should start as DRAFT';

  result := execute_slash_delete('T_DEL1', 'U_DEL1', rec.id);
  result_text := result::text;

  ASSERT result_text LIKE '%deleted%' OR result_text LIKE '%Deleted%',
    format('Should confirm deletion, got: %s', result_text);

  -- ADR should be gone
  SELECT EXISTS(SELECT 1 FROM adrs WHERE id = rec.id) INTO adr_exists;
  ASSERT NOT adr_exists, 'ADR should be deleted from adrs table';

  RAISE NOTICE 'PASS: Test 1 - /adr delete removes DRAFT ADR';
END;
$$;

-- Test 2: /adr delete on an ACCEPTED ADR is rejected
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
  adr_exists boolean;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_DEL2', 'C_DEL2', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_DEL2', 'C_DEL2', 'U_DEL2', 'Accepted ADR', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_DEL2');

  result := execute_slash_delete('T_DEL2', 'U_DEL2', rec.id);
  result_text := result::text;

  ASSERT result_text LIKE '%DRAFT%' OR result_text LIKE '%draft%',
    format('Should mention only DRAFT can be deleted, got: %s', result_text);

  -- ADR should still exist
  SELECT EXISTS(SELECT 1 FROM adrs WHERE id = rec.id) INTO adr_exists;
  ASSERT adr_exists, 'ACCEPTED ADR should NOT be deleted';

  RAISE NOTICE 'PASS: Test 2 - /adr delete rejects non-DRAFT ADR';
END;
$$;

-- Test 3: /adr delete enforces team ownership
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_DEL3', 'C_DEL3', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_DEL3', 'C_DEL3', 'U_DEL3', 'Other Team ADR', 'ctx');

  -- Try to delete from a different team
  result := execute_slash_delete('T_WRONG', 'U_WRONG', rec.id);
  result_text := result::text;

  ASSERT result_text LIKE '%not found%',
    format('Wrong team should get not found, got: %s', result_text);

  RAISE NOTICE 'PASS: Test 3 - /adr delete enforces team ownership';
END;
$$;

-- Test 4: /adr delete with empty ID returns usage hint
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := execute_slash_delete('T_DEL4', 'U_DEL4', '');
  result_text := result::text;
  ASSERT result_text LIKE '%Usage%' OR result_text LIKE '%delete%',
    format('Empty ID should return usage hint, got: %s', result_text);
  RAISE NOTICE 'PASS: Test 4 - /adr delete with empty ID returns usage hint';
END;
$$;

-- Test 5: /adr delete cleans up events and outbox rows
DO $$
DECLARE
  rec adrs;
  result json;
  event_count int;
  outbox_count int;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_DEL5', 'C_DEL5', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_DEL5', 'C_DEL5', 'U_DEL5', 'Cleanup ADR', 'ctx');

  -- Verify events and outbox rows exist
  SELECT count(*) INTO event_count FROM adr_events WHERE adr_id = rec.id;
  ASSERT event_count > 0, 'Should have events before delete';

  result := execute_slash_delete('T_DEL5', 'U_DEL5', rec.id);

  SELECT count(*) INTO event_count FROM adr_events WHERE adr_id = rec.id;
  ASSERT event_count = 0, format('Events should be deleted, got %s', event_count);

  SELECT count(*) INTO outbox_count FROM adr_outbox WHERE adr_id = rec.id;
  ASSERT outbox_count = 0, format('Outbox rows should be deleted, got %s', outbox_count);

  RAISE NOTICE 'PASS: Test 5 - /adr delete cleans up events and outbox rows';
END;
$$;

-- Test 6: Help text includes /adr delete
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := handle_slack_webhook('command=%2Fadr&text=help&team_id=T_DEL6&channel_id=C_DEL6&user_id=U_DEL6');
  result_text := result::text;
  ASSERT result_text LIKE '%delete%',
    format('Help should mention delete, got: %s', left(result_text, 300));
  RAISE NOTICE 'PASS: Test 6 - Help text includes /adr delete';
END;
$$;

ROLLBACK;
