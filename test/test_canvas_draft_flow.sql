-- test/test_canvas_draft_flow.sql
-- Tests for Step 43: Canvas-based collaborative ADR drafting flow
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_canvas_draft_flow.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_CANVAS', 'C_CANVAS', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: app_mention outbox contains both Start ADR and Draft in Canvas buttons
DO $$
DECLARE
  result json;
  outbox_row record;
  payload_text text;
BEGIN
  result := handle_slack_event(json_build_object(
    'type', 'event_callback',
    'team_id', 'T_CANVAS',
    'event_id', 'Ev_CANVAS_001',
    'event', json_build_object(
      'type', 'app_mention',
      'channel', 'C_CANVAS',
      'ts', '1700000100.000001',
      'thread_ts', '1700000100.000000',
      'user', 'U_CANVAS'
    )
  )::text);

  SELECT * INTO outbox_row FROM adr_outbox
  WHERE destination = 'slack' AND payload->>'channel' = 'C_CANVAS'
  ORDER BY created_at DESC LIMIT 1;

  payload_text := outbox_row.payload::text;

  ASSERT payload_text LIKE '%start_adr_from_mention%',
    format('Outbox payload should contain start_adr_from_mention, got: %s', left(payload_text, 500));
  ASSERT payload_text LIKE '%draft_adr_canvas%',
    format('Outbox payload should contain draft_adr_canvas, got: %s', left(payload_text, 500));
  ASSERT payload_text LIKE '%Start ADR%',
    format('Outbox payload should contain Start ADR button text, got: %s', left(payload_text, 500));
  ASSERT payload_text LIKE '%Draft in Canvas%',
    format('Outbox payload should contain Draft in Canvas button text, got: %s', left(payload_text, 500));
  RAISE NOTICE 'PASS: Test 1 - app_mention outbox contains both buttons';
END;
$$;

-- Test 2: app_mention outbox section text mentions both options
DO $$
DECLARE
  outbox_row record;
  section_text text;
BEGIN
  SELECT * INTO outbox_row FROM adr_outbox
  WHERE destination = 'slack' AND payload->>'channel' = 'C_CANVAS'
  ORDER BY created_at DESC LIMIT 1;

  section_text := outbox_row.payload->'blocks'->0->'text'->>'text';

  ASSERT section_text LIKE '%form%',
    format('Section text should mention form, got: %s', section_text);
  ASSERT section_text LIKE '%Canvas%',
    format('Section text should mention Canvas, got: %s', section_text);
  RAISE NOTICE 'PASS: Test 2 - Section text mentions both options';
END;
$$;

-- Test 3: draft_adr_canvas action passes through to Edge Function
DO $$
DECLARE
  result json;
  payload jsonb;
BEGIN
  payload := jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_CANVAS'),
    'team', jsonb_build_object('id', 'T_CANVAS'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'draft_adr_canvas',
      'value', 'C_CANVAS|1700000100.000000'
    ))
  );

  result := handle_interactive_payload(payload);
  ASSERT result->>'text' = 'Processing...',
    format('draft_adr_canvas should pass through with Processing..., got: %s', result::text);
  RAISE NOTICE 'PASS: Test 3 - draft_adr_canvas passes through to Edge Function';
END;
$$;

-- Test 4: finalize_adr_from_canvas action passes through to Edge Function
DO $$
DECLARE
  result json;
  payload jsonb;
BEGIN
  payload := jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_CANVAS'),
    'team', jsonb_build_object('id', 'T_CANVAS'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'finalize_adr_from_canvas',
      'value', 'FCANVAS123|C_CANVAS|1700000100.000000'
    ))
  );

  result := handle_interactive_payload(payload);
  ASSERT result->>'text' = 'Processing...',
    format('finalize_adr_from_canvas should pass through with Processing..., got: %s', result::text);
  RAISE NOTICE 'PASS: Test 4 - finalize_adr_from_canvas passes through to Edge Function';
END;
$$;

-- Test 5: start_adr_from_mention still passes through (regression test)
DO $$
DECLARE
  result json;
  payload jsonb;
BEGIN
  payload := jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_CANVAS'),
    'team', jsonb_build_object('id', 'T_CANVAS'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'start_adr_from_mention',
      'value', 'C_CANVAS|1700000100.000000'
    ))
  );

  result := handle_interactive_payload(payload);
  ASSERT result->>'text' = 'Opening form...',
    format('start_adr_from_mention should still return Opening form..., got: %s', result::text);
  RAISE NOTICE 'PASS: Test 5 - start_adr_from_mention still works (regression)';
END;
$$;

-- Test 6: edit_adr still passes through (regression test)
DO $$
DECLARE
  result json;
  payload jsonb;
BEGIN
  payload := jsonb_build_object(
    'type', 'block_actions',
    'user', jsonb_build_object('id', 'U_CANVAS'),
    'team', jsonb_build_object('id', 'T_CANVAS'),
    'actions', jsonb_build_array(jsonb_build_object(
      'action_id', 'edit_adr',
      'value', 'ADR-FAKE-123'
    ))
  );

  result := handle_interactive_payload(payload);
  ASSERT result->>'text' = 'Opening form...',
    format('edit_adr should still return Opening form..., got: %s', result::text);
  RAISE NOTICE 'PASS: Test 6 - edit_adr still works (regression)';
END;
$$;

-- Test 7: Draft in Canvas button value contains channel and thread_ts
DO $$
DECLARE
  outbox_row record;
  elements jsonb;
  canvas_btn jsonb;
  btn_value text;
BEGIN
  SELECT * INTO outbox_row FROM adr_outbox
  WHERE destination = 'slack' AND payload->>'channel' = 'C_CANVAS'
  ORDER BY created_at DESC LIMIT 1;

  elements := outbox_row.payload->'blocks'->1->'elements';

  -- Find the draft_adr_canvas button
  SELECT elem INTO canvas_btn FROM jsonb_array_elements(elements) AS elem
  WHERE elem->>'action_id' = 'draft_adr_canvas';

  btn_value := canvas_btn->>'value';
  ASSERT btn_value LIKE 'C_CANVAS|%',
    format('Canvas button value should start with channel, got: %s', btn_value);
  ASSERT btn_value LIKE '%1700000100.000000',
    format('Canvas button value should end with thread_ts, got: %s', btn_value);
  RAISE NOTICE 'PASS: Test 7 - Canvas button value contains channel|thread_ts';
END;
$$;

-- Test 8: Outbox actions block has exactly 2 buttons
DO $$
DECLARE
  outbox_row record;
  elements jsonb;
  btn_count int;
BEGIN
  SELECT * INTO outbox_row FROM adr_outbox
  WHERE destination = 'slack' AND payload->>'channel' = 'C_CANVAS'
  ORDER BY created_at DESC LIMIT 1;

  elements := outbox_row.payload->'blocks'->1->'elements';
  btn_count := jsonb_array_length(elements);

  ASSERT btn_count = 2,
    format('Actions block should have exactly 2 buttons, got: %s', btn_count);
  RAISE NOTICE 'PASS: Test 8 - Actions block has exactly 2 buttons';
END;
$$;

ROLLBACK;
