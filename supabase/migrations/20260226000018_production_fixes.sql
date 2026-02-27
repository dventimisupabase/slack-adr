-- Step 18: Production readiness fixes
-- 1. check_outbox_deliveries: stop deleting net._http_response rows
--    (capture_thread_timestamps needs them; pg_net TTL handles cleanup)
-- 2. handle_slack_modal_submission: reject channels with no config
-- 3. recover_stuck_exports: auto-fail exports stuck > 30 minutes

-- Fix 1: Remove response row deletion from check_outbox_deliveries
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
      SELECT r.status_code, r.content, r.timed_out, true
      INTO resp_status, resp_body, resp_timed_out, resp_found
      FROM net._http_response r
      WHERE r.id = row.pg_net_request_id;

      IF NOT coalesce(resp_found, false) THEN
        CONTINUE;
      END IF;

      IF resp_timed_out THEN
        UPDATE adr_outbox SET
          pg_net_request_id = NULL,
          last_error = 'Request timed out'
        WHERE id = row.id;
        CONTINUE;
      END IF;

      IF resp_status < 200 OR resp_status >= 300 THEN
        UPDATE adr_outbox SET
          pg_net_request_id = NULL,
          last_error = format('HTTP %s: %s', resp_status, left(resp_body, 200))
        WHERE id = row.id;
        CONTINUE;
      END IF;

      is_success := true;
      IF row.destination = 'slack' THEN
        BEGIN
          body_json := resp_body::jsonb;
          IF body_json->>'ok' = 'false' THEN
            is_success := false;
            UPDATE adr_outbox SET
              pg_net_request_id = NULL,
              last_error = format('Slack API error: %s', coalesce(body_json->>'error', 'unknown'))
            WHERE id = row.id;
          END IF;
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
      END IF;

      IF is_success THEN
        UPDATE adr_outbox SET delivered_at = now()
        WHERE id = row.id;
        -- Do NOT delete from net._http_response here.
        -- capture_thread_timestamps needs the response to extract Slack ts.
        -- pg_net's built-in TTL handles cleanup of old response rows.
      END IF;

    EXCEPTION WHEN OTHERS THEN
      UPDATE adr_outbox SET
        pg_net_request_id = NULL,
        last_error = format('check_deliveries error: %s', sqlerrm)
      WHERE id = row.id;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fix 2: Modal submission rejects channels without config
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

  user_id := payload->'user'->>'id';
  private_metadata := payload->'view'->>'private_metadata';

  meta_parts := string_to_array(private_metadata, '|');
  channel_id := meta_parts[1];
  thread_ts := NULLIF(meta_parts[2], '');
  adr_id := NULLIF(meta_parts[3], '');

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

  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fix 3: Recover stuck exports (> 30 min in EXPORT_REQUESTED with no callback)
CREATE FUNCTION recover_stuck_exports() RETURNS void AS $$
DECLARE
  stuck record;
BEGIN
  FOR stuck IN
    SELECT DISTINCT a.id
    FROM adrs a
    JOIN adr_events e ON e.adr_id = a.id
    WHERE e.event_type = 'EXPORT_REQUESTED'
      AND e.created_at < now() - interval '30 minutes'
      -- No subsequent export completion or failure
      AND NOT EXISTS (
        SELECT 1 FROM adr_events e2
        WHERE e2.adr_id = a.id
          AND e2.event_type IN ('EXPORT_COMPLETED', 'EXPORT_FAILED')
          AND e2.created_at > e.created_at
      )
  LOOP
    BEGIN
      PERFORM apply_adr_event(
        stuck.id, 'EXPORT_FAILED', 'system', 'stuck-export-recovery',
        jsonb_build_object('error', 'Export timed out after 30 minutes')
      );
    EXCEPTION WHEN OTHERS THEN
      -- Log but don't fail the whole batch
      RAISE WARNING 'Failed to recover stuck export %: %', stuck.id, sqlerrm;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Schedule stuck export recovery every 5 minutes
SELECT cron.schedule(
  'recover-stuck-exports',
  '*/5 * * * *',
  $$SELECT recover_stuck_exports()$$
);
