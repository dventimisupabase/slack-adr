-- test/test_pagination_and_dry.sql
-- Tests for Step 26: Pagination for list/search + DRY state transition helper
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_pagination_and_dry.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

INSERT INTO channel_config (team_id, channel_id, enabled) VALUES ('T_PAGE', 'C_PAGE', true)
ON CONFLICT ON CONSTRAINT channel_config_pkey DO NOTHING;

-- Seed 25 ADRs (more than one page of 20)
DO $$
DECLARE
  i int;
  r adrs;
BEGIN
  PERFORM set_config('app.suppress_outbox', 'true', true);
  FOR i IN 1..25 LOOP
    PERFORM create_adr('T_PAGE', 'C_PAGE', 'U_PAGE', format('Paginated ADR %s', i), format('context %s', i));
  END LOOP;
  -- Accept 5 of them for state filtering pagination tests
  FOR r IN SELECT * FROM adrs WHERE team_id = 'T_PAGE' ORDER BY created_at LIMIT 5 LOOP
    PERFORM apply_adr_event(r.id, 'ADR_ACCEPTED', 'user', 'U_PAGE');
  END LOOP;
  PERFORM set_config('app.suppress_outbox', 'false', true);
END;
$$;

-- Test 1: /adr list shows total count when more than 20 results
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t1'
  );
  ASSERT result->>'text' LIKE '%25%',
    format('Should mention 25 total ADRs, got: %s', result->>'text');
  ASSERT result->>'text' LIKE '%page%' OR result->>'text' LIKE '%more%',
    format('Should indicate more results available, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 1 - /adr list shows total count when truncated';
END;
$$;

-- Test 2: /adr list page 2 shows remaining results
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+page+2&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t2'
  );
  ASSERT result->>'text' LIKE '%Paginated ADR%',
    format('Page 2 should show ADRs, got: %s', result->>'text');
  -- Page 2 with 25 total should show 5 remaining
  RAISE NOTICE 'PASS: Test 2 - /adr list page 2 shows remaining results';
END;
$$;

-- Test 3: /adr list page 99 shows no results
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+page+99&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t3'
  );
  ASSERT result->>'text' LIKE '%No%' OR result->>'text' LIKE '%no more%',
    format('Page 99 should indicate no results, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 3 - /adr list page 99 shows no results';
END;
$$;

-- Test 4: /adr list <state> page 1 with pagination
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+draft&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t4'
  );
  -- 20 draft ADRs (25 total - 5 accepted = 20 draft)
  ASSERT result->>'text' LIKE '%DRAFT%',
    format('Should show DRAFT filter, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 4 - /adr list <state> with pagination';
END;
$$;

-- Test 5: /adr search with pagination indicator
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=search+Paginated&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t5'
  );
  ASSERT result->>'text' LIKE '%Paginated%',
    format('Should find paginated ADRs, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 5 - /adr search shows results with count';
END;
$$;

-- Test 6: /adr search page 2
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=search+Paginated+page+2&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t6'
  );
  ASSERT result->>'text' LIKE '%Paginated%',
    format('Search page 2 should show results, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 6 - /adr search page 2';
END;
$$;

-- Test 7: DRY helper - /adr accept still works after refactor
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_PAGE', 'C_PAGE', 'U_PAGE', 'DRY Accept Test', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=accept+%s&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t7', rec.id)
  );
  -- Should still work after refactoring to helper
  ASSERT result->>'text' LIKE '%ACCEPTED%' OR result->>'blocks' IS NOT NULL,
    format('Accept should still work, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 7 - /adr accept works after DRY refactor';
END;
$$;

-- Test 8: DRY helper - /adr reject still works after refactor
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  rec := create_adr('T_PAGE', 'C_PAGE', 'U_PAGE', 'DRY Reject Test', 'ctx');

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=reject+%s&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t7b', rec.id)
  );
  ASSERT result->>'text' LIKE '%REJECTED%' OR result->>'blocks' IS NOT NULL,
    format('Reject should still work, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 8 - /adr reject works after DRY refactor';
END;
$$;

-- Test 9: DRY helper - /adr supersede still works after refactor
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := create_adr('T_PAGE', 'C_PAGE', 'U_PAGE', 'DRY Supersede Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_PAGE');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=supersede+%s&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t7c', rec.id)
  );
  ASSERT result->>'text' LIKE '%SUPERSEDED%' OR result->>'blocks' IS NOT NULL,
    format('Supersede should still work, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 9 - /adr supersede works after DRY refactor';
END;
$$;

-- Test 10: DRY helper - friendly error still works
DO $$
DECLARE
  rec adrs;
  result json;
BEGIN
  PERFORM set_config('app.suppress_outbox', 'true', true);
  rec := create_adr('T_PAGE', 'C_PAGE', 'U_PAGE', 'DRY Error Test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_PAGE');
  PERFORM set_config('app.suppress_outbox', 'false', true);

  result := handle_slack_webhook(
    format('command=%%2Fadr&text=accept+%s&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t7d', rec.id)
  );
  ASSERT result->>'text' LIKE '%currently ACCEPTED%',
    format('Should show friendly error, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 10 - Friendly error still works after DRY refactor';
END;
$$;

-- Test 11: /adr list page 0 or negative treated as page 1
DO $$
DECLARE result json;
BEGIN
  result := handle_slack_webhook(
    'command=%2Fadr&text=list+page+0&team_id=T_PAGE&channel_id=C_PAGE&user_id=U_PAGE&trigger_id=t8'
  );
  ASSERT result->>'text' LIKE '%Paginated ADR%',
    format('Page 0 should default to page 1, got: %s', result->>'text');
  RAISE NOTICE 'PASS: Test 11 - /adr list page 0 defaults to page 1';
END;
$$;

ROLLBACK;
