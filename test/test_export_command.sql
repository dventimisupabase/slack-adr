-- test/test_export_command.sql
-- Tests for Step 30: /adr export <id> slash command
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_export_command.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_EXP', 'C_EXP', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: /adr export with missing ID shows usage
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=export&team_id=T_EXP&channel_id=C_EXP&user_id=U_EXP&trigger_id=t1'
  );
  ASSERT result->>'text' LIKE '%Usage%' OR result->>'text' LIKE '%export%',
    format('Should show usage, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 1 - /adr export with missing ID shows usage';
END;
$$;

-- Test 2: /adr export on draft ADR creates git-export outbox row
DO $$
DECLARE
  rec adrs;
  result json;
  outbox_count int;
BEGIN
  rec := create_adr('T_EXP', 'C_EXP', 'U_EXP', 'Export Draft Test', 'context for export');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=export+%s&team_id=T_EXP&channel_id=C_EXP&user_id=U_EXP&trigger_id=t2', rec.id)
  );

  ASSERT result->>'text' LIKE '%export%' OR result->>'text' LIKE '%Export%',
    format('Should confirm export, got: %s', result->>'text');

  SELECT count(*) INTO outbox_count FROM adr_outbox
  WHERE adr_id = rec.id AND destination = 'git-export';
  ASSERT outbox_count >= 1,
    format('Should create git-export outbox row, got: %s', outbox_count);

  RAISE NOTICE 'PASS: Test 2 - /adr export creates git-export outbox row';
END;
$$;

-- Test 3: /adr export on accepted ADR works
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := create_adr('T_EXP', 'C_EXP', 'U_EXP', 'Export Accepted Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_EXP');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=export+%s&team_id=T_EXP&channel_id=C_EXP&user_id=U_EXP&trigger_id=t3', rec.id)
  );

  ASSERT result->>'text' LIKE '%export%' OR result->>'text' LIKE '%Export%',
    format('Should confirm export of accepted ADR, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 3 - /adr export on accepted ADR works';
END;
$$;

-- Test 4: /adr export rejects cross-team ADR
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_EXP', 'C_EXP', 'U_EXP', 'Cross Team Export', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=export+%s&team_id=T_OTHER_EXP&channel_id=C_OTHER&user_id=U_OTHER&trigger_id=t4', rec.id)
  );

  ASSERT result->>'text' LIKE '%not found%',
    format('Should reject cross-team export, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 4 - /adr export rejects cross-team ADR';
END;
$$;

-- Test 5: /adr export on rejected ADR shows friendly error
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := create_adr('T_EXP', 'C_EXP', 'U_EXP', 'Export Rejected Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_EXP');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=export+%s&team_id=T_EXP&channel_id=C_EXP&user_id=U_EXP&trigger_id=t5', rec.id)
  );

  ASSERT result->>'text' LIKE '%currently REJECTED%' OR result->>'text' LIKE '%cannot%export%',
    format('Should show friendly error for rejected, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 5 - /adr export on rejected ADR shows friendly error';
END;
$$;

-- Test 6: Help text includes export command
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_EXP&channel_id=C_EXP&user_id=U_EXP&trigger_id=t6'
  );
  ASSERT result->>'text' LIKE '%export%',
    format('Help should mention export, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 6 - Help text includes export command';
END;
$$;

ROLLBACK;
