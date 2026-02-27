-- Step 29: Event deduplication + schema hardening
-- 1. processed_events table for Slack event deduplication
-- 2. Rewrite handle_slack_event with dedup check
-- 3. ALTER adrs.context_text to NOT NULL
-- 4. Defensive NULL check in handle_slack_modal_submission
-- 5. Cron job to clean up old processed_events

-- 1. Processed events table for deduplication
CREATE TABLE IF NOT EXISTS processed_events (
  event_id text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- RLS (internal use only)
ALTER TABLE processed_events ENABLE ROW LEVEL SECURITY;

-- 2. Rewrite handle_slack_event with dedup
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

-- 3. Schema hardening: context_text NOT NULL
-- First update any existing NULL values (shouldn't exist due to function-level validation)
UPDATE adrs SET context_text = '' WHERE context_text IS NULL;
ALTER TABLE adrs ALTER COLUMN context_text SET NOT NULL;

-- 4. Defensive NULL check in handle_slack_modal_submission
CREATE OR REPLACE FUNCTION handle_slack_modal_submission(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  payload jsonb;
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
  -- Guard against slow queries
  SET LOCAL statement_timeout = '2900ms';

  payload := raw_body::jsonb;

  user_id := payload->'user'->>'id';
  private_metadata := payload->'view'->>'private_metadata';

  meta_parts := string_to_array(private_metadata, '|');
  channel_id := meta_parts[1];
  thread_ts := NULLIF(meta_parts[2], '');
  adr_id := NULLIF(meta_parts[3], '');

  vals := payload->'view'->'state'->'values';

  -- Defensive: check if vals is NULL (malformed payload)
  IF vals IS NULL THEN
    RETURN json_build_object(
      'response_action', 'errors',
      'errors', jsonb_build_object(
        'title_block', 'Form submission incomplete. Please try again.'
      )
    );
  END IF;

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
    -- Look up team_id from channel_config
    SELECT cc.team_id INTO looked_up_team_id
    FROM channel_config cc WHERE cc.channel_id = channel_id LIMIT 1;

    -- Reject if channel has no config (would create orphaned ADR)
    IF looked_up_team_id IS NULL THEN
      RETURN json_build_object(
        'response_action', 'errors',
        'errors', jsonb_build_object(
          'title_block',
          'ADR Bot is not enabled in this channel. Run /adr enable first.'
        )
      );
    END IF;

    rec := create_adr(
      p_team_id := looked_up_team_id,
      p_channel_id := channel_id,
      p_created_by := user_id,
      p_title := p_title,
      p_context_text := p_context,
      p_thread_ts := thread_ts,
      p_decision := p_decision,
      p_alternatives := p_alternatives,
      p_consequences := p_consequences,
      p_open_questions := p_open_questions,
      p_decision_drivers := p_decision_drivers,
      p_implementation_plan := p_implementation_plan,
      p_reviewers := p_reviewers
    );
  END IF;

  -- Close modal
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Cron job to clean up old processed events (daily at 4:30am)
SELECT cron.schedule(
  'cleanup-processed-events',
  '30 4 * * *',
  $$DELETE FROM processed_events WHERE created_at < now() - interval '24 hours'$$
);
