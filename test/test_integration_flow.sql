-- test/test_integration_flow.sql
-- End-to-end flow tests: simulates the full user journey through SQL functions.
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_integration_flow.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';
SET LOCAL app.test_secret_SUPABASE_URL = 'http://localhost:54321';
SET LOCAL app.test_secret_SUPABASE_SERVICE_ROLE_KEY = 'test-service-key';

-- Test 1: /adr enable → /adr start (modal) → submit → /adr list → /adr view → accept → export
DO $$
DECLARE
  enable_result json;
  list_result json;
  view_result json;
  modal_result json;
  rec adrs;
  adr_id text;
  outbox_cnt int;
  blocks_text text;
BEGIN
  -- Step 1: Enable channel
  enable_result := handle_slack_webhook(
    'command=%2Fadr&text=enable&team_id=T_INT&channel_id=C_INT&user_id=U_ADMIN&trigger_id=trig1'
  );
  ASSERT enable_result->>'text' LIKE '%enabled%',
    format('Enable should confirm: %s', enable_result->>'text');
  RAISE NOTICE 'PASS: Step 1 - /adr enable works';

  -- Step 2: Simulate modal submission (create ADR)
  modal_result := handle_slack_modal_submission('{
    "type": "view_submission",
    "user": {"id": "U_ENGINEER"},
    "view": {
      "private_metadata": "C_INT|1234567890.001|",
      "state": {
        "values": {
          "title_block": {"title_input": {"value": "Use event sourcing for ADR state"}},
          "context_block": {"context_input": {"value": "We need a reliable state machine for ADR lifecycle"}},
          "decision_block": {"decision_input": {"value": "Append-only events with mutable projection"}},
          "alternatives_block": {"alternatives_input": {"value": "1. Direct mutations\n2. CQRS with separate read/write"}},
          "consequences_block": {"consequences_input": {"value": "Full audit trail, slightly more complex queries"}},
          "open_questions_block": {"open_questions_input": {"value": "Event compaction strategy?"}},
          "decision_drivers_block": {"decision_drivers_input": {"value": "Auditability, simplicity"}},
          "implementation_plan_block": {"implementation_plan_input": {"value": "1. Create events table\n2. Build reducer"}},
          "reviewers_block": {"reviewers_input": {"value": "Tech Lead, DBA"}}
        }
      }
    }
  }');
  ASSERT modal_result IS NULL, format('Modal should return NULL, got %s', modal_result);

  -- Find the created ADR
  SELECT * INTO rec FROM adrs
  WHERE title = 'Use event sourcing for ADR state' AND created_by = 'U_ENGINEER';
  ASSERT rec.id IS NOT NULL, 'ADR should exist';
  ASSERT rec.state = 'DRAFT', format('Should be DRAFT, got %s', rec.state);
  ASSERT rec.team_id = 'T_INT', format('team_id should come from channel_config, got %s', rec.team_id);
  adr_id := rec.id;
  RAISE NOTICE 'PASS: Step 2 - Modal submission creates ADR: %', adr_id;

  -- Step 2b: Edit ADR via modal submission
  modal_result := handle_slack_modal_submission(format('{
    "type": "view_submission",
    "user": {"id": "U_ENGINEER"},
    "view": {
      "private_metadata": "C_INT|1234567890.001|%s",
      "state": {
        "values": {
          "title_block": {"title_input": {"value": "Use event sourcing for ADR state (revised)"}},
          "context_block": {"context_input": {"value": "We need a reliable state machine for ADR lifecycle"}},
          "decision_block": {"decision_input": {"value": "Append-only events with mutable projection, optimistic concurrency"}},
          "alternatives_block": {"alternatives_input": {"value": "1. Direct mutations\n2. CQRS with separate read/write\n3. Saga pattern"}},
          "consequences_block": {"consequences_input": {"value": "Full audit trail, slightly more complex queries"}},
          "open_questions_block": {"open_questions_input": {"value": null}},
          "decision_drivers_block": {"decision_drivers_input": {"value": "Auditability, simplicity, concurrency"}},
          "implementation_plan_block": {"implementation_plan_input": {"value": "1. Create events table\n2. Build reducer\n3. Add outbox"}},
          "reviewers_block": {"reviewers_input": {"value": "Tech Lead, DBA, Platform Team"}}
        }
      }
    }
  }', adr_id));
  ASSERT modal_result IS NULL, format('Edit modal should return NULL, got %s', modal_result);

  SELECT * INTO rec FROM adrs WHERE id = adr_id;
  ASSERT rec.title = 'Use event sourcing for ADR state (revised)',
    format('Title should be updated, got %s', rec.title);
  ASSERT rec.decision LIKE '%optimistic concurrency%',
    format('Decision should be updated, got %s', rec.decision);
  ASSERT rec.reviewers LIKE '%Platform Team%',
    format('Reviewers should be updated, got %s', rec.reviewers);
  ASSERT rec.state = 'DRAFT', format('State should still be DRAFT after edit, got %s', rec.state);
  RAISE NOTICE 'PASS: Step 2b - Edit ADR via modal submission updates fields';

  -- Step 3: /adr list
  list_result := handle_slack_webhook(
    format('command=%%2Fadr&text=list&team_id=T_INT&channel_id=C_INT&user_id=U_ENGINEER&trigger_id=trig2')
  );
  ASSERT list_result->>'text' LIKE '%' || adr_id || '%',
    format('List should contain ADR ID: %s', list_result->>'text');
  RAISE NOTICE 'PASS: Step 3 - /adr list shows the ADR';

  -- Step 4: /adr view <id>
  view_result := handle_slack_webhook(
    format('command=%%2Fadr&text=view+%s&team_id=T_INT&channel_id=C_INT&user_id=U_ENGINEER&trigger_id=trig3', adr_id)
  );
  blocks_text := view_result::text;
  ASSERT blocks_text LIKE '%event sourcing%',
    format('View should contain title: %s', left(blocks_text, 200));
  ASSERT blocks_text LIKE '%revised%',
    format('View should show revised title: %s', left(blocks_text, 200));
  RAISE NOTICE 'PASS: Step 4 - /adr view shows Block Kit with updated title';

  -- Step 5: Accept the ADR (simulates interactive button press)
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := apply_adr_event(adr_id, 'ADR_ACCEPTED', 'user', 'U_LEAD');
  PERFORM set_config('app.suppress_outbox', 'false', true);
  ASSERT rec.state = 'ACCEPTED', format('Should be ACCEPTED, got %s', rec.state);
  RAISE NOTICE 'PASS: Step 5 - Accept transitions to ACCEPTED';

  -- Step 6: Export to Git
  rec := apply_adr_event(adr_id, 'EXPORT_REQUESTED', 'user', 'U_LEAD');
  -- Check git-export outbox row was created
  SELECT count(*) INTO outbox_cnt FROM adr_outbox ob
  WHERE ob.adr_id = rec.id AND ob.destination = 'git-export';
  ASSERT outbox_cnt >= 1, format('Should have git-export outbox row, got %s', outbox_cnt);
  RAISE NOTICE 'PASS: Step 6 - Export creates git-export outbox row';

  -- Step 7: Simulate git-export callback (PR created)
  DECLARE
    callback_result json;
  BEGIN
    callback_result := handle_git_export_callback(format(
      '{"adr_id": "%s", "status": "complete", "pr_url": "https://github.com/org/arch/pull/42", "branch": "adr/2026-02-26-use-event-sourcing"}',
      adr_id
    ));
    ASSERT callback_result->>'ok' = 'true', 'Callback should succeed';
    ASSERT callback_result->>'state' = 'ACCEPTED', format('State should be ACCEPTED, got %s', callback_result->>'state');
  END;

  SELECT * INTO rec FROM adrs WHERE id = adr_id;
  ASSERT rec.git_pr_url = 'https://github.com/org/arch/pull/42',
    format('PR URL should be set: %s', rec.git_pr_url);
  RAISE NOTICE 'PASS: Step 7 - Git export callback sets PR URL';

  -- Step 8: Verify markdown rendering
  DECLARE
    md text;
  BEGIN
    md := render_adr_markdown(adr_id);
    ASSERT md LIKE '%# Use event sourcing for ADR state (revised)%', 'Markdown should have revised title';
    ASSERT md LIKE '%## Decision%', 'Markdown should have Decision section';
    ASSERT md LIKE '%optimistic concurrency%', 'Markdown should have updated decision content';
    ASSERT md LIKE '%Platform Team%', 'Markdown should have updated reviewers';
    RAISE NOTICE 'PASS: Step 8 - Markdown rendering complete';
  END;

  -- Step 9: /adr disable
  DECLARE
    disable_result json;
    cfg_enabled boolean;
  BEGIN
    disable_result := handle_slack_webhook(
      'command=%2Fadr&text=disable&team_id=T_INT&channel_id=C_INT&user_id=U_ADMIN&trigger_id=trig4'
    );
    ASSERT disable_result->>'text' LIKE '%disabled%',
      format('Disable should confirm: %s', disable_result->>'text');

    SELECT enabled INTO cfg_enabled FROM channel_config
    WHERE team_id = 'T_INT' AND channel_id = 'C_INT';
    ASSERT cfg_enabled = false, 'Channel should be disabled';
    RAISE NOTICE 'PASS: Step 9 - /adr disable works';
  END;

  RAISE NOTICE '=== ALL INTEGRATION STEPS PASSED ===';
END;
$$;

-- Test 2: app_mention flow
DO $$
DECLARE
  result json;
  ob adr_outbox;
BEGIN
  -- Enable a channel for app_mention
  INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_INT2', 'C_MENTION', true);

  result := handle_slack_event('{
    "type": "event_callback",
    "team_id": "T_INT2",
    "event": {
      "type": "app_mention",
      "channel": "C_MENTION",
      "ts": "9999999999.001",
      "thread_ts": "9999999999.000",
      "user": "U_MENTION",
      "text": "<@ADR_BOT> we should formalize this decision"
    }
  }');

  ASSERT result->>'ok' = 'true', 'Should return ok';

  SELECT * INTO ob FROM adr_outbox
  WHERE destination = 'slack' AND payload->>'channel' = 'C_MENTION'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT ob.id IS NOT NULL, 'Should have outbox row';
  ASSERT ob.payload::text LIKE '%Start ADR%', 'Should contain Start ADR button';
  ASSERT ob.payload->>'thread_ts' = '9999999999.000', 'Should use thread_ts';
  RAISE NOTICE 'PASS: Test 2 - app_mention flow creates Start ADR prompt';
END;
$$;

-- Test 3: /adr help returns usage info
DO $$
DECLARE
  result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=help&team_id=T_INT3&channel_id=C_HELP&user_id=U_HELP&trigger_id=trig5'
  );
  ASSERT result->>'text' LIKE '%start%',
    format('Help should mention start: %s', result->>'text');
  ASSERT result->>'text' LIKE '%enable%',
    format('Help should mention enable: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 3 - /adr help shows usage';
END;
$$;

ROLLBACK;
