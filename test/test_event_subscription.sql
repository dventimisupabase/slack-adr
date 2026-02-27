-- test/test_event_subscription.sql
-- Tests for Step 12: Event subscription (app_mention)
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_event_subscription.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Test 1: url_verification challenge returns correct response
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_event('{"type": "url_verification", "challenge": "abc123xyz"}');
  ASSERT result->>'challenge' = 'abc123xyz',
    format('Should return challenge, got %s', result->>'challenge');
  RAISE NOTICE 'PASS: Test 1 - url_verification returns challenge';
END;
$$;

-- Test 2: app_mention in enabled channel creates outbox row
DO $$
DECLARE
  result json;
  cnt int;
  ob adr_outbox;
  evt_payload text;
BEGIN
  -- Enable channel
  INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_EVT', 'C_EVT_ON', true);

  evt_payload := '{
    "type": "event_callback",
    "team_id": "T_EVT",
    "event": {
      "type": "app_mention",
      "channel": "C_EVT_ON",
      "ts": "1234567890.111",
      "user": "U_EVT1",
      "text": "<@BOTID> start an ADR"
    }
  }';

  result := handle_slack_event(evt_payload);
  ASSERT result->>'ok' = 'true', format('Should return ok, got %s', result);

  SELECT count(*) INTO cnt FROM adr_outbox
  WHERE destination = 'slack'
    AND payload->>'channel' = 'C_EVT_ON';

  ASSERT cnt >= 1, format('Should have outbox row for C_EVT_ON, got %s', cnt);

  SELECT * INTO ob FROM adr_outbox
  WHERE destination = 'slack'
    AND payload->>'channel' = 'C_EVT_ON'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT ob.payload::text LIKE '%Start ADR%',
    format('Should have Start ADR button, got %s', ob.payload::text);
  RAISE NOTICE 'PASS: Test 2 - app_mention in enabled channel creates outbox row';
END;
$$;

-- Test 3: app_mention in disabled channel is ignored
DO $$
DECLARE
  result json;
  cnt_before int;
  cnt_after int;
  evt_payload text;
BEGIN
  -- Disabled channel
  INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_EVT', 'C_EVT_OFF', false);

  SELECT count(*) INTO cnt_before FROM adr_outbox;

  evt_payload := '{
    "type": "event_callback",
    "team_id": "T_EVT",
    "event": {
      "type": "app_mention",
      "channel": "C_EVT_OFF",
      "ts": "1234567890.222",
      "user": "U_EVT2",
      "text": "<@BOTID> adr"
    }
  }';

  result := handle_slack_event(evt_payload);
  ASSERT result->>'ok' = 'true', 'Should return ok';

  SELECT count(*) INTO cnt_after FROM adr_outbox;
  ASSERT cnt_after = cnt_before,
    format('Should not add outbox rows for disabled channel, before=%s after=%s', cnt_before, cnt_after);
  RAISE NOTICE 'PASS: Test 3 - app_mention in disabled channel is ignored';
END;
$$;

-- Test 4: app_mention in unknown channel (no config) is ignored
DO $$
DECLARE
  result json;
  cnt_before int;
  cnt_after int;
  evt_payload text;
BEGIN
  SELECT count(*) INTO cnt_before FROM adr_outbox;

  evt_payload := '{
    "type": "event_callback",
    "team_id": "T_EVT",
    "event": {
      "type": "app_mention",
      "channel": "C_UNKNOWN",
      "ts": "1234567890.333",
      "user": "U_EVT3",
      "text": "<@BOTID> adr"
    }
  }';

  result := handle_slack_event(evt_payload);
  ASSERT result->>'ok' = 'true', 'Should return ok';

  SELECT count(*) INTO cnt_after FROM adr_outbox;
  ASSERT cnt_after = cnt_before,
    format('Should not add outbox rows for unknown channel, before=%s after=%s', cnt_before, cnt_after);
  RAISE NOTICE 'PASS: Test 4 - app_mention in unknown channel is ignored';
END;
$$;

-- Test 5: Non-event_callback type returns ok
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_event('{"type": "app_rate_limited"}');
  ASSERT result->>'ok' = 'true', 'Should return ok for non-event_callback';
  RAISE NOTICE 'PASS: Test 5 - Non-event_callback type returns ok';
END;
$$;

-- Test 6: app_mention uses thread_ts when in a thread
DO $$
DECLARE
  result json;
  ob adr_outbox;
  evt_payload text;
BEGIN
  -- Ensure enabled channel exists
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_EVT', 'C_EVT_THR', true)
  ON CONFLICT DO NOTHING;

  evt_payload := '{
    "type": "event_callback",
    "team_id": "T_EVT",
    "event": {
      "type": "app_mention",
      "channel": "C_EVT_THR",
      "ts": "1234567890.444",
      "thread_ts": "1234567890.000",
      "user": "U_EVT4",
      "text": "<@BOTID> start ADR"
    }
  }';

  result := handle_slack_event(evt_payload);

  SELECT * INTO ob FROM adr_outbox
  WHERE destination = 'slack'
    AND payload->>'channel' = 'C_EVT_THR'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT ob.payload->>'thread_ts' = '1234567890.000',
    format('Should use thread_ts, got %s', ob.payload->>'thread_ts');
  RAISE NOTICE 'PASS: Test 6 - app_mention uses thread_ts when in a thread';
END;
$$;

-- Test 7: app_mention with wrong team_id is ignored (multi-workspace safety)
DO $$
DECLARE
  result json;
  cnt_before int;
  cnt_after int;
  evt_payload text;
BEGIN
  -- Channel C_EVT_ON is enabled for T_EVT (from Test 2)
  SELECT count(*) INTO cnt_before FROM adr_outbox;

  evt_payload := '{
    "type": "event_callback",
    "team_id": "T_WRONG_TEAM",
    "event": {
      "type": "app_mention",
      "channel": "C_EVT_ON",
      "ts": "1234567890.555",
      "user": "U_EVT5",
      "text": "<@BOTID> adr"
    }
  }';

  result := handle_slack_event(evt_payload);
  ASSERT result->>'ok' = 'true', 'Should return ok';

  SELECT count(*) INTO cnt_after FROM adr_outbox;
  ASSERT cnt_after = cnt_before,
    format('Should not add outbox rows for wrong team, before=%s after=%s', cnt_before, cnt_after);
  RAISE NOTICE 'PASS: Test 7 - app_mention with wrong team_id is ignored';
END;
$$;

ROLLBACK;
