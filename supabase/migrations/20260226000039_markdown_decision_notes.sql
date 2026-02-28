-- Step 40: Include decision notes (reasons) in exported markdown
-- Looks up state transition events with reasons from adr_events

CREATE OR REPLACE FUNCTION render_adr_markdown(p_adr_id text) RETURNS text AS $$
DECLARE
  rec adrs;
  md text;
  notes_text text := '';
  evt record;
BEGIN
  SELECT * INTO STRICT rec FROM adrs WHERE id = p_adr_id;

  md := format(E'# %s\n\n', rec.title);
  md := md || format(E'**Status**: %s  \n', rec.state);
  md := md || format(E'**Date**: %s  \n', to_char(rec.created_at, 'YYYY-MM-DD'));
  md := md || format(E'**Authors**: %s  \n\n', rec.created_by);

  md := md || E'## Context\n\n';
  md := md || coalesce(rec.context_text, '_(none)_') || E'\n\n';

  md := md || E'## Decision\n\n';
  md := md || coalesce(rec.decision, '_(none)_') || E'\n\n';

  md := md || E'## Alternatives Considered\n\n';
  md := md || coalesce(rec.alternatives, '_(none)_') || E'\n\n';

  md := md || E'## Consequences\n\n';
  md := md || coalesce(rec.consequences, '_(none)_') || E'\n\n';

  md := md || E'## Decision Drivers\n\n';
  md := md || coalesce(rec.decision_drivers, '_(none)_') || E'\n\n';

  md := md || E'## Open Questions\n\n';
  md := md || coalesce(rec.open_questions, '_(none)_') || E'\n\n';

  md := md || E'## Implementation Plan\n\n';
  md := md || coalesce(rec.implementation_plan, '_(none)_') || E'\n\n';

  md := md || E'## Reviewers\n\n';
  md := md || coalesce(rec.reviewers, '_(none)_') || E'\n\n';

  -- Decision Notes: reasons from state transition events
  FOR evt IN
    SELECT e.event_type, e.actor_id, e.created_at, e.payload->>'reason' AS reason
    FROM adr_events e
    WHERE e.adr_id = p_adr_id
      AND e.payload->>'reason' IS NOT NULL
    ORDER BY e.created_at ASC
  LOOP
    notes_text := notes_text || format(E'- **%s** by %s (%s): %s\n',
      replace(lower(evt.event_type::text), '_', ' '),
      evt.actor_id,
      to_char(evt.created_at, 'YYYY-MM-DD'),
      evt.reason
    );
  END LOOP;

  IF notes_text != '' THEN
    md := md || E'## Decision Notes\n\n';
    md := md || notes_text || E'\n';
  END IF;

  md := md || E'## Slack Thread\n\n';
  md := md || coalesce(rec.slack_thread_link, '_(not linked)_') || E'\n';

  RETURN md;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
