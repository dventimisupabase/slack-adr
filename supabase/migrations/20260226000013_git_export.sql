-- Step 13: Git Export
-- Markdown renderer and export callback handler.

-- Render ADR to Markdown using the template from 02-adr-template.md
CREATE FUNCTION render_adr_markdown(p_adr_id text) RETURNS text AS $$
DECLARE
  rec adrs;
  md text;
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

  md := md || E'## Slack Thread\n\n';
  md := md || coalesce(rec.slack_thread_link, '_(not linked)_') || E'\n';

  RETURN md;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Update dispatch_side_effects to include markdown in git-export payload
CREATE OR REPLACE FUNCTION dispatch_side_effects(
  req adrs,
  old_state adr_state,
  new_state adr_state,
  event_type adr_event_type
) RETURNS void AS $$
DECLARE
  slack_payload jsonb;
  channel text;
  markdown text;
BEGIN
  -- Check outbox suppression
  IF current_setting('app.suppress_outbox', true) = 'true' THEN
    RETURN;
  END IF;

  channel := coalesce(req.slack_channel_id, req.channel_id);

  CASE event_type
    WHEN 'ADR_CREATED' THEN
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format('*%s: %s*' || E'\n' || 'Status: %s | Created by: <@%s>',
          req.id, req.title, new_state, req.created_by)
      );
      IF req.thread_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.thread_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    WHEN 'ADR_ACCEPTED', 'ADR_REJECTED', 'ADR_SUPERSEDED' THEN
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format('*%s* status changed to *%s*', req.id, new_state)
      );
      IF req.slack_message_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    WHEN 'EXPORT_REQUESTED' THEN
      -- Render markdown and enqueue git export
      markdown := render_adr_markdown(req.id);
      PERFORM enqueue_outbox(req.id, NULL, 'git-export', jsonb_build_object(
        'adr_id', req.id,
        'title', req.title,
        'markdown', markdown
      ));

    WHEN 'EXPORT_COMPLETED' THEN
      IF req.git_pr_url IS NOT NULL THEN
        slack_payload := jsonb_build_object(
          'channel', channel,
          'text', format(':white_check_mark: *%s* exported to Git: %s', req.id, req.git_pr_url)
        );
        IF req.slack_message_ts IS NOT NULL THEN
          slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
        END IF;
        PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);
      END IF;

    WHEN 'EXPORT_FAILED' THEN
      slack_payload := jsonb_build_object(
        'channel', channel,
        'text', format(':x: *%s* export failed. Try again with the Export button.', req.id)
      );
      IF req.slack_message_ts IS NOT NULL THEN
        slack_payload := slack_payload || jsonb_build_object('thread_ts', req.slack_message_ts);
      END IF;
      PERFORM enqueue_outbox(req.id, NULL, 'slack', slack_payload);

    ELSE
      NULL;
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Git export callback handler (called by git-export Edge Function)
CREATE FUNCTION handle_git_export_callback(raw_body text) RETURNS json AS $$
DECLARE
  payload jsonb;
  p_adr_id text;
  p_status text;
  p_pr_url text;
  p_branch text;
  p_error text;
  rec adrs;
BEGIN
  payload := raw_body::jsonb;
  p_adr_id := payload->>'adr_id';
  p_status := payload->>'status';

  IF p_adr_id IS NULL THEN
    RAISE EXCEPTION 'adr_id is required';
  END IF;

  IF p_status = 'complete' THEN
    p_pr_url := payload->>'pr_url';
    p_branch := payload->>'branch';
    rec := apply_adr_event(
      p_adr_id, 'EXPORT_COMPLETED', 'system', 'git-export',
      jsonb_build_object('pr_url', p_pr_url, 'branch', p_branch)
    );
    RETURN json_build_object('ok', true, 'state', rec.state);
  ELSIF p_status = 'failed' THEN
    p_error := payload->>'error';
    rec := apply_adr_event(
      p_adr_id, 'EXPORT_FAILED', 'system', 'git-export',
      jsonb_build_object('error', p_error)
    );
    RETURN json_build_object('ok', true, 'state', rec.state);
  ELSE
    RAISE EXCEPTION 'Invalid status: %', p_status;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
