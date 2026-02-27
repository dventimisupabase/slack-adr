-- test/test_modal_submission.sql
-- Tests for Step 10: Modal submission handler
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_modal_submission.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Seed a channel_config so create_adr can look up team_id
INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_MODAL', 'C_MODAL', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Test 1: Create flow - new ADR from modal submission
DO $$
DECLARE
  result json;
  rec adrs;
  payload text;
BEGIN
  payload := '{
    "type": "view_submission",
    "user": {"id": "U_MODAL1"},
    "view": {
      "private_metadata": "C_MODAL|1234567890.123456|",
      "state": {
        "values": {
          "title_block": {"title_input": {"value": "Use Redis for caching"}},
          "context_block": {"context_input": {"value": "We need a fast cache layer"}},
          "decision_block": {"decision_input": {"value": "Use Redis 7"}},
          "alternatives_block": {"alternatives_input": {"value": "Memcached"}},
          "consequences_block": {"consequences_input": {"value": "Must manage Redis cluster"}},
          "open_questions_block": {"open_questions_input": {"value": "Cloud vs self-hosted?"}},
          "decision_drivers_block": {"decision_drivers_input": {"value": "Performance, simplicity"}},
          "implementation_plan_block": {"implementation_plan_input": {"value": "1. Provision\n2. Configure"}},
          "reviewers_block": {"reviewers_input": {"value": "Tech Lead"}}
        }
      }
    }
  }';

  result := handle_slack_modal_submission(payload);
  -- Should return NULL to close modal
  ASSERT result IS NULL, format('Should return NULL, got %s', result);

  -- Verify ADR was created
  SELECT * INTO rec FROM adrs
  WHERE title = 'Use Redis for caching' AND created_by = 'U_MODAL1';

  ASSERT rec.id IS NOT NULL, 'ADR should be created';
  ASSERT rec.state = 'DRAFT', format('State should be DRAFT, got %s', rec.state);
  ASSERT rec.channel_id = 'C_MODAL', format('Channel should be C_MODAL, got %s', rec.channel_id);
  ASSERT rec.thread_ts = '1234567890.123456', format('thread_ts should be set, got %s', rec.thread_ts);
  ASSERT rec.decision = 'Use Redis 7', format('Decision should be set, got %s', rec.decision);
  ASSERT rec.team_id = 'T_MODAL', format('team_id should come from channel_config, got %s', rec.team_id);
  RAISE NOTICE 'PASS: Test 1 - Create flow creates new ADR from modal submission';
END;
$$;

-- Test 2: Edit flow - update existing ADR from modal submission
DO $$
DECLARE
  result json;
  orig adrs;
  updated adrs;
  payload text;
BEGIN
  orig := create_adr('T_MODAL', 'C_MODAL', 'U_MODAL2', 'Original Title', 'Original context');

  payload := format('{
    "type": "view_submission",
    "user": {"id": "U_MODAL2"},
    "view": {
      "private_metadata": "C_MODAL|1234567890.999|%s",
      "state": {
        "values": {
          "title_block": {"title_input": {"value": "Updated Title"}},
          "context_block": {"context_input": {"value": "Updated context"}},
          "decision_block": {"decision_input": {"value": "New decision"}},
          "alternatives_block": {"alternatives_input": {"value": null}},
          "consequences_block": {"consequences_input": {"value": null}},
          "open_questions_block": {"open_questions_input": {"value": null}},
          "decision_drivers_block": {"decision_drivers_input": {"value": null}},
          "implementation_plan_block": {"implementation_plan_input": {"value": null}},
          "reviewers_block": {"reviewers_input": {"value": null}}
        }
      }
    }
  }', orig.id);

  result := handle_slack_modal_submission(payload);
  ASSERT result IS NULL, format('Should return NULL, got %s', result);

  SELECT * INTO updated FROM adrs WHERE id = orig.id;
  ASSERT updated.title = 'Updated Title', format('Title should be updated, got %s', updated.title);
  ASSERT updated.context_text = 'Updated context', format('Context should be updated, got %s', updated.context_text);
  ASSERT updated.decision = 'New decision', format('Decision should be updated, got %s', updated.decision);
  RAISE NOTICE 'PASS: Test 2 - Edit flow updates existing ADR';
END;
$$;

-- Test 3: Validation - missing title returns error
DO $$
DECLARE
  result json;
  payload text;
BEGIN
  payload := '{
    "type": "view_submission",
    "user": {"id": "U_MODAL3"},
    "view": {
      "private_metadata": "C_MODAL||",
      "state": {
        "values": {
          "title_block": {"title_input": {"value": null}},
          "context_block": {"context_input": {"value": "Has context"}},
          "decision_block": {"decision_input": {"value": null}},
          "alternatives_block": {"alternatives_input": {"value": null}},
          "consequences_block": {"consequences_input": {"value": null}},
          "open_questions_block": {"open_questions_input": {"value": null}},
          "decision_drivers_block": {"decision_drivers_input": {"value": null}},
          "implementation_plan_block": {"implementation_plan_input": {"value": null}},
          "reviewers_block": {"reviewers_input": {"value": null}}
        }
      }
    }
  }';

  result := handle_slack_modal_submission(payload);
  ASSERT result IS NOT NULL, 'Should return validation error';
  ASSERT result->>'response_action' = 'errors', format('Should have response_action=errors, got %s', result->>'response_action');
  ASSERT result->'errors'->>'title_block' IS NOT NULL, 'Should have title_block error';
  RAISE NOTICE 'PASS: Test 3 - Validation returns error for missing title';
END;
$$;

-- Test 4: Validation - missing context returns error
DO $$
DECLARE
  result json;
  payload text;
BEGIN
  payload := '{
    "type": "view_submission",
    "user": {"id": "U_MODAL4"},
    "view": {
      "private_metadata": "C_MODAL||",
      "state": {
        "values": {
          "title_block": {"title_input": {"value": "Has title"}},
          "context_block": {"context_input": {"value": ""}},
          "decision_block": {"decision_input": {"value": null}},
          "alternatives_block": {"alternatives_input": {"value": null}},
          "consequences_block": {"consequences_input": {"value": null}},
          "open_questions_block": {"open_questions_input": {"value": null}},
          "decision_drivers_block": {"decision_drivers_input": {"value": null}},
          "implementation_plan_block": {"implementation_plan_input": {"value": null}},
          "reviewers_block": {"reviewers_input": {"value": null}}
        }
      }
    }
  }';

  result := handle_slack_modal_submission(payload);
  ASSERT result IS NOT NULL, 'Should return validation error';
  ASSERT result->>'response_action' = 'errors', format('Should have response_action=errors, got %s', result->>'response_action');
  ASSERT result->'errors'->>'context_block' IS NOT NULL, 'Should have context_block error';
  RAISE NOTICE 'PASS: Test 4 - Validation returns error for missing context';
END;
$$;

-- Test 5: Validation - both missing returns both errors
DO $$
DECLARE
  result json;
  payload text;
BEGIN
  payload := '{
    "type": "view_submission",
    "user": {"id": "U_MODAL5"},
    "view": {
      "private_metadata": "C_MODAL||",
      "state": {
        "values": {
          "title_block": {"title_input": {"value": ""}},
          "context_block": {"context_input": {"value": ""}},
          "decision_block": {"decision_input": {"value": null}},
          "alternatives_block": {"alternatives_input": {"value": null}},
          "consequences_block": {"consequences_input": {"value": null}},
          "open_questions_block": {"open_questions_input": {"value": null}},
          "decision_drivers_block": {"decision_drivers_input": {"value": null}},
          "implementation_plan_block": {"implementation_plan_input": {"value": null}},
          "reviewers_block": {"reviewers_input": {"value": null}}
        }
      }
    }
  }';

  result := handle_slack_modal_submission(payload);
  ASSERT result->'errors'->>'title_block' IS NOT NULL, 'Should have title_block error';
  ASSERT result->'errors'->>'context_block' IS NOT NULL, 'Should have context_block error';
  RAISE NOTICE 'PASS: Test 5 - Validation returns both errors when both missing';
END;
$$;

ROLLBACK;
