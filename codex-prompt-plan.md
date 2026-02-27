# Codex Prompt Plan (Step-by-Step)

This plan is written to keep an agentic coding system constrained to the project philosophy: bot-token-only, minimal automation, Canvas-first, Git export.

## Global instruction (prepend to every Codex session)

You are implementing the ADR Slack Bot described in `docs/01-design-document.md` and `docs/04-prd.md`.

Hard constraints:
- Bot-token-only (xoxb). Do not introduce user OAuth.
- Canvas is the primary drafting surface.
- The bot is facilitative, not autonomous: do not add “AI decision-making” features.
- Any message capture is best-effort via Events API only; no on-demand backfill.

Output requirements:
- Prefer small, testable increments.
- Produce runnable code with clear setup instructions.
- Do not add features not explicitly in scope.

## Step 0 — Repo skeleton
Prompt:
Create a minimal repository skeleton with:
- `README.md` (keep existing)
- `docs/` (already present)
- `src/` application code (choose language/framework)
- `.env.example`
- `package.json` or equivalent
- basic lint/test config

Do not implement logic yet.

## Step 1 — Slack manifest and local config
Prompt:
Add `infra/slack-manifest.yaml` matching the approved bot scopes and events:
- /adr command
- app_mention event
- message.channels, message.groups events
- interactivity enabled
Include placeholder URLs.

Add a config loader reading:
- SLACK_SIGNING_SECRET
- SLACK_BOT_TOKEN
- APP_BASE_URL
- (optional) DB_URL
- Git integration env vars (placeholders)

## Step 2 — HTTP server + Slack signature verification
Prompt:
Implement an HTTP server with endpoints:
- POST /slack/commands/adr
- POST /slack/events
- POST /slack/interactivity

Verify Slack signatures on each request. Respond within Slack timing constraints (ACK fast). Add unit tests for signature verification.

## Step 3 — /adr enable and /adr disable
Prompt:
Implement parsing for `/adr` subcommands:
- `enable`: store channel_id enabled=true
- `disable`: store enabled=false
Store in a simple persistence layer:
- start with SQLite or in-memory, but behind an interface so it can swap later.

On enable, post a confirmation message that:
- explains bot-token-only visibility boundaries
- explains optional best-effort capture
- tells users how to disable

## Step 4 — /adr start (Canvas creation)
Prompt:
Implement `/adr start`:
- Check channel is enabled; if not, reply with instructions to run `/adr enable`.
- Create a Canvas with content from `docs/02-adr-template.md`.
- Include sentinel markers in managed blocks.
- Post a message in the originating channel/thread with a link to the Canvas.

Write an integration test that mocks Slack Web API calls.

## Step 5 — @adr mention trigger
Prompt:
In Events API handler:
- on app_mention, if it occurs in a channel that is enabled, create a Canvas and reply with link.
- avoid loops (ignore bot messages).
- if channel not enabled, reply with “run /adr enable”.

## Step 6 — Optional best-effort message ingestion
Prompt:
Implement event ingestion for message.channels and message.groups:
- filter irrelevant subtypes
- store minimal fields: channel_id, ts, thread_ts, user_id, text
- apply retention policy (e.g., delete older than N days via a daily job or on-write pruning)

Do not attempt to backfill history.

## Step 7 — Git export workflow (manual trigger)
Prompt:
Add a Slack button “Export to Git” in the Canvas link message.
On click:
- read Canvas content (or use stored ADR draft content if you mirror it)
- normalize to Markdown
- create a branch, commit file into docs/adr/
- open a PR
- post PR link back to Slack

Keep implementation minimal and fail-safe (retryable). Add a dry-run mode.

## Step 8 — Hardening
Prompt:
Add:
- structured logging (no secrets)
- error mapping to user-facing messages
- rate limit handling with backoff
- minimal observability counters

## Step 9 — Developer ergonomics
Prompt:
Add:
- local dev instructions
- docker-compose for DB if needed
- scripts to run tests and lint

## Step 10 — Cut scope audit
Prompt:
Review code vs docs. Remove any features that are not in PRD scope. Confirm bot-token-only is preserved.
