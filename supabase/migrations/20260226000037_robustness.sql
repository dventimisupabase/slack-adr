-- Step 38: Robustness improvements
-- 1. Rate limit bucket cleanup cron job (expires entries older than 1 hour)
-- 2. Response URL error handling (Edge Function fix, not SQL)

-- Schedule rate limit bucket cleanup every 10 minutes
SELECT cron.schedule(
  'cleanup-rate-limit-buckets',
  '*/10 * * * *',
  $$DELETE FROM rate_limit_buckets WHERE window_start < now() - interval '1 hour'$$
);
