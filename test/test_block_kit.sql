-- test/test_block_kit.sql
-- Tests for Step 7: Block Kit message builder
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_block_kit.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Test 1: DRAFT state has Edit, Accept, Reject, Export buttons
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  actions jsonb;
  action_ids text[];
BEGIN
  rec := create_adr('T_BK', 'C_BK', 'U_BK', 'Block Kit Test', 'Some context', 'Use Postgres');
  bk := build_adr_block_kit(rec);
  ASSERT bk IS NOT NULL, 'Block kit should not be null';
  ASSERT bk ? 'blocks', 'Should have blocks key';

  -- Find the actions block
  SELECT elem INTO actions FROM jsonb_array_elements(bk->'blocks') elem
  WHERE elem->>'type' = 'actions' LIMIT 1;
  ASSERT actions IS NOT NULL, 'Should have an actions block';

  -- Collect action_ids
  SELECT array_agg(el->>'action_id') INTO action_ids
  FROM jsonb_array_elements(actions->'elements') el;

  ASSERT 'edit_adr' = ANY(action_ids), format('Missing edit_adr: %s', action_ids);
  ASSERT 'accept_adr' = ANY(action_ids), format('Missing accept_adr: %s', action_ids);
  ASSERT 'reject_adr' = ANY(action_ids), format('Missing reject_adr: %s', action_ids);
  ASSERT 'export_adr' = ANY(action_ids), format('Missing export_adr: %s', action_ids);
  RAISE NOTICE 'PASS: Test 1 - DRAFT state has Edit, Accept, Reject, Export buttons';
END;
$$;

-- Test 2: ACCEPTED state has Edit, Supersede, Export (no Accept/Reject)
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  actions jsonb;
  action_ids text[];
BEGIN
  rec := create_adr('T_BK2', 'C_BK2', 'U_BK2', 'Accepted BK Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_REV');
  bk := build_adr_block_kit(rec);

  SELECT elem INTO actions FROM jsonb_array_elements(bk->'blocks') elem
  WHERE elem->>'type' = 'actions' LIMIT 1;
  ASSERT actions IS NOT NULL, 'Should have actions block';

  SELECT array_agg(el->>'action_id') INTO action_ids
  FROM jsonb_array_elements(actions->'elements') el;

  ASSERT 'edit_adr' = ANY(action_ids), 'Should have edit';
  ASSERT 'supersede_adr' = ANY(action_ids), 'Should have supersede';
  ASSERT 'export_adr' = ANY(action_ids), 'Should have export (no PR yet)';
  ASSERT NOT ('accept_adr' = ANY(action_ids)), 'Should NOT have accept';
  ASSERT NOT ('reject_adr' = ANY(action_ids)), 'Should NOT have reject';
  RAISE NOTICE 'PASS: Test 2 - ACCEPTED state has Edit, Supersede, Export buttons';
END;
$$;

-- Test 3: REJECTED state has no action buttons
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  actions jsonb;
BEGIN
  rec := create_adr('T_BK3', 'C_BK3', 'U_BK3', 'Rejected BK Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_REV');
  bk := build_adr_block_kit(rec);

  SELECT elem INTO actions FROM jsonb_array_elements(bk->'blocks') elem
  WHERE elem->>'type' = 'actions' LIMIT 1;
  ASSERT actions IS NULL, 'REJECTED should have no actions block';
  RAISE NOTICE 'PASS: Test 3 - REJECTED state has no action buttons';
END;
$$;

-- Test 4: PR link appears when git_pr_url is set
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  pr_block jsonb;
BEGIN
  rec := create_adr('T_BK4', 'C_BK4', 'U_BK4', 'PR Link Test', 'ctx');
  rec := apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_BK4');
  rec := apply_adr_event(rec.id, 'EXPORT_COMPLETED', 'system', 'git-export',
    '{"pr_url": "https://github.com/org/repo/pull/42", "branch": "adr/test"}'::jsonb);

  bk := build_adr_block_kit(rec);

  SELECT elem INTO pr_block FROM jsonb_array_elements(bk->'blocks') elem
  WHERE elem->'text'->>'text' LIKE '%Pull Request%' LIMIT 1;
  ASSERT pr_block IS NOT NULL, 'Should have PR link block';
  ASSERT pr_block->'text'->>'text' LIKE '%github.com%',
    format('PR link should contain URL: %s', pr_block->'text'->>'text');
  RAISE NOTICE 'PASS: Test 4 - PR link appears when git_pr_url is set';
END;
$$;

-- Test 5: Context and Decision sections appear when populated
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  has_context boolean := false;
  has_decision boolean := false;
  elem jsonb;
BEGIN
  rec := create_adr('T_BK5', 'C_BK5', 'U_BK5', 'Sections Test', 'Important context here', 'We decided this');
  bk := build_adr_block_kit(rec);

  FOR elem IN SELECT * FROM jsonb_array_elements(bk->'blocks')
  LOOP
    IF elem->'text'->>'text' LIKE '%Context:%' THEN has_context := true; END IF;
    IF elem->'text'->>'text' LIKE '%Decision:%' THEN has_decision := true; END IF;
  END LOOP;

  ASSERT has_context, 'Should have context section';
  ASSERT has_decision, 'Should have decision section';
  RAISE NOTICE 'PASS: Test 5 - Context and Decision sections appear when populated';
END;
$$;

-- Test 6: Actor context line appears when event_type provided
DO $$
DECLARE
  rec adrs;
  bk jsonb;
  ctx_block jsonb;
BEGIN
  rec := create_adr('T_BK6', 'C_BK6', 'U_BK6', 'Actor Test', 'ctx');
  bk := build_adr_block_kit(rec, 'ADR_CREATED'::adr_event_type, 'U_BK6');

  SELECT elem INTO ctx_block FROM jsonb_array_elements(bk->'blocks') elem
  WHERE elem->>'type' = 'context' LIMIT 1;
  ASSERT ctx_block IS NOT NULL, 'Should have context line with actor';
  RAISE NOTICE 'PASS: Test 6 - Actor context line appears when event_type provided';
END;
$$;

ROLLBACK;
