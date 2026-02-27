# ADR Slack Bot

A minimal Slack app that creates a deliberate workspace (Slack Canvas) for drafting Architectural Decision Records (ADRs) and exporting them to Git as Markdown pull requests.

This project is intentionally **bot-token-only (xoxb)** and intentionally **lightweight**. The bot’s primary value is social signaling (“slow down and record the decision”) plus a structured drafting surface—not automation.

## Repository contents

- `docs/01-design-document.md` — system architecture and workflow
- `docs/02-adr-template.md` — finalized ADR Canvas template
- `docs/03-risk-review.md` — operational, privacy, and adoption risks + mitigations
- `docs/04-prd.md` — one-page lean PRD
- `docs/codex-prompt-plan.md` — step-by-step agent prompt plan for implementation

## MVP capabilities

- `/adr start` creates an ADR drafting Canvas in the current context (thread/channel) and posts a link back to Slack.
- `/adr enable` enables the bot in a channel and posts privacy/behavior expectations.
- `@adr` mention can also trigger creation (MVP).
- Export ADR to Git as a Markdown PR.

## Design tenets

1. **Simplicity first**: minimal moving parts, minimal scopes.
2. **Humans do the thinking**: the bot creates the workspace; people write the ADR.
3. **Least surprise**: the bot only observes channels where it is invited; best-effort message capture only.
4. **Deterministic updates**: Canvas edits patch specific managed sections without clobbering human edits.
5. **Git is the source of truth**: accepted ADRs live in a repo via PR.

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
