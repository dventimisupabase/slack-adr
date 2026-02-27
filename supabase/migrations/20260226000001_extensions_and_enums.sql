-- Step 1: Extensions and Enums
-- pgcrypto for HMAC-SHA256 signature verification and UUID generation
-- pg_net for async HTTP calls to Slack/GitHub
-- pg_cron for outbox processing and thread_ts capture

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- ADR lifecycle states
CREATE TYPE adr_state AS ENUM (
  'DRAFT',
  'ACCEPTED',
  'REJECTED',
  'SUPERSEDED'
);

-- Events that drive state transitions
CREATE TYPE adr_event_type AS ENUM (
  'ADR_CREATED',
  'ADR_UPDATED',
  'ADR_ACCEPTED',
  'ADR_REJECTED',
  'ADR_SUPERSEDED',
  'EXPORT_REQUESTED',
  'EXPORT_COMPLETED',
  'EXPORT_FAILED'
);

-- Who performed the action
CREATE TYPE adr_actor_type AS ENUM (
  'user',
  'system',
  'cron'
);

-- Human-readable ADR ID sequence
CREATE SEQUENCE adr_seq;

-- Generate ADR-YYYY-NNNNNN format IDs
CREATE FUNCTION next_adr_id() RETURNS text AS $$
  SELECT 'ADR-' || extract(year FROM now())::int || '-' || lpad(nextval('adr_seq')::text, 6, '0');
$$ LANGUAGE sql;
