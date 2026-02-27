# ADR Slack Bot — Revised Implementation Plan (Database-as-Brain)

## Context

The original plan used Node.js + `@slack/bolt` + `@supabase/supabase-js` + `@octokit/rest` + Vitest. After studying the [`dventimisupabase/capacity_request`](https://github.com/dventimisupabase/capacity_request) reference implementation, we're adopting a **database-as-brain** architecture where almost all business logic lives in PostgreSQL, with thin Supabase Edge Functions as proxies.

This eliminates the Node.js application layer entirely. The stack becomes: **Supabase (PostgreSQL 17 + Edge Functions + pg_net + pg_cron)**.

## Architecture

- **Edge Functions (Deno)**: Thin proxies that rewrite `Content-Type` and forward to PostgREST RPCs. Only exception: modal opening (`trigger_id` expires in 3s) and sequential GitHub API calls.
- **PostgREST as API gateway**: SQL functions receive raw Slack payloads as text parameters.
- **Event sourcing**: Append-only `adr_events` table + mutable `adrs` projection + single `apply_adr_event()` reducer.
- **Pure state machine**: `compute_adr_next_state()` is `IMMUTABLE` — no side effects, trivially testable.
- **Transactional outbox**: Side effects enqueued in same transaction, delivered by `pg_cron` every 30s via `pg_net`.
- **Slack signature verification in SQL**: HMAC-SHA256 via `pgcrypto`.
- **SQL test suite**: TDD with `BEGIN`/`ROLLBACK` transaction blocks.

## Stack

- **Runtime**: Supabase (hosted PostgreSQL 17 + Deno Edge Functions)
- **Extensions**: `pgcrypto`, `pg_net`, `pg_cron`
- **Slack integration**: HTTP webhooks (no Bolt SDK)
- **Git integration**: GitHub REST API via Edge Function + callback RPC
- **Tests**: SQL (`psql -v ON_ERROR_STOP=1 -f test/*.sql`)

## Repository Structure

```
slack-adr/
  slack-app-manifest.yaml
  supabase/
    config.toml
    migrations/
      20260226000001_extensions_and_enums.sql
      20260226000002_tables_and_indexes.sql
      20260226000003_core_functions.sql
      20260226000004_side_effects_and_webhooks.sql
      20260226000005_security_and_rls.sql
      20260226000006_outbox.sql
      20260226000007_block_kit_messages.sql
      20260226000008_thread_ts_capture.sql
      20260226000009_slash_command_dispatch.sql
      20260226000010_modal_submission.sql
      20260226000011_suppress_interactive_outbox.sql
      20260226000012_event_subscription.sql
      20260226000013_git_export.sql
    functions/
      slack-proxy/index.ts
      event-proxy/index.ts
      git-export/index.ts
  test/
    test_state_machine.sql
    test_reducer.sql
    test_webhook_handler.sql
    test_modal_submission.sql
    test_block_kit.sql
    test_event_subscription.sql
    test_git_export.sql
```

## Vault Secrets

| Secret | Description |
|---|---|
| `SLACK_BOT_TOKEN` | `xoxb-...` bot token |
| `SLACK_SIGNING_SECRET` | HMAC signing secret |
| `GITHUB_TOKEN` | PAT with `repo` scope |
| `GITHUB_REPO_OWNER` | e.g. `myorg` |
| `GITHUB_REPO_NAME` | e.g. `architecture` |
| `GITHUB_DEFAULT_BRANCH` | e.g. `main` |

## Cron Jobs

| Job | Frequency | Function |
|---|---|---|
| `process-outbox` | 30 seconds | `process_outbox()` |
| `capture-thread-ts` | 30 seconds | `capture_thread_timestamps()` |

---

## Implementation Steps

Each step follows TDD: write tests first, watch them fail, write the migration, watch them pass.

### Step 1 — Extensions and Enums
**File**: `supabase/migrations/20260226000001_extensions_and_enums.sql`

- `pgcrypto`, `pg_net`, `pg_cron` extensions
- `adr_state` enum: `DRAFT`, `ACCEPTED`, `REJECTED`, `SUPERSEDED`
- `adr_event_type` enum: `ADR_CREATED`, `ADR_UPDATED`, `ADR_ACCEPTED`, `ADR_REJECTED`, `ADR_SUPERSEDED`, `EXPORT_REQUESTED`, `EXPORT_COMPLETED`, `EXPORT_FAILED`
- `adr_actor_type` enum: `user`, `system`, `cron`
- `adr_seq` sequence + `next_adr_id()` → `ADR-YYYY-NNNNNN`

**Tests**: ID format, sequential, correct year.

### Step 2 — Tables and Indexes
**File**: `supabase/migrations/20260226000002_tables_and_indexes.sql`

- `workspace_install` (team_id PK, bot_token, installed_at)
- `channel_config` (team_id + channel_id PK, enabled, created_at)
- `adrs` — projection table (id, version, state, team_id, channel_id, thread_ts, created_by, title, context_text, decision, alternatives, consequences, open_questions, decision_drivers, implementation_plan, reviewers, slack_thread_link, slack_channel_id, slack_message_ts, git_pr_url, git_branch, created_at, updated_at)
- `adr_events` — append-only (id, adr_id FK, event_type, actor_type, actor_id, payload jsonb, created_at)
- Indexes on events(adr_id), adrs(team_id, channel_id)

**Tests**: Tables accept inserts, FK enforced.

### Step 3 — Core Functions (heart of the system)
**File**: `supabase/migrations/20260226000003_core_functions.sql`

`compute_adr_next_state(adr_state, adr_event_type) RETURNS adr_state` — IMMUTABLE pure function:
- DRAFT + ADR_CREATED → DRAFT
- DRAFT + ADR_UPDATED → DRAFT
- DRAFT + ADR_ACCEPTED → ACCEPTED
- DRAFT + ADR_REJECTED → REJECTED
- DRAFT + EXPORT_REQUESTED → DRAFT
- DRAFT + EXPORT_COMPLETED → ACCEPTED
- DRAFT + EXPORT_FAILED → DRAFT
- ACCEPTED + ADR_UPDATED → ACCEPTED
- ACCEPTED + ADR_SUPERSEDED → SUPERSEDED
- All others → EXCEPTION

`apply_adr_event(p_adr_id, p_event_type, p_actor_type, p_actor_id, p_payload)` — the reducer:
- `SELECT ... FOR UPDATE` (pessimistic lock)
- Compute next state via `compute_adr_next_state`
- Insert event into `adr_events`
- Update projection with `WHERE version = req.version` (optimistic concurrency)
- Call `dispatch_side_effects` (stub initially)

`create_adr(...)` — generate ID, insert row, apply `ADR_CREATED` event.

**Tests**: All valid transitions, all invalid transitions raise exceptions, create_adr works, version increments, event log populated.

### Step 4 — Side Effects and Webhooks
**File**: `supabase/migrations/20260226000004_side_effects_and_webhooks.sql`

- `get_secret(text) RETURNS text` — vault helper (SECURITY DEFINER)
- `url_decode(text) RETURNS text` — `%XX` + `+` handling (IMMUTABLE)
- `verify_slack_signature(raw_body, timestamp_, signature) RETURNS boolean` — HMAC-SHA256 via pgcrypto
- `handle_slack_webhook(text) RETURNS json` — initial version: parse form body, verify signature, route subcommands (enable/disable/list/view/help) and interactive actions (accept/reject/export)
- `check_request()` — PostgREST pre-request hook: validate signature headers, reject replay (>5min)
- `dispatch_side_effects()` — stub (enqueues to outbox once step 6 lands)

**Tests**: url_decode, verify_slack_signature (good/bad), subcommand routing, check_request rejects stale timestamps.

### Step 5 — Security and RLS
**File**: `supabase/migrations/20260226000005_security_and_rls.sql`

- Enable RLS on all tables
- Revoke direct INSERT/UPDATE/DELETE from `authenticated`/`anon`
- Grant SELECT on `adrs`, `adr_events` to `authenticated`
- All mutations go through SECURITY DEFINER functions
- Service role bypasses RLS

### Step 6 — Transactional Outbox
**File**: `supabase/migrations/20260226000006_outbox.sql`

- `adr_outbox` table (id, adr_id, event_id, destination `'slack'`/`'git-export'`, payload jsonb, delivered_at, attempts, max_attempts, pg_net_request_id)
- Partial index on undelivered rows
- `enqueue_outbox()` helper
- `process_outbox()` — poll with `FOR UPDATE SKIP LOCKED`, look up secrets at delivery time, call `net.http_post`
- Wire `dispatch_side_effects` to enqueue instead of direct HTTP
- `pg_cron` schedule: every 30 seconds

**Tests**: Enqueue works, dispatch creates outbox rows, process_outbox marks delivered.

### Step 7 — Block Kit Messages
**File**: `supabase/migrations/20260226000007_block_kit_messages.sql`

`build_adr_block_kit(req adrs, event_type, actor_id)` — STABLE function returning jsonb:
- Header: `ADR-YYYY-NNNNNN: <title>`
- Fields: State, Created By, Date
- Sections: Context, Decision (truncated)
- Context line: who acted, when (omitted for `/adr view`)
- Contextual action buttons by state:
  - DRAFT: Edit, Accept, Reject, Export
  - ACCEPTED: Edit, Supersede, Export (if no PR yet)
  - REJECTED/SUPERSEDED: no buttons
- PR link section when `git_pr_url` is set

**Tests**: Correct buttons per state, PR link appears when set, NULL channel returns NULL.

### Step 8 — Thread TS Capture
**File**: `supabase/migrations/20260226000008_thread_ts_capture.sql`

- `capture_thread_timestamps()` — polls `net._http_response` for delivered outbox rows, extracts Slack `ts`, writes to `adrs.slack_message_ts`
- `pg_cron` schedule: every 30 seconds

### Step 9 — Full Slash Command Dispatch
**File**: `supabase/migrations/20260226000009_slash_command_dispatch.sql`

Replace initial `handle_slack_webhook` with complete implementation:
- `/adr start` → ephemeral ack (modal opened by Edge Function)
- `/adr enable` → upsert channel_config, return privacy expectations message
- `/adr disable` → update channel_config, return confirmation
- `/adr list` → query adrs for channel, return formatted list
- `/adr view <id>` → return Block Kit via `build_adr_block_kit`
- `/adr help` → help text
- Interactive: accept/reject/supersede/export (with outbox suppression for button responses)

**Tests**: Each subcommand returns correct response, enable/disable updates config, interactive actions transition state.

### Step 10 — Modal Submission
**File**: `supabase/migrations/20260226000010_modal_submission.sql`

`handle_slack_modal_submission(text) RETURNS json`:
- Parse JSON `view_submission` payload
- Extract fields from `view.state.values`
- `private_metadata` carries `channel_id|thread_ts|adr_id`
- If `adr_id` present → edit via `apply_adr_event(ADR_UPDATED)`
- If no `adr_id` → create via `create_adr()`
- Validate required fields (title, context), return Slack error format if invalid
- Return NULL to close modal

**Tests**: Create flow, edit flow, validation errors.

### Step 11 — Outbox Suppression
**File**: `supabase/migrations/20260226000011_suppress_interactive_outbox.sql`

- `dispatch_side_effects` checks `current_setting('app.suppress_outbox', true)`
- `handle_slack_webhook` sets `app.suppress_outbox = 'true'` before interactive action apply

**Tests**: Interactive actions produce no outbox rows; non-interactive paths still do.

### Step 12 — Event Subscription (app_mention)
**File**: `supabase/migrations/20260226000012_event_subscription.sql`

`handle_slack_event(text) RETURNS json`:
- Handle `url_verification` challenge
- For `app_mention`: check channel enabled, enqueue outbox row with "Start ADR" button
- Return 200 immediately

**Tests**: Challenge response, mention creates outbox row, disabled channel ignored.

### Step 13 — Git Export
**File**: `supabase/migrations/20260226000013_git_export.sql`

`render_adr_markdown(adr_id) RETURNS text` — renders ADR fields to the template from `02-adr-template.md`.

`handle_git_export_callback(text) RETURNS json`:
- On success: `apply_adr_event(EXPORT_COMPLETED)`, set `git_pr_url` and `git_branch`
- On failure: `apply_adr_event(EXPORT_FAILED)`

Wire `dispatch_side_effects` for `EXPORT_REQUESTED` → enqueue outbox with `destination = 'git-export'`.

**Tests**: Markdown rendering, export callback success/failure, outbox row created for export.

---

## Edge Functions

### `slack-proxy/index.ts`
Thin Deno proxy, 3 paths (mirrors capacity_request):

1. **Modal opening**: `/adr start`, `edit_adr` action, `start_adr_from_mention` action → call `views.open` with `trigger_id` (3s constraint). Modal has fields: Title, Context (required), Decision, Alternatives, Consequences, Open Questions, Decision Drivers, Implementation Plan, Reviewers. For edits: pre-fill by reading ADR from PostgREST. `private_metadata` = `channel_id|thread_ts|adr_id`.
2. **Interactive payloads**: `view_submission` → forward to `/rpc/handle_slack_modal_submission`. `block_actions` (non-modal) → fire-and-forget to `/rpc/handle_slack_webhook`, post result to `response_url`.
3. **Default**: Forward raw body to `/rpc/handle_slack_webhook` as `text/plain`.

### `event-proxy/index.ts`
- Handle `url_verification` directly (no DB)
- Forward all other events to `/rpc/handle_slack_event` as `text/plain`

### `git-export/index.ts`
Sequential GitHub API calls (cannot use pg_net):
1. Get base branch SHA
2. Create branch `adr/<date>-<slug>`
3. Create file `docs/adr/<ADR-ID>.md`
4. Open PR
5. Callback to `/rpc/handle_git_export_callback` with result

---

## Slack App Manifest

```yaml
display_information:
  name: ADR Bot
  description: Create and manage Architectural Decision Records from Slack.
features:
  bot_user:
    display_name: ADR Bot
    always_online: true
  slash_commands:
    - command: /adr
      url: https://<PROJECT_REF>.supabase.co/functions/v1/slack-proxy
      description: Create or manage ADRs
      usage_hint: "start | enable | disable | list | view <id> | help"
oauth_config:
  scopes:
    bot:
      - chat:write
      - commands
      - app_mentions:read
      - channels:history
      - groups:history
settings:
  event_subscriptions:
    request_url: https://<PROJECT_REF>.supabase.co/functions/v1/event-proxy
    bot_events:
      - app_mention
  interactivity:
    is_enabled: true
    request_url: https://<PROJECT_REF>.supabase.co/functions/v1/slack-proxy
  socket_mode_enabled: false
```

## Verification

1. **Unit tests**: `psql -v ON_ERROR_STOP=1 -f test/test_*.sql` against local Supabase (`supabase start`)
2. **Edge Function smoke**: `curl` against local Supabase Edge Functions with mock Slack payloads
3. **Integration**: Install Slack app to test workspace, run `/adr enable`, `/adr start`, submit modal, click Export, verify PR created
