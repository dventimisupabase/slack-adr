# ADR Slack Bot – Design Document

## 1. Purpose

This document specifies the design of a Slack application whose primary purpose is to create a structured workspace for drafting Architectural Decision Records (ADRs). The application intentionally performs minimal automation. Its main function is to signal a transition from informal conversation to deliberate architectural decision-making, and to provide a collaborative drafting surface (Slack Canvas).

The application is bot-token-only (xoxb) to preserve operational simplicity, audit clarity, and minimal-surprise privacy semantics.

## 2. Goals and Non-Goals

### 2.1 Goals

1. Provide a simple mechanism to create an ADR drafting workspace from a Slack conversation.
2. Encourage teams to formalize architectural decisions using a structured template.
3. Maintain a clear audit trail of ADR creation and authorship.
4. Keep the application operationally simple and predictable.
5. Optionally capture conversation context on a best-effort basis.
6. Export completed ADRs to Git as Markdown via pull request.

### 2.2 Non-Goals

1. Perfect reconstruction of Slack conversation history.
2. Fully autonomous ADR generation.
3. Complex workflow automation or approval chains.
4. Acting on behalf of users via user OAuth.
5. Acting as a general-purpose AI summarization bot.

## 3. Design Principles

1. **Simplicity first.** The app should do very little beyond creating a drafting workspace.
2. **Humans do the thinking.** Automation assists but does not replace human reasoning.
3. **Least surprise.** The bot only accesses content from channels where it is present.
4. **Deterministic behavior.** Fail fast with clear instructions.
5. **Minimal scope.** Request the smallest set of Slack permissions necessary.
6. **Traceability.** Every ADR links back to its originating Slack thread.

## 4. User Workflow

### 4.1 Typical Scenario

1. Team members discuss a technical issue in a Slack thread.
2. Someone decides the topic warrants an ADR.
3. They run `/adr start` or mention `@adr` in the thread.
4. The bot creates a Slack Canvas containing an ADR template.
5. Humans collaborate in the Canvas to draft the ADR.
6. The ADR is marked “Draft Ready”.
7. The ADR is exported to Git as Markdown via PR.

### 4.2 Channel Enablement

1. A channel owner runs `/adr enable`.
2. The bot records that ADR drafting is allowed in that channel.
3. The bot confirms with a message describing what data it can access and how to disable.

### 4.3 Error Cases

If bot not in channel:
- Bot replies: “Invite @ADR Bot to this channel and retry.”

If insufficient history captured:
- Bot replies: “I only capture messages after I was invited. Paste missing context if needed.”

## 5. Slack Architecture

### 5.1 Authentication Model

Bot-token-only (xoxb).

Rationale:
- Simple install model.
- Clear audit identity.
- Minimal privacy concerns.
- Acceptable limitations on conversation history access.

### 5.2 Required Slack Features

- Slash command `/adr`
- `@adr` mentions
- Canvas creation and editing
- Interactive buttons/modals
- Event subscriptions for optional message capture

### 5.3 Scopes

Bot scopes:
- `commands`
- `chat:write`
- `app_mentions:read`
- `channels:history`
- `groups:history`
- `canvases:write`
- `canvases:read`

### 5.4 Event Subscriptions

- `app_mention`
- `message.channels`
- `message.groups`

Message events are optional and used only for best-effort context capture.

## 6. ADR Workspace Design

### 6.1 ADR Template

Each Canvas contains:
- Status
- Context
- Decision
- Alternatives Considered
- Consequences
- Open Questions
- Slack Thread Link

### 6.2 Managed Sections

The bot inserts hidden sentinel markers inside managed sections to allow deterministic updates without overwriting human edits.

Example markers:
- `adrbot:status:<adr_id>`
- `adrbot:context:<adr_id>`
- `adrbot:decision:<adr_id>`

### 6.3 Deterministic Editing Strategy

1. Lookup section via sentinel marker.
2. Replace only that section.
3. Preserve sentinel marker in replacement content.
4. Retry on edit conflict.

## 7. Data Model

### 7.1 Core Tables

`workspace_install`
- team_id
- bot_token
- installed_at

`channel_config`
- team_id
- channel_id
- enabled
- retention_days

`adr_workspace`
- adr_id
- team_id
- channel_id
- thread_ts
- created_by
- canvas_id
- status
- git_pr_url

`thread_index` (optional)
- team_id
- channel_id
- thread_ts
- message_count

`message_store` (optional, best-effort capture)
- team_id
- channel_id
- ts
- thread_ts
- user_id
- text

## 8. Git Export

When ADR marked ready:
1. Convert Canvas content to Markdown.
2. Create branch `adr/<date>-<slug>`.
3. Add file `docs/adr/ADR-<id>.md`.
4. Open pull request.
5. Post PR link to Slack thread.

## 9. Security and Privacy

1. Bot sees only channels where invited.
2. No user OAuth tokens stored.
3. Message capture is best-effort and minimal.
4. No long-term storage of sensitive attachments.
5. ADR export history visible via Git PR.

## 10. Deployment Architecture

Backend responsibilities:
- Slack command handling
- Event ingestion
- Canvas creation/editing
- ADR state tracking
- Git integration

Recommended:
- Stateless API service
- Small relational DB
- Queue for Canvas edits / Git export

## 11. MVP Scope

Must Have:
- `/adr start`
- `/adr enable`
- Canvas template creation
- PR export
- Bot-only authentication

Nice to Have:
- Best-effort thread summary
- Guided question prompts
- ADR status tracking

Out of Scope:
- Approval workflows
- Complex governance
- Multi-workspace federation

## 12. Future Enhancements

- Optional user OAuth fallback for better history access
- Decision review workflows
- ADR search and indexing
- Superseding ADR linkage
- Metrics on decision latency

## 13. Summary

This application intentionally does very little. It creates a deliberate workspace for architectural thinking. Its value lies in social signaling, structured collaboration, and traceable decision capture, not automation.
