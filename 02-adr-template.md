# ADR Canvas Template (Standard)

## Title
Short name for the decision.

Prompt: State the decision in one sentence.  
Example: “Adopt Postgres logical replication for cross-region failover.”

## Status
Draft | Accepted | Superseded | Rejected

Prompt: Current lifecycle state. Change to “Accepted” after review.  
Example: Draft

## Context
Prompt: Describe the problem and relevant constraints. Include scale, timeline, and stakeholders. Avoid opinions here.

Checklist:
- What problem are we solving?
- What constraints exist (time, cost, compliance, tech debt)?
- What prior decisions affect this?

Example:
“We need cross-region failover within 5 minutes RTO. Current primary is single-region. We cannot introduce vendor lock-in due to contract requirements. Team capacity is two engineers for one quarter.”

## Decision
Prompt: State exactly what will be done. Use imperative language. Include scope and non-scope.

Checklist:
- What are we doing?
- Where will it apply?
- What is explicitly out of scope?

Example:
“We will implement Postgres logical replication from us-east-1 to us-west-2 for the customer-facing database. This applies to production only. We will not replicate analytics workloads.”

## Alternatives Considered
Prompt: List realistic alternatives and why they were rejected.

Example:
1. Multi-master database — rejected due to consistency risk.
2. Vendor managed failover — rejected due to lock-in concerns.
3. Snapshot restore — rejected due to 30-minute RTO.

## Consequences
Prompt: Describe expected benefits and costs. Include operational impact.

Example:
Positive: RTO reduced to <5 minutes.  
Negative: Increased replication lag monitoring.  
Risk: Replication slot exhaustion.  
Follow-up: Add replication health dashboard.

## Open Questions
Prompt: List unresolved issues blocking acceptance.

Example:
- Do we need read replicas in both regions?
- How will schema migrations propagate?

## Decision Drivers
Prompt: Key factors influencing the decision.

Example:
- Required RTO
- Vendor neutrality
- Limited engineering capacity

## Implementation Plan
Prompt: High-level steps only.

Example:
1. Provision replica region.
2. Configure logical replication.
3. Run failover test.
4. Update runbooks.

## Reviewers
Prompt: People responsible for approving or challenging the decision.

Example:
Platform Lead, SRE Manager, Security Reviewer

## Slack Thread Link
Prompt: Permalink to originating conversation.
