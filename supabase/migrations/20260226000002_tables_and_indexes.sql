-- Step 2: Tables and Indexes

-- Multi-tenant workspace installations
CREATE TABLE workspace_install (
  team_id text PRIMARY KEY,
  bot_token text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now()
);

-- Per-channel bot enablement
CREATE TABLE channel_config (
  team_id text NOT NULL,
  channel_id text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, channel_id)
);

-- ADR projection table (current state)
CREATE TABLE adrs (
  id text PRIMARY KEY,
  version integer NOT NULL DEFAULT 1,
  state adr_state NOT NULL,
  team_id text NOT NULL,
  channel_id text NOT NULL,
  thread_ts text,
  created_by text NOT NULL,
  title text NOT NULL,
  context_text text,
  decision text,
  alternatives text,
  consequences text,
  open_questions text,
  decision_drivers text,
  implementation_plan text,
  reviewers text,
  slack_thread_link text,
  slack_channel_id text,
  slack_message_ts text,
  git_pr_url text,
  git_branch text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Append-only event log
CREATE TABLE adr_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  adr_id text NOT NULL REFERENCES adrs(id),
  event_type adr_event_type NOT NULL,
  actor_type adr_actor_type NOT NULL,
  actor_id text NOT NULL,
  payload jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_adr_events_adr_id ON adr_events (adr_id, created_at);
CREATE INDEX idx_adrs_team_channel ON adrs (team_id, channel_id);
CREATE INDEX idx_channel_config_team ON channel_config (team_id);
