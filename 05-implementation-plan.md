# ADR Slack Bot — Implementation Plan (Revised with Supabase)

## Context

The implementation uses **Slack Modals** for drafting and **Block Kit** for in-channel summaries. **Supabase (PostgreSQL)** is the source of truth, replacing SQLite for production readiness and better multi-tenancy support.

- **Modal** collects structured ADR fields.
- **Block Kit message** displays the ADR in the channel.
- **Supabase (PostgreSQL):** Used for storing installations, channel configs, and ADR records.
- **Multi-tenancy:** Uses Slack's OAuth flow and Supabase for the `InstallationStore`.
- **Async Processing:** Export operations use background tasks.

## Stack

- **Runtime:** Node.js + TypeScript
- **Slack SDK:** `@slack/bolt` v4
- **DB:** Supabase via `@supabase/supabase-js`
- **Schema:** `supabase/migrations/*.sql`
- **Git:** GitHub API via `@octokit/rest`
- **Test:** Vitest (TDD)

## Repository Structure

```
slack-adr/
  infra/slack-manifest.yaml
  supabase/
    migrations/                 # SQL migration files
  src/
    app.ts                      # Bolt init + startup
    config.ts                   # Env var loader
    types.ts                    # AdrRecord, ChannelConfig, AdrStatus
    db/
      repository.ts             # IRepository interface + SupabaseRepository
    handlers/
      commands.ts               # /adr slash command dispatcher
      actions.ts                # Button handlers
      events.ts                 # app_mention + message handlers
      views.ts                  # Modal submission handlers
    services/
      block-kit.ts              # buildAdrModal() + buildAdrSummaryBlocks()
      git-export.ts             # GitHubExporter (Octokit)
      markdown.ts               # AdrRecord -> Markdown string
    utils/
      slugify.ts
  test/
  .env.example
  tsconfig.json
```

## Implementation Steps

### Step 0 — Project scaffold
`package.json`, `tsconfig.json`, `vitest.config.ts`, `.gitignore`, `.env.example`.
Required Vars: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET`, `SLACK_SIGNING_SECRET`, `GITHUB_TOKEN`.

### Step 1 — Supabase Schema (Migrations)
`supabase/migrations/20260226000000_init.sql`.
Tables: 
- `workspace_install` (team_id, bot_token, installation_json, created_at)
- `channel_config` (team_id, channel_id, enabled, created_at)
- `adr_workspace` (adr_id, team_id, channel_id, thread_ts, created_by, status, title, context, etc., git_pr_url)
Tests: Verify SQL migrations apply cleanly.

### Step 2 — Supabase Repository
`src/db/repository.ts`: Implement `SupabaseRepository` using `@supabase/supabase-js`.
Logic: Handle `upsert` for installations and standard CRUD for ADRs and channel configs.
Tests: Integration tests with a Supabase local/dev project.

### Step 3 — Bolt App with Supabase OAuth
`src/app.ts`: Configure `App` with a custom `installationStore` that uses the `SupabaseRepository`.
Tests: Store and fetch installation.

### Step 4 — Command Dispatch & Membership Check
`src/handlers/commands.ts`.
Check membership via `conversations.info` before `/adr start`.
Tests: Fail if bot not in channel.

### Step 5 — `/adr enable` and `/adr disable`
Store channel config in Supabase.
Tests: repo updates verified.

### Step 6 — Context Capture & Modal Builder
`src/services/block-kit.ts`: `buildAdrModal()`.
Fetch thread context to pre-fill the "Context" field.

### Step 7 — Summary Message & Traceability
`buildAdrSummaryBlocks()`: Ensure "Slack Thread Link" is clearly visible.

### Step 8 — Create Modal Submission
`src/handlers/views.ts`: on `adr_create_modal`. Extract fields, `repo.createAdr()`, post summary, save `message_ts`.

### Step 9 — Edit Logic
Action/View handlers for `edit_adr` and `adr_edit_modal`. Update Supabase record and `chat.update` the summary.

### Step 10 — `@adr` Mention Trigger
`app_mention` handler: post a "Start ADR" button in the thread.

### Step 11 — Markdown Renderer
`src/services/markdown.ts`: Render ADR to Markdown (include link).

### Step 12 — Async Export Logic
`src/handlers/actions.ts`: `ack()` immediately -> Show "Exporting..." -> Background Octokit task.

### Step 13 — Git Export Service
`src/services/git-export.ts`: Create branch, commit, open PR.

### Step 14 — Export Completion & Status Update
Update Supabase record with `git_pr_url`, set status to `Accepted`, and update Slack UI.

### Step 15 — Integration Tests & Hardening
Full end-to-end flow tests.

### Step 16 — Slack Manifest
`infra/slack-manifest.yaml`.
