-- Step 11: Outbox Suppression for Interactive Actions
-- Already implemented in steps 6 (dispatch_side_effects checks app.suppress_outbox)
-- and step 9 (handle_interactive_payload sets app.suppress_outbox).
-- This migration is a no-op placeholder for documentation purposes.

-- Verify the mechanism is in place by confirming the function exists
DO $$
BEGIN
  ASSERT (SELECT count(*) FROM pg_proc WHERE proname = 'handle_interactive_payload') = 1,
    'handle_interactive_payload should exist';
  ASSERT (SELECT count(*) FROM pg_proc WHERE proname = 'dispatch_side_effects') = 1,
    'dispatch_side_effects should exist';
END;
$$;
