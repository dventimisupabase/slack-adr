-- Step 19: Dead-letter handling and outbox hygiene
-- 1. dead_letter_outbox: mark exhausted rows (attempts >= max_attempts)
-- 2. purge_old_outbox: remove delivered rows older than 30 days
-- 3. Schedule both via pg_cron

-- Mark exhausted outbox rows as dead-lettered so they stop showing up in queries
-- and are visible as permanently failed in the outbox.
CREATE FUNCTION dead_letter_outbox() RETURNS void AS $$
BEGIN
  UPDATE adr_outbox SET
    delivered_at = now(),
    last_error = format('DEAD_LETTER: exhausted after %s attempts. Last error: %s', attempts, coalesce(last_error, 'unknown'))
  WHERE delivered_at IS NULL
    AND attempts >= max_attempts
    AND pg_net_request_id IS NULL;  -- not currently in-flight
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Purge delivered outbox rows older than 30 days to keep the table lean.
-- Only removes delivered rows — undelivered/dead-lettered rows with delivered_at
-- are also eligible since they're terminal.
CREATE FUNCTION purge_old_outbox() RETURNS void AS $$
BEGIN
  DELETE FROM adr_outbox
  WHERE delivered_at IS NOT NULL
    AND delivered_at < now() - interval '30 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Run dead-lettering every 5 minutes (aligns with recover_stuck_exports)
SELECT cron.schedule(
  'dead-letter-outbox',
  '*/5 * * * *',
  $$SELECT dead_letter_outbox()$$
);

-- Run purge daily at 3 AM UTC
SELECT cron.schedule(
  'purge-old-outbox',
  '0 3 * * *',
  $$SELECT purge_old_outbox()$$
);
