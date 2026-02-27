-- Step 8: Thread TS Capture
-- Cron job polls pg_net HTTP responses to extract Slack's message ts.

CREATE FUNCTION capture_thread_timestamps() RETURNS void AS $$
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
      -- Only capture for initial messages (no thread_ts in payload = top-level message)
      AND NOT (ob.payload ? 'thread_ts')
    ORDER BY ob.created_at
    LIMIT 20
  LOOP
    BEGIN
      SELECT (body::jsonb) INTO response_body
      FROM net._http_response
      WHERE id = row.pg_net_request_id;

      IF response_body IS NOT NULL AND response_body->>'ok' = 'true' THEN
        ts_value := response_body->>'ts';
        IF ts_value IS NOT NULL THEN
          UPDATE adrs SET slack_message_ts = ts_value
          WHERE id = row.adr_id AND slack_message_ts IS NULL;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Ignore errors reading pg_net responses
      NULL;
    END;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Schedule every 30 seconds
SELECT cron.schedule(
  'capture-thread-ts',
  '30 seconds',
  $$SELECT capture_thread_timestamps()$$
);
