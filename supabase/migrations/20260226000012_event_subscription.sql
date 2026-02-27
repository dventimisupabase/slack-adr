-- Step 12: Event Subscription (app_mention)
-- Handles Slack Events API callbacks.

CREATE FUNCTION handle_slack_event(raw_body text) RETURNS json AS $$
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
    sig text := current_setting('request.header.x_slack_signature', true);
    ts text := current_setting('request.header.x_slack_request_timestamp', true);
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
      -- Use a placeholder adr_id (we don't have one yet)
      -- Create a temporary reference using the channel
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
