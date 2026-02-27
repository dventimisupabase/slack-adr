-- Step 17: Retry backoff and ADR_UPDATED notification
-- 1. process_outbox() uses exponential backoff: skip rows where
--    now() < created_at + (2^attempts * interval '1 minute').
--    Fresh rows (attempts=0) are processed immediately.
-- 2. dispatch_side_effects() sends Block Kit notification on ADR_UPDATED.

-- Rewrite process_outbox with exponential backoff
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
      -- Exponential backoff: 0 (immediate), 2min, 4min, 8min, 16min
      AND (
        attempts = 0
        OR now() >= created_at + (power(2, attempts) * interval '1 minute')
      )
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

-- Add ADR_UPDATED to dispatch_side_effects
CREATE OR REPLACE FUNCTION dispatch_side_effects(
  req adrs,
  old_state adr_state,
  new_state adr_state,
  event_type adr_event_type
) RETURNS void AS $$
DECLARE
  slack_payload jsonb;
  bk jsonb;
  channel text;
  thread text;
  markdown text;
BEGIN
  -- Check outbox suppression
  IF current_setting('app.suppress_outbox', true) = 'true' THEN
    RETURN;
  END IF;

  channel := coalesce(req.slack_channel_id, req.channel_id);

  CASE event_type
    WHEN 'ADR_CREATED' THEN
      bk := build_adr_block_kit(req, event_type, req.created_by);
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format('*%s: %s* — Status: %s', req.id, req.title, new_state)
      );
      IF bk IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('blocks', bk->'blocks');
      END IF;
      IF req.thread_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.thread_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    WHEN 'ADR_UPDATED' THEN
      -- Send updated Block Kit when ADR is edited
      thread := coalesce(req.slack_message_ts, req.thread_ts);
      bk := build_adr_block_kit(req, event_type, NULL);
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format('*%s: %s* — updated', req.id, req.title)
      );
      IF bk IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('blocks', bk->'blocks');
      END IF;
      IF thread IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', thread);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    WHEN 'ADR_ACCEPTED', 'ADR_REJECTED', 'ADR_SUPERSEDED' THEN
      thread := coalesce(req.slack_message_ts, req.thread_ts);
      bk := build_adr_block_kit(req, event_type, NULL);
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format('*%s* status changed to *%s*', req.id, new_state)
      );
      IF bk IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('blocks', bk->'blocks');
      END IF;
      IF thread IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', thread);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    WHEN 'EXPORT_REQUESTED' THEN
      markdown := render_adr_markdown(req.id);
      PERFORM enqueue_outbox(req.id, NULL, 'git-export', jsonb_build_object(
        'adr_id', req.id,
        'title', req.title,
        'markdown', markdown
      ));

    WHEN 'EXPORT_COMPLETED' THEN
      IF req.git_pr_url IS NOT NULL THEN
        bk := build_adr_block_kit(req, event_type, NULL);
        slack_payload := jsonb_build_object(
          'channel', channel,
          'text', format('*%s* exported to Git: %s', req.id, req.git_pr_url)
        );
        IF bk IS NOT NULL THEN
          slack_payload := slack_payload || jsonb_build_object('blocks', bk->'blocks');
        END IF;
        IF req.slack_message_ts IS NOT NULL THEN
          slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
        END IF;
        PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);
      END IF;

    WHEN 'EXPORT_FAILED' THEN
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format(':x: *%s* export failed. Try again with the Export button.', req.id)
      );
      IF req.slack_message_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    ELSE
      NULL;
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
