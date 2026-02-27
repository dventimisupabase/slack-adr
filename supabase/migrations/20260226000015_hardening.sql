-- Step 15: Hardening
-- Fix handle_interactive_payload NULL return, add team_id to event subscription,
-- and improve overall robustness.

-- Fix 1: handle_interactive_payload returns explicit ack for modal actions
CREATE OR REPLACE FUNCTION handle_interactive_payload(payload jsonb) RETURNS json AS $$
DECLARE
  action_id text;
  adr_id text;
  user_id text;
  rec adrs;
  bk jsonb;
BEGIN
  -- Extract action info
  action_id := payload->'actions'->0->>'action_id';
  adr_id := payload->'actions'->0->>'value';
  user_id := payload->'user'->>'id';

  IF action_id IS NULL THEN
    RETURN json_build_object('text', 'Unknown action.');
  END IF;

  -- Suppress outbox for interactive actions (response_url handles the update)
  PERFORM set_config('app.suppress_outbox', 'true', true);

  CASE action_id
    WHEN 'accept_adr' THEN
      IF adr_id IS NULL THEN
        RETURN json_build_object('text', 'Missing ADR ID.');
      END IF;
      rec := apply_adr_event(adr_id, 'ADR_ACCEPTED', 'user', user_id);
    WHEN 'reject_adr' THEN
      IF adr_id IS NULL THEN
        RETURN json_build_object('text', 'Missing ADR ID.');
      END IF;
      rec := apply_adr_event(adr_id, 'ADR_REJECTED', 'user', user_id);
    WHEN 'supersede_adr' THEN
      IF adr_id IS NULL THEN
        RETURN json_build_object('text', 'Missing ADR ID.');
      END IF;
      rec := apply_adr_event(adr_id, 'ADR_SUPERSEDED', 'user', user_id);
    WHEN 'export_adr' THEN
      IF adr_id IS NULL THEN
        RETURN json_build_object('text', 'Missing ADR ID.');
      END IF;
      -- Don't suppress outbox for export (it needs the git-export outbox row)
      PERFORM set_config('app.suppress_outbox', 'false', true);
      rec := apply_adr_event(adr_id, 'EXPORT_REQUESTED', 'user', user_id);
    WHEN 'edit_adr', 'start_adr_from_mention' THEN
      -- These are handled by the Edge Function (modal opening).
      -- If we reach here, the Edge Function routing failed — return safe ack.
      RETURN json_build_object('response_type', 'ephemeral', 'text', 'Opening form...');
    ELSE
      RETURN json_build_object('text', format('Unknown action: %s', action_id));
  END CASE;

  -- Clear suppress flag
  PERFORM set_config('app.suppress_outbox', 'false', true);

  -- Return updated Block Kit for response_url
  bk := build_adr_block_kit(rec, NULL, user_id);
  IF bk IS NOT NULL THEN
    RETURN json_build_object(
      'replace_original', true,
      'blocks', bk->'blocks'
    );
  END IF;

  RETURN json_build_object(
    'replace_original', true,
    'text', format('*%s* updated to *%s*', rec.id, rec.state)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fix 2: handle_slack_event adds team_id to channel_config lookup
CREATE OR REPLACE FUNCTION handle_slack_event(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  payload jsonb;
  event_type text;
  event jsonb;
  team_id text;
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

  team_id := payload->>'team_id';
  event := payload->'event';
  event_type := event->>'type';

  IF event_type = 'app_mention' THEN
    channel := event->>'channel';
    thread_ts := coalesce(event->>'thread_ts', event->>'ts');
    user_id := event->>'user';

    -- Check if channel is enabled for this team
    SELECT cc.enabled INTO is_enabled FROM channel_config cc
    WHERE cc.channel_id = channel AND cc.team_id = team_id
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
