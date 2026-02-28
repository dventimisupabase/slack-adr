-- Step 31: Edge case hardening
-- 1. Extend event dedup retention from 24 hours to 7 days
-- 2. Add safety net for empty/whitespace ADR IDs in build_adr_view

-- 1. Update processed_events cleanup to 7-day retention
-- (Slack can retry events for up to 3 hours, but 7 days provides a safety margin)
SELECT cron.unschedule('cleanup-processed-events');
SELECT cron.schedule(
  'cleanup-processed-events',
  '30 4 * * *',
  $$DELETE FROM processed_events WHERE created_at < now() - interval '7 days'$$
);
