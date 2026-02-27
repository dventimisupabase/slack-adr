-- Step 5: Security and RLS
-- All mutations go through SECURITY DEFINER functions.
-- Authenticated/anon roles get SELECT only. Service role bypasses RLS.

ALTER TABLE workspace_install ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE adrs ENABLE ROW LEVEL SECURITY;
ALTER TABLE adr_events ENABLE ROW LEVEL SECURITY;

-- Revoke direct write access from non-service roles
REVOKE INSERT, UPDATE, DELETE ON workspace_install FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON channel_config FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON adrs FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON adr_events FROM authenticated, anon;

-- Grant SELECT to authenticated (for web UI if needed later)
GRANT SELECT ON adrs TO authenticated;
GRANT SELECT ON adr_events TO authenticated;
GRANT SELECT ON channel_config TO authenticated;

-- Service role bypasses RLS
CREATE POLICY "service_role_all" ON workspace_install FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role_all" ON channel_config FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role_all" ON adrs FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY "service_role_all" ON adr_events FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Authenticated can read all ADRs and events (no row-level filtering for now)
CREATE POLICY "authenticated_read" ON adrs FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated_read" ON adr_events FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated_read" ON channel_config FOR SELECT TO authenticated USING (true);

-- Mark all mutation functions as SECURITY DEFINER
ALTER FUNCTION create_adr SECURITY DEFINER;
ALTER FUNCTION apply_adr_event SECURITY DEFINER;
ALTER FUNCTION dispatch_side_effects SECURITY DEFINER;
ALTER FUNCTION handle_slack_webhook SECURITY DEFINER;
ALTER FUNCTION handle_interactive_payload SECURITY DEFINER;
ALTER FUNCTION build_adr_list SECURITY DEFINER;
ALTER FUNCTION build_adr_view SECURITY DEFINER;
