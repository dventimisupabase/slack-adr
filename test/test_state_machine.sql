-- test/test_state_machine.sql
-- Tests for Step 1 (extensions, enums, ID generation) and Step 3 (state machine, reducer)
-- Run: psql -v ON_ERROR_STOP=1 -f test/test_state_machine.sql

BEGIN;

-- ============================================================
-- Step 1 Tests: Extensions and Enums
-- ============================================================

-- Test 1: pgcrypto extension is available
DO $$
BEGIN
  PERFORM gen_random_uuid();
  RAISE NOTICE 'PASS: Test 1 - pgcrypto extension available (gen_random_uuid works)';
END;
$$;

-- Test 2: adr_state enum exists with correct values
DO $$
BEGIN
  PERFORM 'DRAFT'::adr_state;
  PERFORM 'ACCEPTED'::adr_state;
  PERFORM 'REJECTED'::adr_state;
  PERFORM 'SUPERSEDED'::adr_state;
  RAISE NOTICE 'PASS: Test 2 - adr_state enum has all expected values';
END;
$$;

-- Test 3: adr_event_type enum exists with correct values
DO $$
BEGIN
  PERFORM 'ADR_CREATED'::adr_event_type;
  PERFORM 'ADR_UPDATED'::adr_event_type;
  PERFORM 'ADR_ACCEPTED'::adr_event_type;
  PERFORM 'ADR_REJECTED'::adr_event_type;
  PERFORM 'ADR_SUPERSEDED'::adr_event_type;
  PERFORM 'EXPORT_REQUESTED'::adr_event_type;
  PERFORM 'EXPORT_COMPLETED'::adr_event_type;
  PERFORM 'EXPORT_FAILED'::adr_event_type;
  RAISE NOTICE 'PASS: Test 3 - adr_event_type enum has all expected values';
END;
$$;

-- Test 4: adr_actor_type enum exists with correct values
DO $$
BEGIN
  PERFORM 'user'::adr_actor_type;
  PERFORM 'system'::adr_actor_type;
  PERFORM 'cron'::adr_actor_type;
  RAISE NOTICE 'PASS: Test 4 - adr_actor_type enum has all expected values';
END;
$$;

-- Test 5: next_adr_id() returns correct format ADR-YYYY-NNNNNN
DO $$
DECLARE
  id1 text;
  current_year text;
BEGIN
  id1 := next_adr_id();
  current_year := extract(year FROM now())::text;
  ASSERT id1 ~ ('^ADR-' || current_year || '-\d{6}$'),
    format('ID format mismatch: got %s', id1);
  RAISE NOTICE 'PASS: Test 5 - next_adr_id() returns correct format: %', id1;
END;
$$;

-- Test 6: next_adr_id() returns sequential IDs
DO $$
DECLARE
  id1 text;
  id2 text;
  seq1 int;
  seq2 int;
BEGIN
  id1 := next_adr_id();
  id2 := next_adr_id();
  seq1 := substring(id1 from '\d{6}$')::int;
  seq2 := substring(id2 from '\d{6}$')::int;
  ASSERT seq2 = seq1 + 1,
    format('IDs not sequential: %s, %s', id1, id2);
  RAISE NOTICE 'PASS: Test 6 - next_adr_id() returns sequential IDs: %, %', id1, id2;
END;
$$;

-- ============================================================
-- Step 3 Tests: Pure State Machine (compute_adr_next_state)
-- ============================================================

-- Test 7: DRAFT + ADR_CREATED → DRAFT
DO $$
BEGIN
  ASSERT compute_adr_next_state('DRAFT', 'ADR_CREATED') = 'DRAFT',
    'DRAFT + ADR_CREATED should stay DRAFT';
  RAISE NOTICE 'PASS: Test 7 - DRAFT + ADR_CREATED → DRAFT';
END;
$$;

-- Test 8: DRAFT + ADR_UPDATED → DRAFT
DO $$
BEGIN
  ASSERT compute_adr_next_state('DRAFT', 'ADR_UPDATED') = 'DRAFT',
    'DRAFT + ADR_UPDATED should stay DRAFT';
  RAISE NOTICE 'PASS: Test 8 - DRAFT + ADR_UPDATED → DRAFT';
END;
$$;

-- Test 9: DRAFT + ADR_ACCEPTED → ACCEPTED
DO $$
BEGIN
  ASSERT compute_adr_next_state('DRAFT', 'ADR_ACCEPTED') = 'ACCEPTED',
    'DRAFT + ADR_ACCEPTED should be ACCEPTED';
  RAISE NOTICE 'PASS: Test 9 - DRAFT + ADR_ACCEPTED → ACCEPTED';
END;
$$;

-- Test 10: DRAFT + ADR_REJECTED → REJECTED
DO $$
BEGIN
  ASSERT compute_adr_next_state('DRAFT', 'ADR_REJECTED') = 'REJECTED',
    'DRAFT + ADR_REJECTED should be REJECTED';
  RAISE NOTICE 'PASS: Test 10 - DRAFT + ADR_REJECTED → REJECTED';
END;
$$;

-- Test 11: DRAFT + EXPORT_REQUESTED → DRAFT
DO $$
BEGIN
  ASSERT compute_adr_next_state('DRAFT', 'EXPORT_REQUESTED') = 'DRAFT',
    'DRAFT + EXPORT_REQUESTED should stay DRAFT';
  RAISE NOTICE 'PASS: Test 11 - DRAFT + EXPORT_REQUESTED → DRAFT';
END;
$$;

-- Test 12: DRAFT + EXPORT_COMPLETED → ACCEPTED
DO $$
BEGIN
  ASSERT compute_adr_next_state('DRAFT', 'EXPORT_COMPLETED') = 'ACCEPTED',
    'DRAFT + EXPORT_COMPLETED should be ACCEPTED';
  RAISE NOTICE 'PASS: Test 12 - DRAFT + EXPORT_COMPLETED → ACCEPTED';
END;
$$;

-- Test 13: DRAFT + EXPORT_FAILED → DRAFT
DO $$
BEGIN
  ASSERT compute_adr_next_state('DRAFT', 'EXPORT_FAILED') = 'DRAFT',
    'DRAFT + EXPORT_FAILED should stay DRAFT';
  RAISE NOTICE 'PASS: Test 13 - DRAFT + EXPORT_FAILED → DRAFT';
END;
$$;

-- Test 14: ACCEPTED + ADR_UPDATED → ACCEPTED
DO $$
BEGIN
  ASSERT compute_adr_next_state('ACCEPTED', 'ADR_UPDATED') = 'ACCEPTED',
    'ACCEPTED + ADR_UPDATED should stay ACCEPTED';
  RAISE NOTICE 'PASS: Test 14 - ACCEPTED + ADR_UPDATED → ACCEPTED';
END;
$$;

-- Test 15: ACCEPTED + ADR_SUPERSEDED → SUPERSEDED
DO $$
BEGIN
  ASSERT compute_adr_next_state('ACCEPTED', 'ADR_SUPERSEDED') = 'SUPERSEDED',
    'ACCEPTED + ADR_SUPERSEDED should be SUPERSEDED';
  RAISE NOTICE 'PASS: Test 15 - ACCEPTED + ADR_SUPERSEDED → SUPERSEDED';
END;
$$;

-- Test 16: Invalid transition raises exception (REJECTED + ADR_UPDATED)
DO $$
BEGIN
  BEGIN
    PERFORM compute_adr_next_state('REJECTED', 'ADR_UPDATED');
    RAISE EXCEPTION 'Should have raised invalid transition';
  EXCEPTION WHEN raise_exception THEN
    ASSERT sqlerrm LIKE 'Invalid transition%',
      format('Unexpected error: %s', sqlerrm);
  END;
  RAISE NOTICE 'PASS: Test 16 - REJECTED + ADR_UPDATED raises exception';
END;
$$;

-- Test 17: Invalid transition (SUPERSEDED + ADR_ACCEPTED)
DO $$
BEGIN
  BEGIN
    PERFORM compute_adr_next_state('SUPERSEDED', 'ADR_ACCEPTED');
    RAISE EXCEPTION 'Should have raised invalid transition';
  EXCEPTION WHEN raise_exception THEN
    ASSERT sqlerrm LIKE 'Invalid transition%',
      format('Unexpected error: %s', sqlerrm);
  END;
  RAISE NOTICE 'PASS: Test 17 - SUPERSEDED + ADR_ACCEPTED raises exception';
END;
$$;

-- Test 18: Invalid transition (DRAFT + ADR_SUPERSEDED)
DO $$
BEGIN
  BEGIN
    PERFORM compute_adr_next_state('DRAFT', 'ADR_SUPERSEDED');
    RAISE EXCEPTION 'Should have raised invalid transition';
  EXCEPTION WHEN raise_exception THEN
    ASSERT sqlerrm LIKE 'Invalid transition%',
      format('Unexpected error: %s', sqlerrm);
  END;
  RAISE NOTICE 'PASS: Test 18 - DRAFT + ADR_SUPERSEDED raises exception';
END;
$$;

-- ============================================================
-- Step 3 Tests: Reducer (apply_adr_event) and create_adr
-- ============================================================

-- Test 19: create_adr creates an ADR in DRAFT state
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr(
    p_team_id := 'T_TEST',
    p_channel_id := 'C_TEST',
    p_created_by := 'U_AUTHOR',
    p_title := 'Use Postgres for everything',
    p_context_text := 'We need a database',
    p_decision := 'Use Postgres',
    p_alternatives := 'MySQL, MongoDB',
    p_consequences := 'Must learn SQL',
    p_open_questions := 'Which version?',
    p_decision_drivers := 'Simplicity',
    p_implementation_plan := 'Install PG',
    p_reviewers := 'Tech Lead'
  );
  ASSERT rec.id ~ '^ADR-\d{4}-\d{6}$', format('Bad ID: %s', rec.id);
  ASSERT rec.state = 'DRAFT', 'Should be DRAFT';
  ASSERT rec.version = 2, format('Version should be 2 (insert + ADR_CREATED event), got %s', rec.version);
  ASSERT rec.title = 'Use Postgres for everything', 'Title mismatch';
  ASSERT rec.context_text = 'We need a database', 'Context mismatch';
  ASSERT rec.created_by = 'U_AUTHOR', 'Created by mismatch';
  RAISE NOTICE 'PASS: Test 19 - create_adr creates ADR in DRAFT state: %', rec.id;
END;
$$;

-- Test 20: create_adr inserts ADR_CREATED event
DO $$
DECLARE
  rec adrs;
  evt_count int;
BEGIN
  rec := create_adr(
    p_team_id := 'T_TEST',
    p_channel_id := 'C_TEST',
    p_created_by := 'U_AUTHOR',
    p_title := 'Test event log',
    p_context_text := 'Testing'
  );
  SELECT count(*) INTO evt_count FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_CREATED';
  ASSERT evt_count = 1, format('Expected 1 ADR_CREATED event, got %s', evt_count);
  RAISE NOTICE 'PASS: Test 20 - create_adr inserts ADR_CREATED event';
END;
$$;

-- Test 21: apply_adr_event transitions DRAFT → ACCEPTED
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Accept test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_REVIEWER');
  ASSERT rec.state = 'ACCEPTED', format('Expected ACCEPTED, got %s', rec.state);
  ASSERT rec.version = 3, format('Expected version 3 (insert + created + accepted), got %s', rec.version);
  RAISE NOTICE 'PASS: Test 21 - apply_adr_event DRAFT → ACCEPTED';
END;
$$;

-- Test 22: apply_adr_event transitions DRAFT → REJECTED
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Reject test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_REVIEWER');
  ASSERT rec.state = 'REJECTED', format('Expected REJECTED, got %s', rec.state);
  RAISE NOTICE 'PASS: Test 22 - apply_adr_event DRAFT → REJECTED';
END;
$$;

-- Test 23: apply_adr_event transitions ACCEPTED → SUPERSEDED
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Supersede test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_REVIEWER');
  rec := apply_adr_event(rec.id, 'ADR_SUPERSEDED', 'user', 'U_REVIEWER');
  ASSERT rec.state = 'SUPERSEDED', format('Expected SUPERSEDED, got %s', rec.state);
  ASSERT rec.version = 4, format('Expected version 4 (insert + created + accepted + superseded), got %s', rec.version);
  RAISE NOTICE 'PASS: Test 23 - apply_adr_event ACCEPTED → SUPERSEDED';
END;
$$;

-- Test 24: Full export lifecycle DRAFT → EXPORT_REQUESTED → EXPORT_COMPLETED → ACCEPTED
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Export test', 'ctx');
  rec := apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_AUTHOR');
  ASSERT rec.state = 'DRAFT', 'EXPORT_REQUESTED should stay DRAFT';
  rec := apply_adr_event(rec.id, 'EXPORT_COMPLETED', 'system', 'git-export');
  ASSERT rec.state = 'ACCEPTED', 'EXPORT_COMPLETED should transition to ACCEPTED';
  RAISE NOTICE 'PASS: Test 24 - Export lifecycle DRAFT → EXPORT_REQUESTED → EXPORT_COMPLETED → ACCEPTED';
END;
$$;

-- Test 25: Export failure keeps DRAFT
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Export fail test', 'ctx');
  rec := apply_adr_event(rec.id, 'EXPORT_REQUESTED', 'user', 'U_AUTHOR');
  rec := apply_adr_event(rec.id, 'EXPORT_FAILED', 'system', 'git-export');
  ASSERT rec.state = 'DRAFT', 'EXPORT_FAILED should stay DRAFT';
  RAISE NOTICE 'PASS: Test 25 - Export failure keeps DRAFT';
END;
$$;

-- Test 26: apply_adr_event with ADR_UPDATED updates fields from payload
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Original title', 'Original context');
  rec := apply_adr_event(
    rec.id, 'ADR_UPDATED', 'user', 'U_EDITOR',
    '{"title": "Updated title", "context_text": "Updated context", "decision": "New decision"}'::jsonb
  );
  ASSERT rec.state = 'DRAFT', 'Should still be DRAFT';
  ASSERT rec.title = 'Updated title', format('Title not updated: %s', rec.title);
  ASSERT rec.context_text = 'Updated context', format('Context not updated: %s', rec.context_text);
  ASSERT rec.decision = 'New decision', format('Decision not updated: %s', rec.decision);
  RAISE NOTICE 'PASS: Test 26 - apply_adr_event ADR_UPDATED updates fields from payload';
END;
$$;

-- Test 27: Event log integrity — correct count and ordering
DO $$
DECLARE
  rec adrs;
  evt_count int;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Event log test', 'ctx');
  PERFORM apply_adr_event(rec.id, 'ADR_UPDATED', 'user', 'U_EDITOR', '{"title":"v2"}'::jsonb);
  PERFORM apply_adr_event(rec.id, 'ADR_ACCEPTED', 'user', 'U_REVIEWER');

  SELECT count(*) INTO evt_count FROM adr_events WHERE adr_id = rec.id;
  ASSERT evt_count = 3, format('Expected 3 events, got %s', evt_count);

  -- Verify each event type exists (ordering by created_at is non-deterministic within a transaction)
  SELECT count(*) INTO evt_count FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_CREATED';
  ASSERT evt_count = 1, format('Should have 1 ADR_CREATED event, got %s', evt_count);

  SELECT count(*) INTO evt_count FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_UPDATED';
  ASSERT evt_count = 1, format('Should have 1 ADR_UPDATED event, got %s', evt_count);

  SELECT count(*) INTO evt_count FROM adr_events
  WHERE adr_id = rec.id AND event_type = 'ADR_ACCEPTED';
  ASSERT evt_count = 1, format('Should have 1 ADR_ACCEPTED event, got %s', evt_count);

  RAISE NOTICE 'PASS: Test 27 - Event log integrity (3 events, all types present)';
END;
$$;

-- Test 28: Invalid transition via reducer raises exception
DO $$
DECLARE
  rec adrs;
BEGIN
  rec := create_adr('T_TEST', 'C_TEST', 'U_AUTHOR', 'Invalid transition test', 'ctx');
  rec := apply_adr_event(rec.id, 'ADR_REJECTED', 'user', 'U_REVIEWER');
  BEGIN
    PERFORM apply_adr_event(rec.id, 'ADR_UPDATED', 'user', 'U_EDITOR');
    RAISE EXCEPTION 'Should have raised invalid transition';
  EXCEPTION WHEN raise_exception THEN
    ASSERT sqlerrm LIKE 'Invalid transition%',
      format('Unexpected error: %s', sqlerrm);
  END;
  RAISE NOTICE 'PASS: Test 28 - Invalid transition via reducer raises exception';
END;
$$;

ROLLBACK;
