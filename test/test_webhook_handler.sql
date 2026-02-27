-- test/test_webhook_handler.sql
-- Tests for Step 4: url_decode, verify_slack_signature, parse_form_body, build_adr_list, build_adr_view
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_webhook_handler.sql
--
-- Note: handle_slack_webhook reads PostgREST GUC headers (request.header.x-slack-signature)
-- which can't be simulated in plain psql. Full webhook routing is tested via curl integration tests.
-- Here we test the pure building blocks.

BEGIN;

-- Set test secrets
SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = '8f742231b10e8888abcd99yyyzzz85a5';

-- ============================================================
-- url_decode tests
-- ============================================================

-- Test 1: url_decode handles + as space
DO $$
BEGIN
  ASSERT url_decode('hello+world') = 'hello world',
    format('Expected "hello world", got "%s"', url_decode('hello+world'));
  RAISE NOTICE 'PASS: Test 1 - url_decode handles + as space';
END;
$$;

-- Test 2: url_decode handles %XX hex sequences
DO $$
BEGIN
  ASSERT url_decode('hello%20world') = 'hello world',
    format('Expected "hello world", got "%s"', url_decode('hello%20world'));
  RAISE NOTICE 'PASS: Test 2 - url_decode handles %%XX hex sequences';
END;
$$;

-- Test 3: url_decode handles mixed encoding
DO $$
DECLARE
  result text;
BEGIN
  result := url_decode('key%3Dvalue%26foo%3Dbar+baz');
  ASSERT result = 'key=value&foo=bar baz',
    format('Expected "key=value&foo=bar baz", got "%s"', result);
  RAISE NOTICE 'PASS: Test 3 - url_decode handles mixed encoding';
END;
$$;

-- Test 4: url_decode handles empty string
DO $$
BEGIN
  ASSERT url_decode('') = '', 'Empty string should return empty';
  RAISE NOTICE 'PASS: Test 4 - url_decode handles empty string';
END;
$$;

-- ============================================================
-- parse_form_body tests
-- ============================================================

-- Test 5: parse_form_body parses typical Slack slash command body
DO $$
DECLARE
  result jsonb;
BEGIN
  result := parse_form_body('command=%2Fadr&text=start&team_id=T123&channel_id=C456&user_id=U789');
  ASSERT result->>'command' = '/adr', format('command: %s', result->>'command');
  ASSERT result->>'text' = 'start', format('text: %s', result->>'text');
  ASSERT result->>'team_id' = 'T123', format('team_id: %s', result->>'team_id');
  ASSERT result->>'channel_id' = 'C456', format('channel_id: %s', result->>'channel_id');
  ASSERT result->>'user_id' = 'U789', format('user_id: %s', result->>'user_id');
  RAISE NOTICE 'PASS: Test 5 - parse_form_body parses Slack slash command body';
END;
$$;

-- Test 6: parse_form_body handles empty body
DO $$
BEGIN
  ASSERT parse_form_body('') = '{}'::jsonb, 'Empty body should return empty object';
  ASSERT parse_form_body(NULL) = '{}'::jsonb, 'NULL body should return empty object';
  RAISE NOTICE 'PASS: Test 6 - parse_form_body handles empty/NULL body';
END;
$$;

-- ============================================================
-- verify_slack_signature tests
-- ============================================================

-- Test 7: verify_slack_signature returns true for valid signature
DO $$
DECLARE
  raw_body text := 'token=xyzz0WbapA4vBCDEFasx0q6G&team_id=T1DC2JH3J&command=%2Fadr&text=start';
  ts text := '1531420618';
  base_string text;
  expected_sig text;
  result boolean;
BEGIN
  base_string := 'v0:' || ts || ':' || raw_body;
  expected_sig := 'v0=' || encode(
    hmac(base_string, '8f742231b10e8888abcd99yyyzzz85a5', 'sha256'),
    'hex'
  );
  result := verify_slack_signature(raw_body, ts, expected_sig);
  ASSERT result = true, 'Valid signature should verify';
  RAISE NOTICE 'PASS: Test 7 - verify_slack_signature returns true for valid signature';
END;
$$;

-- Test 8: verify_slack_signature returns false for invalid signature
DO $$
DECLARE
  result boolean;
BEGIN
  result := verify_slack_signature('some body', '1531420618', 'v0=invalid_signature');
  ASSERT result = false, 'Invalid signature should not verify';
  RAISE NOTICE 'PASS: Test 8 - verify_slack_signature returns false for invalid signature';
END;
$$;

-- ============================================================
-- build_adr_list tests
-- ============================================================

-- Test 9: build_adr_list returns ADRs from any channel in the workspace
DO $$
DECLARE
  result json;
BEGIN
  PERFORM create_adr('T_LIST', 'C_LIST_A', 'U_TEST', 'First ADR', 'context');
  PERFORM create_adr('T_LIST', 'C_LIST_B', 'U_TEST', 'Second ADR', 'context');

  -- Calling from C_LIST_A should still see both (workspace-scoped)
  result := build_adr_list('T_LIST', 'C_LIST_A');
  ASSERT result->>'response_type' = 'ephemeral',
    format('Expected ephemeral, got %s', result->>'response_type');
  ASSERT result->>'text' LIKE '%First ADR%',
    format('Should contain First ADR: %s', result->>'text');
  ASSERT result->>'text' LIKE '%Second ADR%',
    format('Should contain Second ADR from other channel: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 9 - build_adr_list returns ADRs from any channel in workspace';
END;
$$;

-- Test 10: build_adr_list returns empty message for workspace with no ADRs
DO $$
DECLARE
  result json;
BEGIN
  result := build_adr_list('T_EMPTY', 'C_EMPTY');
  ASSERT result->>'text' LIKE '%No ADRs found%',
    format('Should say no ADRs: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 10 - build_adr_list returns empty message for no ADRs';
END;
$$;

-- ============================================================
-- build_adr_view tests
-- ============================================================

-- Test 11: build_adr_view returns ADR details (Block Kit format after Step 9)
DO $$
DECLARE
  rec adrs;
  result json;
  blocks_text text;
BEGIN
  rec := create_adr('T_VIEW', 'C_VIEW', 'U_TEST', 'View Test ADR', 'Some important context');
  result := build_adr_view('T_VIEW', rec.id);
  -- Step 9 upgraded build_adr_view to return Block Kit blocks
  blocks_text := result::text;
  ASSERT blocks_text LIKE '%View Test ADR%',
    format('Should contain title in blocks: %s', blocks_text);
  ASSERT blocks_text LIKE '%DRAFT%',
    format('Should contain state in blocks: %s', blocks_text);
  RAISE NOTICE 'PASS: Test 11 - build_adr_view returns ADR details (Block Kit)';
END;
$$;

-- Test 12: build_adr_view returns not found for invalid ID
DO $$
DECLARE
  result json;
BEGIN
  result := build_adr_view('T_VIEW', 'ADR-NONEXISTENT');
  ASSERT result->>'text' LIKE '%not found%',
    format('Should say not found: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 12 - build_adr_view returns not found for invalid ID';
END;
$$;

-- ============================================================
-- check_request tests (via GUC simulation)
-- ============================================================

-- Test 13: check_request passes when not on a gated path
DO $$
BEGIN
  PERFORM set_config('request.path', '/rpc/some_other_function', true);
  PERFORM set_config('request.headers', '{}', true);
  PERFORM check_request();
  RAISE NOTICE 'PASS: Test 13 - check_request passes for non-gated path';
END;
$$;

-- Test 14: check_request raises for gated path with missing headers
DO $$
BEGIN
  PERFORM set_config('request.path', '/rpc/handle_slack_webhook', true);
  -- Set headers JSON without Slack signature headers
  PERFORM set_config('request.headers', '{"content-type":"application/json"}', true);
  BEGIN
    PERFORM check_request();
    RAISE EXCEPTION 'Should have raised missing headers';
  EXCEPTION WHEN OTHERS THEN
    ASSERT sqlerrm LIKE '%Missing Slack signature%',
      format('Unexpected error: %s', sqlerrm);
  END;
  RAISE NOTICE 'PASS: Test 14 - check_request raises for missing headers';
END;
$$;

ROLLBACK;
