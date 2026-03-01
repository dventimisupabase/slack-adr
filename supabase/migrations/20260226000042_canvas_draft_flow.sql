-- Step 43: Canvas-based collaborative ADR drafting flow
-- 1. Update handle_slack_event: dual buttons (Start ADR + Draft in Canvas)
-- 2. Update handle_interactive_payload: add canvas action_ids to passthrough

-- 1. Rewrite handle_slack_event with dual buttons for app_mention
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
  p_event_id text;
  inserted boolean;
BEGIN
  -- Guard against slow queries hitting Slack's 3-second deadline
  SET LOCAL statement_timeout = '2900ms';

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

  IF payload->>'type' != 'event_callback' THEN
    RETURN json_build_object('ok', true);
  END IF;

  -- Deduplication: check event_id
  p_event_id := payload->>'event_id';
  IF p_event_id IS NOT NULL AND p_event_id != '' THEN
    INSERT INTO processed_events (event_id) VALUES (p_event_id)
    ON CONFLICT (event_id) DO NOTHING;

    GET DIAGNOSTICS inserted = ROW_COUNT;
    IF NOT inserted THEN
      -- Already processed this event
      RETURN json_build_object('ok', true);
    END IF;
  END IF;

  team_id := payload->>'team_id';
  event := payload->'event';
  event_type := event->>'type';

  IF event_type = 'app_mention' THEN
    channel := event->>'channel';
    thread_ts := coalesce(event->>'thread_ts', event->>'ts');
    user_id := event->>'user';

    SELECT cc.enabled INTO is_enabled FROM channel_config cc
    WHERE cc.channel_id = channel AND cc.team_id = team_id
    LIMIT 1;

    IF coalesce(is_enabled, false) = false THEN
      RETURN json_build_object('ok', true);
    END IF;

    -- Enqueue message with dual buttons: Start ADR + Draft in Canvas
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
              'text', 'Use the form for a quick draft, or open a Canvas for collaborative editing.'
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
              ),
              jsonb_build_object(
                'type', 'button',
                'text', jsonb_build_object('type', 'plain_text', 'text', 'Draft in Canvas'),
                'action_id', 'draft_adr_canvas',
                'value', channel || '|' || thread_ts
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

-- 2. Update handle_interactive_payload: add canvas action_ids to passthrough
CREATE OR REPLACE FUNCTION handle_interactive_payload(payload jsonb) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  action_id text;
  adr_id text;
  user_id text;
  team_id text;
  target_adr adrs;
  rec adrs;
  bk jsonb;
BEGIN
  -- Extract action info
  action_id := payload->'actions'->0->>'action_id';
  adr_id := payload->'actions'->0->>'value';
  user_id := payload->'user'->>'id';
  team_id := coalesce(payload->'team'->>'id', payload->>'team_id');

  IF action_id IS NULL THEN
    RETURN json_build_object('text', 'Unknown action.');
  END IF;

  -- For modal-opening actions, no team ownership check needed (Edge Function handles)
  IF action_id IN ('edit_adr', 'start_adr_from_mention') THEN
    RETURN json_build_object('response_type', 'ephemeral', 'text', 'Opening form...');
  END IF;

  -- For canvas actions, pass through to Edge Function (it handles Slack API calls)
  IF action_id IN ('draft_adr_canvas', 'finalize_adr_from_canvas') THEN
    RETURN json_build_object('response_type', 'ephemeral', 'text', 'Processing...');
  END IF;

  -- Require both adr_id and team_id for state-changing actions
  IF adr_id IS NULL THEN
    RETURN json_build_object('text', 'Missing ADR ID.');
  END IF;

  -- Verify team ownership before any state-changing action
  SELECT * INTO target_adr FROM adrs a
  WHERE a.id = adr_id
    AND a.team_id = team_id;

  IF NOT FOUND THEN
    RETURN json_build_object('text', format('ADR `%s` not found.', adr_id));
  END IF;

  -- Handle delete separately (different flow — no event, just delete)
  IF action_id = 'delete_adr' THEN
    IF target_adr.state != 'DRAFT' THEN
      RETURN json_build_object(
        'replace_original', false,
        'text', format('Cannot delete *%s* — only DRAFT ADRs can be deleted. This ADR is %s.', target_adr.id, target_adr.state)
      );
    END IF;
    DELETE FROM adr_outbox WHERE adr_id = target_adr.id;
    DELETE FROM adr_events WHERE adr_id = target_adr.id;
    DELETE FROM adrs WHERE id = target_adr.id;
    RETURN json_build_object(
      'replace_original', true,
      'text', format('Deleted *%s: %s*. This action cannot be undone.', target_adr.id, target_adr.title)
    );
  END IF;

  -- Suppress outbox for interactive actions (response_url handles the update)
  PERFORM set_config('app.suppress_outbox', 'true', true);

  BEGIN
    CASE action_id
      WHEN 'accept_adr' THEN
        rec := apply_adr_event(target_adr.id, 'ADR_ACCEPTED', 'user', user_id);
      WHEN 'reject_adr' THEN
        rec := apply_adr_event(target_adr.id, 'ADR_REJECTED', 'user', user_id);
      WHEN 'supersede_adr' THEN
        rec := apply_adr_event(target_adr.id, 'ADR_SUPERSEDED', 'user', user_id);
      WHEN 'export_adr' THEN
        -- Don't suppress outbox for export (it needs the git-export outbox row)
        PERFORM set_config('app.suppress_outbox', 'false', true);
        rec := apply_adr_event(target_adr.id, 'EXPORT_REQUESTED', 'user', user_id);
      ELSE
        PERFORM set_config('app.suppress_outbox', 'false', true);
        RETURN json_build_object('text', format('Unknown action: %s', action_id));
    END CASE;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.suppress_outbox', 'false', true);
    RETURN json_build_object(
      'replace_original', false,
      'text', format('Cannot %s *%s* — this ADR is currently %s.',
        replace(action_id, '_adr', ''),
        target_adr.id,
        target_adr.state)
    );
  END;

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
