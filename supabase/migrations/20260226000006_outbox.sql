-- Step 6: Transactional Outbox
-- Side effects enqueued in the same transaction as state changes.
-- Delivered asynchronously by pg_cron every 30 seconds via pg_net.

CREATE TABLE adr_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  adr_id text REFERENCES adrs(id),
  event_id uuid REFERENCES adr_events(id),
  destination text NOT NULL, -- 'slack' or 'git-export'
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  max_attempts integer NOT NULL DEFAULT 5,
  pg_net_request_id bigint
);

-- Partial index for efficient polling of undelivered rows
CREATE INDEX idx_outbox_undelivered ON adr_outbox (created_at)
  WHERE delivered_at IS NULL AND attempts < max_attempts;

-- RLS
ALTER TABLE adr_outbox ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service_role_all" ON adr_outbox FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Enqueue helper
CREATE FUNCTION enqueue_outbox(
  p_adr_id text,
  p_event_id uuid,
  p_destination text,
  p_payload jsonb
) RETURNS uuid AS $$
DECLARE
  outbox_id uuid;
BEGIN
  INSERT INTO adr_outbox (adr_id, event_id, destination, payload)
  VALUES (p_adr_id, p_event_id, p_destination, p_payload)
  RETURNING id INTO outbox_id;
  RETURN outbox_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Replace dispatch_side_effects stub with outbox-based implementation
CREATE OR REPLACE FUNCTION dispatch_side_effects(
  req adrs,
  old_state adr_state,
  new_state adr_state,
  event_type adr_event_type
) RETURNS void AS $$
DECLARE
  slack_payload jsonb;
  channel text;
BEGIN
  -- Check outbox suppression (set by interactive action handlers)
  IF current_setting('app.suppress_outbox', true) = 'true' THEN
    RETURN;
  END IF;

  channel := coalesce(req.slack_channel_id, req.channel_id);

  CASE event_type
    WHEN 'ADR_CREATED' THEN
      -- Post summary to channel
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format('*%s: %s*' || E'\n' || 'Status: %s | Created by: <@%s>',
          req.id, req.title, new_state, req.created_by)
      );
      -- Add thread_ts if available
      IF req.thread_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.thread_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    WHEN 'ADR_ACCEPTED', 'ADR_REJECTED', 'ADR_SUPERSEDED' THEN
      -- Post status update
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format('*%s* status changed to *%s*', req.id, new_state)
      );
      IF req.slack_message_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    WHEN 'EXPORT_REQUESTED' THEN
      -- Enqueue git export job
      PERFORM enqueue_outbox(req.id, NULL, 'git-export', jsonb_build_object(
        'adr_id', req.id,
        'title', req.title
      ));

    WHEN 'EXPORT_COMPLETED' THEN
      -- Post PR link
      IF req.git_pr_url IS NOT NULL THEN
        slack_payload := jsonb_build_object(
          'channel', channel,
          'text', format(':white_check_mark: *%s* exported to Git: %s', req.id, req.git_pr_url)
        );
        IF req.slack_message_ts IS NOT NULL THEN
          slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
        END IF;
        PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);
      END IF;

    WHEN 'EXPORT_FAILED' THEN
      -- Post failure notice
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format(':x: *%s* export failed. Try again with the Export button.', req.id)
      );
      IF req.slack_message_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    ELSE
      -- ADR_UPDATED, etc: no outbox notification
      NULL;
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Process outbox: poll undelivered rows, send via pg_net, mark delivered
CREATE FUNCTION process_outbox() RETURNS void AS $$
DECLARE
  row adr_outbox;
  bot_token text;
  supabase_url text;
  service_key text;
  request_id bigint;
BEGIN
  FOR row IN
    SELECT * FROM adr_outbox
    WHERE delivered_at IS NULL AND attempts < max_attempts
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

        UPDATE adr_outbox SET
          delivered_at = now(),
          attempts = attempts + 1,
          pg_net_request_id = request_id
        WHERE id = row.id;

      ELSIF row.destination = 'git-export' THEN
        supabase_url := get_secret('SUPABASE_URL');
        service_key := get_secret('SUPABASE_SERVICE_ROLE_KEY');

        -- Call git-export Edge Function
        IF supabase_url IS NOT NULL AND supabase_url != '' THEN
          SELECT net.http_post(
            url := supabase_url || '/functions/v1/git-export',
            headers := jsonb_build_object(
              'Content-Type', 'application/json',
              'Authorization', 'Bearer ' || service_key
            ),
            body := row.payload
          ) INTO request_id;

          UPDATE adr_outbox SET
            delivered_at = now(),
            attempts = attempts + 1,
            pg_net_request_id = request_id
          WHERE id = row.id;
        ELSE
          -- No supabase_url configured, mark as error
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

-- Schedule outbox processing every 30 seconds
SELECT cron.schedule(
  'process-outbox',
  '30 seconds',
  $$SELECT process_outbox()$$
);
