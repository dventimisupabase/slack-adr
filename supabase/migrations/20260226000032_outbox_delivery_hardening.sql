-- Step 32: Harden outbox delivery checking
-- Fix: non-JSON and empty Slack responses were incorrectly treated as successful
-- deliveries because the EXCEPTION handler swallowed parse errors silently.

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
        -- Validate Slack response: must be valid JSON with "ok": true
        IF resp_body IS NULL OR trim(resp_body) = '' THEN
          is_success := false;
          UPDATE adr_outbox SET
            pg_net_request_id = NULL,
            last_error = 'Slack response body is empty'
          WHERE id = row.id;
        ELSE
          BEGIN
            body_json := resp_body::jsonb;
            IF body_json->>'ok' = 'false' THEN
              is_success := false;
              UPDATE adr_outbox SET
                pg_net_request_id = NULL,
                last_error = format('Slack API error: %s', coalesce(body_json->>'error', 'unknown'))
              WHERE id = row.id;
            ELSIF body_json->>'ok' IS NULL THEN
              -- Response is JSON but doesn't have "ok" field — suspicious
              is_success := false;
              UPDATE adr_outbox SET
                pg_net_request_id = NULL,
                last_error = format('Slack response missing ok field: %s', left(resp_body, 200))
              WHERE id = row.id;
            END IF;
          EXCEPTION WHEN OTHERS THEN
            -- JSON parse failed — not a valid Slack response
            is_success := false;
            UPDATE adr_outbox SET
              pg_net_request_id = NULL,
              last_error = format('Slack response not valid JSON: %s', left(resp_body, 200))
            WHERE id = row.id;
          END;
        END IF;
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
