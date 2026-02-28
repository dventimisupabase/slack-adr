-- test/test_markdown_reason.sql
-- Tests for Step 40: Markdown export includes decision history with reasons
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_markdown_reason.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test-token';

-- Test 1: render_adr_markdown includes reason from accept event
DO $$
DECLARE
  rec adrs;
  md text;
BEGIN
  rec := create_adr('T_MR1', 'C_MR1', 'U_MR1', 'Accepted With Reason', 'Some context');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_REVIEWER',
    jsonb_build_object('reason', 'Aligns with company strategy'));

  md := render_adr_markdown(rec.id);
  ASSERT md LIKE '%Decision Notes%',
    format('Markdown should have Decision Notes section, got: %s', left(md, 500));
  ASSERT md LIKE '%Aligns with company strategy%',
    format('Markdown should include reason, got: %s', left(md, 500));
  RAISE NOTICE 'PASS: Test 1 - Markdown includes accept reason';
END;
$$;

-- Test 2: render_adr_markdown includes reason from reject event
DO $$
DECLARE
  rec adrs;
  md text;
BEGIN
  rec := create_adr('T_MR2', 'C_MR2', 'U_MR2', 'Rejected With Reason', 'Some context');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_REVIEWER',
    jsonb_build_object('reason', 'Too expensive'));

  md := render_adr_markdown(rec.id);
  ASSERT md LIKE '%Too expensive%',
    format('Markdown should include reject reason, got: %s', left(md, 500));
  RAISE NOTICE 'PASS: Test 2 - Markdown includes reject reason';
END;
$$;

-- Test 3: render_adr_markdown without reason still works
DO $$
DECLARE
  rec adrs;
  md text;
BEGIN
  rec := create_adr('T_MR3', 'C_MR3', 'U_MR3', 'No Reason ADR', 'ctx');
  md := render_adr_markdown(rec.id);
  ASSERT md IS NOT NULL AND md != '',
    'Markdown should render without reason';
  ASSERT md LIKE '%No Reason ADR%',
    format('Markdown should have title, got: %s', left(md, 200));
  RAISE NOTICE 'PASS: Test 3 - Markdown renders without reason';
END;
$$;

-- Test 4: render_adr_markdown shows multiple decision notes
DO $$
DECLARE
  rec adrs;
  md text;
BEGIN
  rec := create_adr('T_MR4', 'C_MR4', 'U_MR4', 'Multi Event ADR', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_A',
    jsonb_build_object('reason', 'Team agreed'));
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_B',
    jsonb_build_object('reason', 'Better approach found'));

  md := render_adr_markdown(rec.id);
  ASSERT md LIKE '%Team agreed%',
    format('Should include accept reason, got: %s', md);
  ASSERT md LIKE '%Better approach found%',
    format('Should include supersede reason, got: %s', md);
  RAISE NOTICE 'PASS: Test 4 - Markdown shows multiple decision notes';
END;
$$;

ROLLBACK;
