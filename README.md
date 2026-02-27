# ADR Slack Bot

A minimal Slack app that creates a deliberate workspace for drafting Architectural Decision Records (ADRs) and exporting them to Git as Markdown pull requests.

This project is intentionally **bot-token-only (xoxb)** (with multi-tenant support) and intentionally **lightweight**. The bot’s primary value is social signaling (“slow down and record the decision”) plus a structured drafting surface—not automation.

## Architecture

**Database-as-brain**: all business logic lives in PostgreSQL. Supabase Edge Functions are thin proxies. Inspired by [`dventimisupabase/capacity_request`](https://github.com/dventimisupabase/capacity_request).

- **Supabase** (PostgreSQL 17 + Edge Functions + `pg_net` + `pg_cron`)
- **Event sourcing**: append-only `adr_events` + mutable `adrs` projection + pure state machine
- **Transactional outbox**: Slack messages and Git export dispatched reliably via `pg_cron`
- **No application server**: no Node.js, no Bolt SDK — just SQL functions behind PostgREST

## Repository contents

- `01-design-document.md` — system architecture and workflow (Note: includes original Canvas-based design)
- `02-adr-template.md` — ADR template fields
- `03-risk-review.md` — operational, privacy, and adoption risks + mitigations
- `04-prd.md` — one-page lean PRD
- `05-implementation-plan.md` — step-by-step implementation plan (Current Source of Truth)
- `slack-app-manifest.yaml` — Slack app manifest
- `supabase/` — migrations, Edge Functions, config
- `test/` — SQL test suite (TDD, `BEGIN`/`ROLLBACK`)

## MVP capabilities

- `/adr start` opens a structured Modal to draft an ADR, pre-filled with thread context.
- `/adr enable` enables the bot in a channel and posts privacy/behavior expectations.
- `@adr` mention triggers a "Start ADR" button in the thread.
- Export ADR to Git as a Markdown PR with status tracking.

## Design tenets

1. **Simplicity first**: minimal moving parts, minimal scopes.
2. **Humans do the thinking**: the bot creates the workspace; people write the ADR.
3. **Least surprise**: the bot only observes channels where it is invited; best-effort message capture for context pre-filling.
4. **Git is the source of truth**: accepted ADRs live in a repo via PR.

## Quick start

1. `supabase start` (local dev)
2. Apply migrations: `supabase db reset`
3. Run tests: `psql -v ON_ERROR_STOP=1 -f test/test_*.sql`
4. Deploy Edge Functions: `supabase functions deploy`
5. Create Slack app from `slack-app-manifest.yaml` and install to workspace

## Out of scope (by design)

- User OAuth / acting on behalf of a user
- Full Slack history archival
- Approval workflows
- Complex dashboards or governance systems

## License

TBD
