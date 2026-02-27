-- test/test_git_export.sql
-- Tests for Step 13: Markdown renderer, git export callback
-- Run: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f test/test_git_export.sql

BEGIN;

SET LOCAL app.test_secret_SLACK_SIGNING_SECRET = 'test';
SET LOCAL app.test_secret_SLACK_BOT_TOKEN = 'xoxb-test';

-- Test 1: render_adr_markdown produces valid markdown
DO $$
DECLARE
  rec adrs;
  md text;
BEGIN
  rec := create_adr(
    'T_GE', 'C_GE', 'U_GE', 'Use Postgres for everything',
    'We need a database that handles our workload',
    'Use PostgreSQL 17',
    '1. MySQL - rejected for lack of CTEs\n2. MongoDB - rejected for consistency',
    'Positive: Rich SQL support\nNegative: Must manage ourselves',
    'Which cloud provider?',
    'Simplicity, cost',
    '1. Provision instance\n2. Run migrations',
    'Tech Lead, DBA'
  );
  md := render_adr_markdown(rec.id);
  ASSERT md LIKE '%# Use Postgres for everything%', 'Should have title';
  ASSERT md LIKE '%## Context%', 'Should have Context section';
  ASSERT md LIKE '%## Decision%', 'Should have Decision section';
  ASSERT md LIKE '%## Alternatives Considered%', 'Should have Alternatives section';
  ASSERT md LIKE '%## Consequences%', 'Should have Consequences section';
  ASSERT md LIKE '%## Reviewers%', 'Should have Reviewers section';
  ASSERT md LIKE '%Tech Lead%', 'Should contain reviewer names';
  RAISE NOTICE 'PASS: Test 1 - render_adr_markdown produces valid markdown';
END;
$$;

-- Test 2: render_adr_markdown handles NULL fields gracefully
DO $$
DECLARE
  rec adrs;
  md text;
BEGIN
  rec := create_adr('T_GE2', 'C_GE2', 'U_GE2', 'Minimal ADR', 'Just context');
  md := render_adr_markdown(rec.id);
  ASSERT md LIKE '%# Minimal ADR%', 'Should have title';
  ASSERT md LIKE '%_(none)_%', 'Should have placeholder for empty fields';
  ASSERT md NOT LIKE '%ERROR%', 'Should not have errors';
  RAISE NOTICE 'PASS: Test 2 - render_adr_markdown handles NULL fields gracefully';
END;
$$;

-- Test 3: EXPORT_REQUESTED creates git-export outbox with markdown
DO $$
DECLARE
  rec adrs;
  ob adr_outbox;
BEGIN
  rec := create_adr('T_GE3', 'C_GE3', 'U_GE3', 'Export MD test', 'context', 'decision');
  rec := apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_GE3');

  SELECT * INTO ob FROM adr_outbox
  WHERE adr_id = rec.id AND destination = 'git-export'
  ORDER BY created_at DESC LIMIT 1;

  ASSERT ob.id IS NOT NULL, 'Should have git-export outbox row';
  ASSERT ob.payload ? 'markdown', 'Payload should contain markdown';
  ASSERT ob.payload ? 'adr_id', 'Payload should contain adr_id';
  ASSERT ob.payload ? 'title', 'Payload should contain title';
  ASSERT (ob.payload->>'markdown') LIKE '%Export MD test%',
    'Markdown should contain title';
  RAISE NOTICE 'PASS: Test 3 - EXPORT_REQUESTED creates git-export outbox with markdown';
END;
$$;

-- Test 4: handle_git_export_callback success transitions to ACCEPTED
DO $$
DECLARE
  rec adrs;
  result json;
  updated adrs;
BEGIN
  rec := create_adr('T_GE4', 'C_GE4', 'U_GE4', 'Callback success test', 'ctx');
  PERFORM apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_GE4');

  result := handle_git_export_callback(format(
    '{"adr_id": "%s", "status": "complete", "pr_url": "https://github.com/org/repo/pull/99", "branch": "adr/2026-02-26-callback-success-test"}',
    rec.id
  ));

  ASSERT result->>'ok' = 'true', 'Should return ok';
  ASSERT result->>'state' = 'ACCEPTED', format('Should be ACCEPTED, got %s', result->>'state');

  SELECT * INTO updated FROM adrs WHERE id = rec.id;
  ASSERT updated.git_pr_url = 'https://github.com/org/repo/pull/99',
    format('git_pr_url should be set: %s', updated.git_pr_url);
  ASSERT updated.git_branch = 'adr/2026-02-26-callback-success-test',
    format('git_branch should be set: %s', updated.git_branch);
  RAISE NOTICE 'PASS: Test 4 - handle_git_export_callback success transitions to ACCEPTED';
END;
$$;

-- Test 5: handle_git_export_callback failure keeps DRAFT
DO $$
DECLARE
  rec adrs;
  result json;
  updated adrs;
BEGIN
  rec := create_adr('T_GE5', 'C_GE5', 'U_GE5', 'Callback fail test', 'ctx');
  PERFORM apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_GE5');

  result := handle_git_export_callback(format(
    '{"adr_id": "%s", "status": "failed", "error": "GitHub API rate limit"}',
    rec.id
  ));

  ASSERT result->>'ok' = 'true', 'Should return ok';
  ASSERT result->>'state' = 'DRAFT', format('Should be DRAFT, got %s', result->>'state');

  SELECT * INTO updated FROM adrs WHERE id = rec.id;
  ASSERT updated.git_pr_url IS NULL, 'git_pr_url should still be NULL';
  RAISE NOTICE 'PASS: Test 5 - handle_git_export_callback failure keeps DRAFT';
END;
$$;

-- Test 6: handle_git_export_callback rejects missing adr_id
DO $$
BEGIN
  BEGIN
    PERFORM handle_git_export_callback('{"status": "complete"}');
    RAISE EXCEPTION 'Should have raised';
  EXCEPTION WHEN OTHERS THEN
    ASSERT sqlerrm LIKE '%adr_id%', format('Unexpected: %s', sqlerrm);
  END;
  RAISE NOTICE 'PASS: Test 6 - handle_git_export_callback rejects missing adr_id';
END;
$$;

ROLLBACK;
