-- Step 14: Fix PostgREST header access
-- PostgREST exposes request headers as a JSON blob via current_setting('request.headers'),
-- NOT as individual GUCs like request.header.<name>.
-- This migration fixes all functions that read Slack signature headers.

-- Fix check_request() to use request.headers JSON
CREATE OR REPLACE FUNCTION check_request() RETURNS void AS $$
DECLARE
  request_path text;
  headers json;
  sig text;
  ts text;
  ts_epoch bigint;
BEGIN
  request_path := current_setting('request.path', true);
  headers := current_setting('request.headers', true)::json;

  -- Gate Slack webhook and modal submission endpoints
  IF request_path IN (
    '/rpc/handle_slack_webhook',
    '/rpc/handle_slack_modal_submission',
    '/rpc/handle_slack_event'
  ) THEN
    sig := headers->>'x-slack-signature';
    ts := headers->>'x-slack-request-timestamp';

    IF sig IS NULL OR sig = '' OR ts IS NULL OR ts = '' THEN
      RAISE EXCEPTION 'Missing Slack signature headers'
        USING ERRCODE = 'P0401';
    END IF;

    -- Replay protection: reject timestamps older than 5 minutes
    ts_epoch := ts::bigint;
    IF abs(extract(epoch FROM now()) - ts_epoch) > 300 THEN
      RAISE EXCEPTION 'Slack request timestamp too old'
        USING ERRCODE = 'P0401';
    END IF;
  END IF;

  -- Gate git export callback
  IF request_path = '/rpc/handle_git_export_callback' THEN
    IF coalesce(headers->>'x-export-api-key', '') = '' THEN
      RAISE EXCEPTION 'Missing export API key'
        USING ERRCODE = 'P0401';
    END IF;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Fix handle_slack_webhook() to use request.headers JSON
CREATE OR REPLACE FUNCTION handle_slack_webhook(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  params jsonb;
  headers json;
  sig text;
  ts text;
  command_text text;
  subcommand text;
  team_id text;
  channel_id text;
  user_id text;
  payload jsonb;
BEGIN
  -- Read signature headers
  headers := current_setting('request.headers', true)::json;
  sig := headers->>'x-slack-signature';
  ts := headers->>'x-slack-request-timestamp';

  -- Check if this is an interactive payload (JSON wrapped in form encoding)
  IF raw_body LIKE 'payload=%' THEN
    -- Interactive payload: extract and parse the JSON
    payload := url_decode(split_part(raw_body, 'payload=', 2))::jsonb;

    -- Verify signature
    IF NOT verify_slack_signature(raw_body, ts, sig) THEN
      RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
    END IF;

    RETURN handle_interactive_payload(payload);
  END IF;

  -- Parse form-encoded slash command
  params := parse_form_body(raw_body);

  -- Verify signature
  IF NOT verify_slack_signature(raw_body, ts, sig) THEN
    RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
  END IF;

  command_text := coalesce(trim(params->>'text'), '');
  team_id := params->>'team_id';
  channel_id := params->>'channel_id';
  user_id := params->>'user_id';

  -- Extract subcommand (first word)
  subcommand := split_part(command_text, ' ', 1);

  CASE subcommand
    WHEN 'start' THEN
      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', 'Opening ADR drafting form...'
      );

    WHEN 'enable' THEN
      INSERT INTO channel_config (team_id, channel_id, enabled)
      VALUES (team_id, channel_id, true)
      ON CONFLICT ON CONSTRAINT channel_config_pkey
      DO UPDATE SET enabled = true;

      RETURN json_build_object(
        'response_type', 'in_channel',
        'text', ':white_check_mark: *ADR Bot enabled in this channel.*'
          || E'\n\n'
          || 'I will listen for `/adr start` commands and `@adr` mentions to help you draft Architectural Decision Records.'
          || E'\n\n'
          || '*What I can see:* Only messages in this channel after I was invited.'
          || E'\n'
          || '*What I do:* Create structured ADR drafts and export them to Git as pull requests.'
          || E'\n'
          || '*To disable:* Run `/adr disable`'
      );

    WHEN 'disable' THEN
      UPDATE channel_config cc SET enabled = false
      WHERE cc.team_id = team_id
        AND cc.channel_id = channel_id;

      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', 'ADR Bot disabled in this channel. Run `/adr enable` to re-enable.'
      );

    WHEN 'list' THEN
      RETURN build_adr_list(team_id, channel_id);

    WHEN 'view' THEN
      RETURN build_adr_view(team_id, split_part(command_text, ' ', 2));

    ELSE
      -- help or unknown command
      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', '*ADR Bot Commands:*'
          || E'\n'
          || '`/adr start` — Open a form to draft a new ADR'
          || E'\n'
          || '`/adr enable` — Enable ADR Bot in this channel'
          || E'\n'
          || '`/adr disable` — Disable ADR Bot in this channel'
          || E'\n'
          || '`/adr list` — List ADRs in this channel'
          || E'\n'
          || '`/adr view <id>` — View an ADR'
          || E'\n'
          || '`/adr help` — Show this help message'
      );
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fix handle_slack_modal_submission() to use request.headers JSON
CREATE OR REPLACE FUNCTION handle_slack_modal_submission(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  payload jsonb;
  headers json;
  sig text;
  ts text;
  user_id text;
  private_metadata text;
  meta_parts text[];
  channel_id text;
  thread_ts text;
  adr_id text;
  vals jsonb;
  p_title text;
  p_context text;
  p_decision text;
  p_alternatives text;
  p_consequences text;
  p_open_questions text;
  p_decision_drivers text;
  p_implementation_plan text;
  p_reviewers text;
  errors jsonb := '{}'::jsonb;
  rec adrs;
  update_payload jsonb;
  looked_up_team_id text;
BEGIN
  -- Parse JSON payload
  payload := raw_body::jsonb;

  -- Verify signature
  headers := current_setting('request.headers', true)::json;
  sig := headers->>'x-slack-signature';
  ts := headers->>'x-slack-request-timestamp';
  IF sig IS NOT NULL AND sig != '' THEN
    IF NOT verify_slack_signature(raw_body, ts, sig) THEN
      RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
    END IF;
  END IF;

  -- Extract user and metadata
  user_id := payload->'user'->>'id';
  private_metadata := payload->'view'->>'private_metadata';

  -- Parse private_metadata: channel_id|thread_ts|adr_id
  meta_parts := string_to_array(private_metadata, '|');
  channel_id := meta_parts[1];
  thread_ts := NULLIF(meta_parts[2], '');
  adr_id := NULLIF(meta_parts[3], '');

  -- Extract form values from view.state.values
  vals := payload->'view'->'state'->'values';

  p_title := vals->'title_block'->'title_input'->>'value';
  p_context := vals->'context_block'->'context_input'->>'value';
  p_decision := vals->'decision_block'->'decision_input'->>'value';
  p_alternatives := vals->'alternatives_block'->'alternatives_input'->>'value';
  p_consequences := vals->'consequences_block'->'consequences_input'->>'value';
  p_open_questions := vals->'open_questions_block'->'open_questions_input'->>'value';
  p_decision_drivers := vals->'decision_drivers_block'->'decision_drivers_input'->>'value';
  p_implementation_plan := vals->'implementation_plan_block'->'implementation_plan_input'->>'value';
  p_reviewers := vals->'reviewers_block'->'reviewers_input'->>'value';

  -- Validate required fields
  IF p_title IS NULL OR trim(p_title) = '' THEN
    errors := errors || jsonb_build_object('title_block', 'Title is required');
  END IF;
  IF p_context IS NULL OR trim(p_context) = '' THEN
    errors := errors || jsonb_build_object('context_block', 'Context is required');
  END IF;

  IF errors != '{}'::jsonb THEN
    RETURN json_build_object('response_action', 'errors', 'errors', errors);
  END IF;

  IF adr_id IS NOT NULL AND adr_id != '' THEN
    -- Edit existing ADR
    update_payload := jsonb_build_object(
      'title', p_title,
      'context_text', p_context,
      'decision', p_decision,
      'alternatives', p_alternatives,
      'consequences', p_consequences,
      'open_questions', p_open_questions,
      'decision_drivers', p_decision_drivers,
      'implementation_plan', p_implementation_plan,
      'reviewers', p_reviewers
    );
    rec := apply_adr_event(adr_id, 'ADR_UPDATED', 'user', user_id, update_payload);
  ELSE
    -- Create new ADR — look up team_id from channel_config
    SELECT cc.team_id INTO looked_up_team_id
    FROM channel_config cc WHERE cc.channel_id = channel_id LIMIT 1;

    rec := create_adr(
      p_team_id := looked_up_team_id,
      p_channel_id := channel_id,
      p_created_by := user_id,
      p_title := p_title,
      p_context_text := p_context,
      p_decision := p_decision,
      p_alternatives := p_alternatives,
      p_consequences := p_consequences,
      p_open_questions := p_open_questions,
      p_decision_drivers := p_decision_drivers,
      p_implementation_plan := p_implementation_plan,
      p_reviewers := p_reviewers,
      p_thread_ts := thread_ts
    );
  END IF;

  -- Return NULL to close the modal
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fix handle_slack_event() to use request.headers JSON
CREATE OR REPLACE FUNCTION handle_slack_event(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  payload jsonb;
  event_type text;
  event jsonb;
  channel text;
  thread_ts text;
  user_id text;
  is_enabled boolean;
BEGIN
  payload := raw_body::jsonb;

  -- URL verification challenge
  IF payload->>'type' = 'url_verification' THEN
    RETURN json_build_object('challenge', payload->>'challenge');
  END IF;

  -- Verify signature
  DECLARE
    headers json := current_setting('request.headers', true)::json;
    sig text := headers->>'x-slack-signature';
    ts text := headers->>'x-slack-request-timestamp';
  BEGIN
    IF sig IS NOT NULL AND sig != '' THEN
      IF NOT verify_slack_signature(raw_body, ts, sig) THEN
        RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
      END IF;
    END IF;
  END;

  -- Only handle event_callback
  IF payload->>'type' != 'event_callback' THEN
    RETURN json_build_object('ok', true);
  END IF;

  event := payload->'event';
  event_type := event->>'type';

  IF event_type = 'app_mention' THEN
    channel := event->>'channel';
    thread_ts := coalesce(event->>'thread_ts', event->>'ts');
    user_id := event->>'user';

    -- Check if channel is enabled
    SELECT cc.enabled INTO is_enabled FROM channel_config cc
    WHERE cc.channel_id = channel
    LIMIT 1;

    IF coalesce(is_enabled, false) = false THEN
      -- Channel not enabled, ignore
      RETURN json_build_object('ok', true);
    END IF;

    -- Enqueue "Start ADR" button message
    PERFORM enqueue_outbox(
      p_adr_id := NULL,
      p_event_id := NULL,
      p_destination := 'slack',
      p_payload := jsonb_build_object(
        'channel', channel,
        'thread_ts', thread_ts,
        'text', 'Ready to start an ADR?',
        'blocks', jsonb_build_array(
          jsonb_build_object(
            'type', 'section',
            'text', jsonb_build_object(
              'type', 'mrkdwn',
              'text', 'Ready to start an ADR? Click the button below to open the drafting form.'
            )
          ),
          jsonb_build_object(
            'type', 'actions',
            'elements', jsonb_build_array(
              jsonb_build_object(
                'type', 'button',
                'text', jsonb_build_object('type', 'plain_text', 'text', 'Start ADR'),
                'action_id', 'start_adr_from_mention',
                'value', channel || '|' || thread_ts,
                'style', 'primary'
              )
            )
          )
        )
      )
    );
  END IF;

  RETURN json_build_object('ok', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Reload PostgREST config so check_request picks up the changes
NOTIFY pgrst, 'reload config';
