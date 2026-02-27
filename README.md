# ADR Slack Bot

A minimal Slack app that creates a deliberate workspace for drafting Architectural Decision Records (ADRs) and exporting them to Git as Markdown pull requests.

This project is intentionally **bot-token-only (xoxb)** (with multi-tenant support) and intentionally **lightweight**. The bot’s primary value is social signaling (“slow down and record the decision”) plus a structured drafting surface—not automation.

## Context Pivot

Initially designed for Slack Canvas, the implementation now uses **Slack Modals** for drafting and **Block Kit** for in-channel summaries. This ensures the bot can reliably read and export the ADR content to Git, which is currently a limitation of the Canvas API.

## Repository contents

- `docs/01-design-document.md` — system architecture and workflow (Note: includes original Canvas-based design)
- `docs/02-adr-template.md` — ADR template fields
- `docs/03-risk-review.md` — operational, privacy, and adoption risks + mitigations
- `docs/04-prd.md` — one-page lean PRD
- `05-implementation-plan.md` — step-by-step implementation plan (Current Source of Truth)

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

## Quick start (implementation sketch)

1. Create a Slack app from the manifest and install it to a test workspace.
2. Implement the `/adr` command handler:
   - `enable|disable` toggles channel config
   - `start` creates a Canvas + posts a link
3. Implement Canvas creation using the ADR template in `docs/02-adr-template.md`.
4. Implement Git export (branch + PR) for “Draft Ready”.

## Out of scope (by design)

- User OAuth / acting on behalf of a user
- Full Slack history archival
- Approval workflows
- Complex dashboards or governance systems

## License

TBD
