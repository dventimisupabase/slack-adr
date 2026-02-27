-- Step 16: Outbox Delivery Tracking
-- Fix process_outbox() to not prematurely mark delivered_at.
-- Add check_outbox_deliveries() to confirm async pg_net responses.
--
-- Before: process_outbox() set delivered_at immediately after net.http_post(),
-- but pg_net is async — failed HTTP responses were never retried.
--
-- After: process_outbox() sets pg_net_request_id only (in-flight).
-- check_outbox_deliveries() polls net._http_response and either confirms
-- delivery or resets the row for retry.

-- Add index for in-flight rows (sent but not yet confirmed)
CREATE INDEX IF NOT EXISTS idx_outbox_inflight ON adr_outbox (created_at)
  WHERE delivered_at IS NULL AND pg_net_request_id IS NOT NULL;

-- Rewrite process_outbox: don't set delivered_at
CREATE OR REPLACE FUNCTION process_outbox() RETURNS void AS $$
DECLARE
  row adr_outbox;
  bot_token text;
  supabase_url text;
  service_key text;
  request_id bigint;
BEGIN
  FOR row IN
    SELECT * FROM adr_outbox
    WHERE delivered_at IS NULL
      AND pg_net_request_id IS NULL  -- skip in-flight rows
      AND attempts < max_attempts
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 20
  LOOP
    BEGIN
      IF row.destination = 'slack' THEN
        bot_token := get_secret('SLACK_BOT_TOKEN');
        SELECT net.http_post(
          url := 'https://slack.com/api/chat.postMessage',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || bot_token
          ),
          body := row.payload
        ) INTO request_id;

        -- Mark as in-flight (NOT delivered)
        UPDATE adr_outbox SET
          attempts = attempts + 1,
          pg_net_request_id = request_id
        WHERE id = row.id;

      ELSIF row.destination = 'git-export' THEN
        supabase_url := get_secret('SUPABASE_URL');
        service_key := get_secret('SUPABASE_SERVICE_ROLE_KEY');

        IF supabase_url IS NOT NULL AND supabase_url != '' THEN
          SELECT net.http_post(
            url := supabase_url || '/functions/v1/git-export',
            headers := jsonb_build_object(
              'Content-Type', 'application/json',
              'Authorization', 'Bearer ' || service_key
            ),
            body := row.payload
          ) INTO request_id;

          -- Mark as in-flight (NOT delivered)
          UPDATE adr_outbox SET
            attempts = attempts + 1,
            pg_net_request_id = request_id
          WHERE id = row.id;
        ELSE
          UPDATE adr_outbox SET
            attempts = attempts + 1,
            last_error = 'supabase_url not configured'
          WHERE id = row.id;
        END IF;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      UPDATE adr_outbox SET
        attempts = attempts + 1,
        last_error = sqlerrm
      WHERE id = row.id;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- New function: check async pg_net responses and confirm/retry
CREATE OR REPLACE FUNCTION check_outbox_deliveries() RETURNS void AS $$
DECLARE
  row adr_outbox;
  resp_status int;
  resp_body text;
  resp_timed_out boolean;
  resp_found boolean;
  body_json jsonb;
  is_success boolean;
BEGIN
  FOR row IN
    SELECT * FROM adr_outbox
    WHERE delivered_at IS NULL
      AND pg_net_request_id IS NOT NULL
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 50
  LOOP
    BEGIN
      -- Look up the pg_net response
      SELECT r.status_code, r.content, r.timed_out, true
      INTO resp_status, resp_body, resp_timed_out, resp_found
      FROM net._http_response r
      WHERE r.id = row.pg_net_request_id;

      -- No response yet — still in flight, skip
      IF NOT coalesce(resp_found, false) THEN
        CONTINUE;
      END IF;

      -- Handle timeout
      IF resp_timed_out THEN
        UPDATE adr_outbox SET
          pg_net_request_id = NULL,
          last_error = 'Request timed out'
        WHERE id = row.id;
        CONTINUE;
      END IF;

      -- Handle HTTP-level errors (non-2xx)
      IF resp_status < 200 OR resp_status >= 300 THEN
        UPDATE adr_outbox SET
          pg_net_request_id = NULL,
          last_error = format('HTTP %s: %s', resp_status, left(resp_body, 200))
        WHERE id = row.id;
        CONTINUE;
      END IF;

      -- HTTP 2xx — check body for Slack API errors
      is_success := true;
      IF row.destination = 'slack' THEN
        BEGIN
          body_json := resp_body::jsonb;
          IF body_json->>'ok' = 'false' THEN
            is_success := false;
            UPDATE adr_outbox SET
              pg_net_request_id = NULL,
              last_error = format('Slack API error: %s', body_json->>'error')
            WHERE id = row.id;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          -- Body not valid JSON, treat as success if HTTP was 2xx
          NULL;
        END;
      END IF;

      -- Mark as delivered
      IF is_success THEN
        UPDATE adr_outbox SET delivered_at = now()
        WHERE id = row.id;

        -- Clean up pg_net response to avoid bloat
        DELETE FROM net._http_response WHERE id = row.pg_net_request_id;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      -- Don't let one bad row stop the whole batch
      UPDATE adr_outbox SET
        pg_net_request_id = NULL,
        last_error = format('check_deliveries error: %s', sqlerrm)
      WHERE id = row.id;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fix capture_thread_timestamps to use correct column name (content, not body)
CREATE OR REPLACE FUNCTION capture_thread_timestamps() RETURNS void AS $$
DECLARE
  row record;
  response_body jsonb;
  ts_value text;
BEGIN
  FOR row IN
    SELECT ob.id AS outbox_id, ob.adr_id, ob.pg_net_request_id
    FROM adr_outbox ob
    JOIN adrs a ON a.id = ob.adr_id
    WHERE ob.delivered_at IS NOT NULL
      AND ob.destination = 'slack'
      AND ob.pg_net_request_id IS NOT NULL
      AND a.slack_message_ts IS NULL
      AND NOT (ob.payload ? 'thread_ts')
    ORDER BY ob.created_at
    LIMIT 20
  LOOP
    BEGIN
      SELECT (r.content::jsonb) INTO response_body
      FROM net._http_response r
      WHERE r.id = row.pg_net_request_id;

      IF response_body IS NOT NULL AND response_body->>'ok' = 'true' THEN
        ts_value := response_body->>'ts';
        IF ts_value IS NOT NULL THEN
          UPDATE adrs SET slack_message_ts = ts_value
          WHERE id = row.adr_id AND slack_message_ts IS NULL;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fix check_request: remove modal submission from gated paths.
-- The Edge Function transforms the body before forwarding to PostgREST,
-- so Slack signature verification is impossible at the SQL level.
-- Modal submission is called internally with service role key — trust boundary
-- is the Edge Function, not PostgREST.
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

  -- Gate Slack webhook and event endpoints (signature can be verified)
  -- Note: handle_slack_modal_submission is NOT gated here because the Edge
  -- Function transforms the body, making HMAC verification impossible.
  -- It's protected by the service role key requirement instead.
  IF request_path IN (
    '/rpc/handle_slack_webhook',
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

-- Remove signature verification from handle_slack_modal_submission.
-- The Edge Function transforms the body (JSON.stringify(payload)) before
-- forwarding, so the Slack HMAC can't be verified against the transformed body.
-- Auth is enforced by the service role key on the PostgREST call.
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
  payload := raw_body::jsonb;

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

-- Schedule delivery checking every 30 seconds
SELECT cron.schedule(
  'check-outbox-deliveries',
  '30 seconds',
  $$SELECT check_outbox_deliveries()$$
);
