-- test/test_reducer.sql
-- Tests for Step 2 (tables) and Step 3 (reducer/create_adr)
-- Run: psql -v ON_ERROR_STOP=1 -f test/test_reducer.sql

BEGIN;

-- ============================================================
-- Step 2 Tests: Tables and Indexes
-- ============================================================

-- Test 1: workspace_install accepts inserts
DO $$
BEGIN
  INSERT INTO workspace_install (team_id, bot_token)
  VALUES ('T_TEST_001', 'xoxb-test-token-001');
  RAISE NOTICE 'PASS: Test 1 - workspace_install accepts inserts';
END;
$$;

-- Test 2: channel_config accepts inserts
DO $$
BEGIN
  INSERT INTO channel_config (team_id, channel_id, enabled)
  VALUES ('T_TEST_001', 'C_TEST_001', true);
  RAISE NOTICE 'PASS: Test 2 - channel_config accepts inserts';
END;
$$;

-- Test 3: adrs table accepts inserts with correct defaults
DO $$
DECLARE
  rec adrs;
BEGIN
  INSERT INTO adrs (id, state, team_id, channel_id, created_by, title)
  VALUES ('ADR-2026-999001', 'DRAFT', 'T_TEST_001', 'C_TEST_001', 'U_USER_001', 'Test ADR')
  RETURNING * INTO rec;
  ASSERT rec.version = 1, 'Default version should be 1';
  ASSERT rec.state = 'DRAFT', 'State should be DRAFT';
  ASSERT rec.created_at IS NOT NULL, 'created_at should be set';
  ASSERT rec.updated_at IS NOT NULL, 'updated_at should be set';
  RAISE NOTICE 'PASS: Test 3 - adrs table accepts inserts with correct defaults';
END;
$$;

-- Test 4: adr_events accepts inserts with FK to adrs
DO $$
DECLARE
  evt_id uuid;
BEGIN
  INSERT INTO adr_events (adr_id, event_type, actor_type, actor_id, payload)
  VALUES ('ADR-2026-999001', 'ADR_CREATED', 'user', 'U_USER_001', '{}')
  RETURNING id INTO evt_id;
  ASSERT evt_id IS NOT NULL, 'Event ID should be generated';
  RAISE NOTICE 'PASS: Test 4 - adr_events accepts inserts with FK to adrs';
END;
$$;

-- Test 5: adr_events FK constraint enforced
DO $$
BEGIN
  BEGIN
    INSERT INTO adr_events (adr_id, event_type, actor_type, actor_id)
    VALUES ('ADR-NONEXISTENT', 'ADR_CREATED', 'user', 'U_USER_001');
    RAISE EXCEPTION 'Should have raised FK violation';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL; -- expected
  END;
  RAISE NOTICE 'PASS: Test 5 - adr_events FK constraint enforced';
END;
$$;

-- Test 6: channel_config composite PK prevents duplicates
DO $$
BEGIN
  BEGIN
    INSERT INTO channel_config (team_id, channel_id, enabled)
    VALUES ('T_TEST_001', 'C_TEST_001', false);
    RAISE EXCEPTION 'Should have raised unique violation';
  EXCEPTION WHEN unique_violation THEN
    NULL; -- expected
  END;
  RAISE NOTICE 'PASS: Test 6 - channel_config composite PK prevents duplicates';
END;
$$;

ROLLBACK;
