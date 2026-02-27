-- test/test_interactive_team_scoping.sql
-- Tests for Step 23: Interactive payload team ownership verification
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_interactive_team_scoping.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Seed test data
INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_INT', 'C_INT', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: accept_adr button rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OTHER', 'C_OTHER', 'U_OTHER', 'Cross-team accept target', 'ctx');

  result := handle_interactive_payload(jsonb_build_object(
    'type', 'block_actions',
    'team', jsonb_build_object('id', 'T_INT'),
    'user', jsonb_build_object('id', 'U_INT'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'accept_adr',
      'value', rec.id
    ))
  ));

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team accept, got: %s', result::text);

  -- ADR should still be DRAFT
  SELECT * INTO rec FROM adrs WHERE id = rec.id;
  ASSERT rec.state = 'DRAFT',
    format('ADR should still be DRAFT, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 1 - accept_adr button rejects ADR from different team';
END;
$$;

-- Test 2: reject_adr button rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OTHER', 'C_OTHER', 'U_OTHER', 'Cross-team reject target', 'ctx');

  result := handle_interactive_payload(jsonb_build_object(
    'type', 'block_actions',
    'team', jsonb_build_object('id', 'T_INT'),
    'user', jsonb_build_object('id', 'U_INT'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'reject_adr',
      'value', rec.id
    ))
  ));

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team reject, got: %s', result::text);

  SELECT * INTO rec FROM adrs WHERE id = rec.id;
  ASSERT rec.state = 'DRAFT',
    format('ADR should still be DRAFT, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 2 - reject_adr button rejects ADR from different team';
END;
$$;

-- Test 3: supersede_adr button rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_OTHER', 'C_OTHER', 'U_OTHER', 'Cross-team supersede target', 'ctx');
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_OTHER');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_interactive_payload(jsonb_build_object(
    'type', 'block_actions',
    'team', jsonb_build_object('id', 'T_INT'),
    'user', jsonb_build_object('id', 'U_INT'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'supersede_adr',
      'value', rec.id
    ))
  ));

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team supersede, got: %s', result::text);

  SELECT * INTO rec FROM adrs WHERE id = rec.id;
  ASSERT rec.state = 'ACCEPTED',
    format('ADR should still be ACCEPTED, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 3 - supersede_adr button rejects ADR from different team';
END;
$$;

-- Test 4: export_adr button rejects ADR from different team
DO $$
DECLARE
  rec adrs;
  result json;
  outbox_count int;
BEGIN
  rec := create_adr('T_OTHER', 'C_OTHER', 'U_OTHER', 'Cross-team export target', 'ctx');

  result := handle_interactive_payload(jsonb_build_object(
    'type', 'block_actions',
    'team', jsonb_build_object('id', 'T_INT'),
    'user', jsonb_build_object('id', 'U_INT'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'export_adr',
      'value', rec.id
    ))
  ));

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team export, got: %s', result::text);

  -- No git-export outbox row should exist
  SELECT count(*) INTO outbox_count FROM adr_outbox
  WHERE adr_id = rec.id AND destination = 'git-export';
  ASSERT outbox_count = 0,
    format('Should not create export outbox row, got %s', outbox_count);
  RAISE NOTICE 'PASS: Test 4 - export_adr button rejects ADR from different team';
END;
$$;

-- Test 5: accept_adr button works for same team
DO $$
DECLARE
  rec adrs;
  result json;
  updated_state adr_state;
BEGIN
  rec := create_adr('T_INT', 'C_INT', 'U_INT', 'Same team accept', 'ctx');

  result := handle_interactive_payload(jsonb_build_object(
    'type', 'block_actions',
    'team', jsonb_build_object('id', 'T_INT'),
    'user', jsonb_build_object('id', 'U_INT'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'accept_adr',
      'value', rec.id
    ))
  ));

  SELECT state INTO updated_state FROM adrs WHERE id = rec.id;
  ASSERT updated_state = 'ACCEPTED',
    format('ADR should be ACCEPTED, got %s', updated_state);
  ASSERT result::text LIKE '%ACCEPTED%',
    format('Response should reflect ACCEPTED, got: %s', left(result::text, 200));
  RAISE NOTICE 'PASS: Test 5 - accept_adr button works for same team';
END;
$$;

-- Test 6: Interactive payload without team field falls back safely
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_INT', 'C_INT', 'U_INT', 'No team payload', 'ctx');

  result := handle_interactive_payload(jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_INT'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'accept_adr',
      'value', rec.id
    ))
  ));

  -- Without team_id, should not find the ADR (NULL != 'T_INT')
  ASSERT result->>'text' LIKE '%not found%',
    format('Missing team should reject, got: %s', result::text);

  SELECT * INTO rec FROM adrs WHERE id = rec.id;
  ASSERT rec.state = 'DRAFT',
    format('ADR should still be DRAFT, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 6 - Interactive payload without team field falls back safely';
END;
$$;

ROLLBACK;
