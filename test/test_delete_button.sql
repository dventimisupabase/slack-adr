-- test/test_delete_button.sql
-- Tests for Step 35: Interactive delete button
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_delete_button.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: DRAFT Block Kit includes delete button
DO $$
DECLARE
  rec adrs;
  bk jsonb;
BEGIN
  rec := create_adr('T_DB1', 'C_DB1', 'U_DB1', 'Delete Button Test', 'ctx');
  bk := build_adr_block_kit(rec);
  ASSERT bk::text LIKE '%delete_adr%',
    format('DRAFT Block Kit should have delete_adr button, got: %s', left(bk::text, 500));
  RAISE NOTICE 'PASS: Test 1 - DRAFT Block Kit includes delete button';
END;
$$;

-- Test 2: ACCEPTED Block Kit does NOT include delete button
DO $$
DECLARE
  rec adrs;
  bk jsonb;
BEGIN
  rec := create_adr('T_DB2', 'C_DB2', 'U_DB2', 'No Delete Button Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_DB2');
  bk := build_adr_block_kit(rec);
  ASSERT bk::text NOT LIKE '%delete_adr%',
    'ACCEPTED Block Kit should NOT have delete_adr button';
  RAISE NOTICE 'PASS: Test 2 - ACCEPTED Block Kit excludes delete button';
END;
$$;

-- Test 3: Interactive delete_adr action deletes DRAFT ADR
DO $$
DECLARE
  rec adrs;
  result json;
  adr_exists boolean;
  payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_DB3', 'C_DB3', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_DB3', 'C_DB3', 'U_DB3', 'Interactive Delete Test', 'ctx');

  payload := jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_DB3'),
    'team', jsonb_build_object('id', 'T_DB3'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'delete_adr',
      'value', rec.id
    ))
  );

  result := handle_interactive_payload(payload);

  SELECT EXISTS(SELECT 1 FROM adrs WHERE id = rec.id) INTO adr_exists;
  ASSERT NOT adr_exists, 'ADR should be deleted by interactive action';
  ASSERT result::text LIKE '%Deleted%' OR result::text LIKE '%deleted%',
    format('Should confirm deletion, got: %s', result::text);
  RAISE NOTICE 'PASS: Test 3 - Interactive delete_adr action deletes DRAFT ADR';
END;
$$;

-- Test 4: Interactive delete_adr action rejects non-DRAFT ADR
DO $$
DECLARE
  rec adrs;
  result json;
  adr_exists boolean;
  payload jsonb;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_DB4', 'C_DB4', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_DB4', 'C_DB4', 'U_DB4', 'Accepted Delete Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_DB4');

  payload := jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_DB4'),
    'team', jsonb_build_object('id', 'T_DB4'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'delete_adr',
      'value', rec.id
    ))
  );

  result := handle_interactive_payload(payload);

  SELECT EXISTS(SELECT 1 FROM adrs WHERE id = rec.id) INTO adr_exists;
  ASSERT adr_exists, 'ACCEPTED ADR should NOT be deleted';
  ASSERT result::text LIKE '%DRAFT%' OR result::text LIKE '%draft%',
    format('Should mention only DRAFT, got: %s', result::text);
  RAISE NOTICE 'PASS: Test 4 - Interactive delete_adr rejects non-DRAFT ADR';
END;
$$;

ROLLBACK;
