-- test/test_input_validation.sql
-- Tests for Step 36: Input validation, unknown commands, error paths
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_input_validation.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: Modal rejects title longer than 200 characters
DO $$
DECLARE
  result json;
  result_text text;
  long_title text;
  payload text;
BEGIN
  long_title := repeat('A', 250);
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_IV1', 'C_IV1', true)
  ON CONFLICT DO NOTHING;

  payload := format('{"type":"view_submission","user":{"id":"U_IV1"},"view":{"private_metadata":"C_IV1||","state":{"values":{"title_block":{"title_input":{"value":"%s"}},"context_block":{"context_input":{"value":"ctx"}},"decision_block":{"decision_input":{"value":null}},"alternatives_block":{"alternatives_input":{"value":null}},"consequences_block":{"consequences_input":{"value":null}},"open_questions_block":{"open_questions_input":{"value":null}},"decision_drivers_block":{"decision_drivers_input":{"value":null}},"implementation_plan_block":{"implementation_plan_input":{"value":null}},"reviewers_block":{"reviewers_input":{"value":null}}}}}}', long_title);

  result := handle_slack_modal_submission(payload);
  result_text := result::text;

  ASSERT result_text LIKE '%response_action%' AND result_text LIKE '%errors%',
    format('Should return validation error for long title, got: %s', left(result_text, 200));
  ASSERT result_text LIKE '%title_block%',
    format('Should flag title_block, got: %s', left(result_text, 200));
  RAISE NOTICE 'PASS: Test 1 - Modal rejects title longer than 200 chars';
END;
$$;

-- Test 2: Modal rejects individual fields longer than 3000 characters
DO $$
DECLARE
  result json;
  result_text text;
  long_context text;
  payload text;
BEGIN
  long_context := repeat('B', 3500);
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_IV2', 'C_IV2', true)
  ON CONFLICT DO NOTHING;

  payload := format('{"type":"view_submission","user":{"id":"U_IV2"},"view":{"private_metadata":"C_IV2||","state":{"values":{"title_block":{"title_input":{"value":"Valid Title"}},"context_block":{"context_input":{"value":"%s"}},"decision_block":{"decision_input":{"value":null}},"alternatives_block":{"alternatives_input":{"value":null}},"consequences_block":{"consequences_input":{"value":null}},"open_questions_block":{"open_questions_input":{"value":null}},"decision_drivers_block":{"decision_drivers_input":{"value":null}},"implementation_plan_block":{"implementation_plan_input":{"value":null}},"reviewers_block":{"reviewers_input":{"value":null}}}}}}', long_context);

  result := handle_slack_modal_submission(payload);
  result_text := result::text;

  ASSERT result_text LIKE '%response_action%' AND result_text LIKE '%errors%',
    format('Should return validation error for long context, got: %s', left(result_text, 200));
  ASSERT result_text LIKE '%context_block%',
    format('Should flag context_block, got: %s', left(result_text, 200));
  RAISE NOTICE 'PASS: Test 2 - Modal rejects fields longer than 3000 chars';
END;
$$;

-- Test 3: Unknown subcommand shows "did you mean" hint
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := handle_slack_webhook('command=%2Fadr&text=serach+foo&team_id=T_IV3&channel_id=C_IV3&user_id=U_IV3');
  result_text := result::text;
  ASSERT result_text LIKE '%search%',
    format('Should suggest "search" for "serach", got: %s', left(result_text, 300));
  RAISE NOTICE 'PASS: Test 3 - Unknown subcommand suggests similar command';
END;
$$;

-- Test 4: Unknown subcommand still shows help
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := handle_slack_webhook('command=%2Fadr&text=xyzzy&team_id=T_IV4&channel_id=C_IV4&user_id=U_IV4');
  result_text := result::text;
  ASSERT result_text LIKE '%ADR Bot Commands%',
    format('Completely unknown command should show help, got: %s', left(result_text, 300));
  RAISE NOTICE 'PASS: Test 4 - Completely unknown subcommand shows help text';
END;
$$;

-- Test 5: Invalid state transition returns friendly error (REJECTED → ACCEPTED)
DO $$
DECLARE
  rec adrs;
  result json;
  result_text text;
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_IV5', 'C_IV5', true)
  ON CONFLICT DO NOTHING;

  rec := create_adr('T_IV5', 'C_IV5', 'U_IV5', 'Rejected ADR', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_IV5');

  -- Try to accept a rejected ADR via slash command
  result := handle_slack_webhook(format('command=%%2Fadr&text=accept+%s&team_id=T_IV5&channel_id=C_IV5&user_id=U_IV5', rec.id));
  result_text := result::text;
  ASSERT result_text LIKE '%Error%' OR result_text LIKE '%cannot%' OR result_text LIKE '%Invalid%',
    format('Should show error for invalid transition, got: %s', left(result_text, 300));
  RAISE NOTICE 'PASS: Test 5 - Invalid state transition returns friendly error';
END;
$$;

-- Test 6: /adr view with NULL target shows friendly error
DO $$
DECLARE
  result json;
  result_text text;
BEGIN
  result := handle_slack_webhook('command=%2Fadr&text=view&team_id=T_IV6&channel_id=C_IV6&user_id=U_IV6');
  result_text := result::text;
  ASSERT result_text LIKE '%not found%' OR result_text LIKE '%Usage%',
    format('View with no ID should return friendly error, got: %s', left(result_text, 200));
  RAISE NOTICE 'PASS: Test 6 - /adr view with no ID returns friendly error';
END;
$$;

-- Test 7: Modal submission with valid-length fields succeeds
DO $$
DECLARE
  result json;
  result_text text;
  title text;
  payload text;
BEGIN
  title := repeat('C', 200); -- exactly at limit
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_IV7', 'C_IV7', true)
  ON CONFLICT DO NOTHING;

  payload := format('{"type":"view_submission","user":{"id":"U_IV7"},"view":{"private_metadata":"C_IV7||","state":{"values":{"title_block":{"title_input":{"value":"%s"}},"context_block":{"context_input":{"value":"ctx"}},"decision_block":{"decision_input":{"value":null}},"alternatives_block":{"alternatives_input":{"value":null}},"consequences_block":{"consequences_input":{"value":null}},"open_questions_block":{"open_questions_input":{"value":null}},"decision_drivers_block":{"decision_drivers_input":{"value":null}},"implementation_plan_block":{"implementation_plan_input":{"value":null}},"reviewers_block":{"reviewers_input":{"value":null}}}}}}', title);

  result := handle_slack_modal_submission(payload);
  -- NULL means success (modal closed)
  ASSERT result IS NULL, format('200-char title should succeed, got: %s', result::text);
  RAISE NOTICE 'PASS: Test 7 - Modal submission with max-length title succeeds';
END;
$$;

ROLLBACK;
