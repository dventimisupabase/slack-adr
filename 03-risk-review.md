# ADR Slack Bot – Risk Review

## Operational Risks

1. Slack API / Canvas changes
- Mitigation: adapter layer, sandbox tests, fallback modal.

2. Bot not invited / partial history
- Mitigation: fail fast; strong `/adr enable` onboarding copy; optional `/adr status`.

3. Canvas edit conflicts
- Mitigation: sentinel-based section patching; never rewrite entire Canvas; retry.

4. Git export failures
- Mitigation: validate repo config during `/adr enable`; retries; store draft until export succeeds.

5. Token leakage
- Mitigation: encrypted storage (KMS), rotation, strict logging hygiene.

6. Slack rate limits
- Mitigation: queue edits; backoff.

## Privacy & Security Risks

1. Perceived surveillance
- Mitigation: explicit enablement message; clear boundaries; `/adr disable`.

2. Sensitive data in ADRs
- Mitigation: template reminder; optional secret scan before export.

3. LLM exposure (optional)
- Mitigation: opt-in summarization; redaction; internal model if available.

## Adoption Risks

1. Too much friction
- Mitigation: minimal template option; fast Canvas creation; keep bot ceremonial.

2. Cultural resistance
- Mitigation: leadership endorsement; examples; emphasize “engineering memory.”

3. ADR fatigue
- Mitigation: guidance on when ADRs are appropriate; lightweight ADRs.
