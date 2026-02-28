-- Step 35: Interactive delete button for DRAFT ADRs
-- 1. Add delete_adr button to DRAFT state in build_adr_block_kit
-- 2. Handle delete_adr action in handle_interactive_payload

-- 1. Rewrite build_adr_block_kit to include Delete button for DRAFT
CREATE OR REPLACE FUNCTION build_adr_block_kit(
  req adrs,
  p_event_type adr_event_type DEFAULT NULL,
  p_actor_id text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  blocks jsonb := '[]'::jsonb;
  actions jsonb := '[]'::jsonb;
  result jsonb;
  truncated text;
BEGIN
  IF req.slack_channel_id IS NULL AND req.channel_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Header
  blocks := blocks || jsonb_build_array(jsonb_build_object(
    'type', 'header',
    'text', jsonb_build_object(
      'type', 'plain_text',
      'text', format('%s: %s', req.id, req.title)
    )
  ));

  -- Fields: State, Created By, Date
  blocks := blocks || jsonb_build_array(jsonb_build_object(
    'type', 'section',
    'fields', jsonb_build_array(
      jsonb_build_object('type', 'mrkdwn', 'text', format('*State:* %s', req.state)),
      jsonb_build_object('type', 'mrkdwn', 'text', format('*Created by:* <@%s>', req.created_by)),
      jsonb_build_object('type', 'mrkdwn', 'text', format('*Date:* %s', to_char(req.created_at, 'YYYY-MM-DD')))
    )
  ));

  -- Context section
  IF req.context_text IS NOT NULL AND req.context_text != '' THEN
    truncated := left(req.context_text, 300);
    IF length(req.context_text) > 300 THEN truncated := truncated || '...'; END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Context:* %s', truncated))
    ));
  END IF;

  -- Decision section
  IF req.decision IS NOT NULL AND req.decision != '' THEN
    truncated := left(req.decision, 300);
    IF length(req.decision) > 300 THEN truncated := truncated || '...'; END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Decision:* %s', truncated))
    ));
  END IF;

  -- Alternatives
  IF req.alternatives IS NOT NULL AND req.alternatives != '' THEN
    truncated := left(req.alternatives, 200);
    IF length(req.alternatives) > 200 THEN truncated := truncated || '...'; END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Alternatives:* %s', truncated))
    ));
  END IF;

  -- Consequences
  IF req.consequences IS NOT NULL AND req.consequences != '' THEN
    truncated := left(req.consequences, 200);
    IF length(req.consequences) > 200 THEN truncated := truncated || '...'; END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Consequences:* %s', truncated))
    ));
  END IF;

  -- Decision Drivers
  IF req.decision_drivers IS NOT NULL AND req.decision_drivers != '' THEN
    truncated := left(req.decision_drivers, 200);
    IF length(req.decision_drivers) > 200 THEN truncated := truncated || '...'; END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Decision Drivers:* %s', truncated))
    ));
  END IF;

  -- Open Questions
  IF req.open_questions IS NOT NULL AND req.open_questions != '' THEN
    truncated := left(req.open_questions, 200);
    IF length(req.open_questions) > 200 THEN truncated := truncated || '...'; END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Open Questions:* %s', truncated))
    ));
  END IF;

  -- Implementation Plan
  IF req.implementation_plan IS NOT NULL AND req.implementation_plan != '' THEN
    truncated := left(req.implementation_plan, 200);
    IF length(req.implementation_plan) > 200 THEN truncated := truncated || '...'; END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Implementation Plan:* %s', truncated))
    ));
  END IF;

  -- Reviewers
  IF req.reviewers IS NOT NULL AND req.reviewers != '' THEN
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Reviewers:* %s', req.reviewers))
    ));
  END IF;

  -- PR link section
  IF req.git_pr_url IS NOT NULL THEN
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format(':link: *Pull Request:* <%s|View PR>', req.git_pr_url))
    ));
  END IF;

  -- Context line: who acted and when (omitted for /adr view)
  IF p_event_type IS NOT NULL AND p_actor_id IS NOT NULL THEN
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'context',
      'elements', jsonb_build_array(jsonb_build_object(
        'type', 'mrkdwn',
        'text', format('<@%s> %s • %s',
          p_actor_id,
          replace(lower(p_event_type::text), '_', ' '),
          to_char(now(), 'YYYY-MM-DD HH24:MI')
        )
      ))
    ));
  END IF;

  -- Divider
  blocks := blocks || jsonb_build_array(jsonb_build_object('type', 'divider'));

  -- Contextual action buttons based on state
  CASE req.state
    WHEN 'DRAFT' THEN
      actions := jsonb_build_array(
        jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Edit'),
          'action_id', 'edit_adr', 'value', req.id
        ),
        jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Accept'),
          'action_id', 'accept_adr', 'value', req.id,
          'style', 'primary'
        ),
        jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Reject'),
          'action_id', 'reject_adr', 'value', req.id,
          'style', 'danger'
        ),
        jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Export to Git'),
          'action_id', 'export_adr', 'value', req.id
        ),
        jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Delete'),
          'action_id', 'delete_adr', 'value', req.id,
          'confirm', jsonb_build_object(
            'title', jsonb_build_object('type', 'plain_text', 'text', 'Delete ADR?'),
            'text', jsonb_build_object('type', 'plain_text', 'text', 'This will permanently delete this ADR. This cannot be undone.'),
            'confirm', jsonb_build_object('type', 'plain_text', 'text', 'Delete'),
            'deny', jsonb_build_object('type', 'plain_text', 'text', 'Cancel')
          )
        )
      );
    WHEN 'ACCEPTED' THEN
      actions := jsonb_build_array(
        jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Edit'),
          'action_id', 'edit_adr', 'value', req.id
        ),
        jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Supersede'),
          'action_id', 'supersede_adr', 'value', req.id,
          'style', 'danger'
        )
      );
      IF req.git_pr_url IS NULL THEN
        actions := actions || jsonb_build_array(jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Export to Git'),
          'action_id', 'export_adr', 'value', req.id
        ));
      END IF;
    ELSE
      -- REJECTED, SUPERSEDED — no action buttons
      actions := '[]'::jsonb;
  END CASE;

  -- Only add actions block if there are buttons
  IF jsonb_array_length(actions) > 0 THEN
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'actions',
      'elements', actions
    ));
  END IF;

  RETURN jsonb_build_object('blocks', blocks);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 2. Rewrite handle_interactive_payload to include delete_adr action
CREATE OR REPLACE FUNCTION handle_interactive_payload(payload jsonb) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  action_id text;
  adr_id text;
  user_id text;
  team_id text;
  target_adr adrs;
  rec adrs;
  bk jsonb;
BEGIN
  -- Extract action info
  action_id := payload->'actions'->0->>'action_id';
  adr_id := payload->'actions'->0->>'value';
  user_id := payload->'user'->>'id';
  team_id := coalesce(payload->'team'->>'id', payload->>'team_id');

  IF action_id IS NULL THEN
    RETURN json_build_object('text', 'Unknown action.');
  END IF;

  -- For modal-opening actions, no team ownership check needed (Edge Function handles)
  IF action_id IN ('edit_adr', 'start_adr_from_mention') THEN
    RETURN json_build_object('response_type', 'ephemeral', 'text', 'Opening form...');
  END IF;

  -- Require both adr_id and team_id for state-changing actions
  IF adr_id IS NULL THEN
    RETURN json_build_object('text', 'Missing ADR ID.');
  END IF;

  -- Verify team ownership before any state-changing action
  SELECT * INTO target_adr FROM adrs a
  WHERE a.id = adr_id
    AND a.team_id = team_id;

  IF NOT FOUND THEN
    RETURN json_build_object('text', format('ADR `%s` not found.', adr_id));
  END IF;

  -- Handle delete separately (different flow — no event, just delete)
  IF action_id = 'delete_adr' THEN
    IF target_adr.state != 'DRAFT' THEN
      RETURN json_build_object(
        'replace_original', false,
        'text', format('Cannot delete *%s* — only DRAFT ADRs can be deleted. This ADR is %s.', target_adr.id, target_adr.state)
      );
    END IF;
    DELETE FROM adr_outbox WHERE adr_id = target_adr.id;
    DELETE FROM adr_events WHERE adr_id = target_adr.id;
    DELETE FROM adrs WHERE id = target_adr.id;
    RETURN json_build_object(
      'replace_original', true,
      'text', format('Deleted *%s: %s*. This action cannot be undone.', target_adr.id, target_adr.title)
    );
  END IF;

  -- Suppress outbox for interactive actions (response_url handles the update)
  PERFORM set_config('app.suppress_outbox', 'true', true);

  CASE action_id
    WHEN 'accept_adr' THEN
      rec := apply_adr_event(target_adr.id, 'ADR_ACCEPTED', 'user', user_id);
    WHEN 'reject_adr' THEN
      rec := apply_adr_event(target_adr.id, 'ADR_REJECTED', 'user', user_id);
    WHEN 'supersede_adr' THEN
      rec := apply_adr_event(target_adr.id, 'ADR_SUPERSEDED', 'user', user_id);
    WHEN 'export_adr' THEN
      -- Don't suppress outbox for export (it needs the git-export outbox row)
      PERFORM set_config('app.suppress_outbox', 'false', true);
      rec := apply_adr_event(target_adr.id, 'EXPORT_REQUESTED', 'user', user_id);
    ELSE
      RETURN json_build_object('text', format('Unknown action: %s', action_id));
  END CASE;

  -- Clear suppress flag
  PERFORM set_config('app.suppress_outbox', 'false', true);

  -- Return updated Block Kit for response_url
  bk := build_adr_block_kit(rec, NULL, user_id);
  IF bk IS NOT NULL THEN
    RETURN json_build_object(
      'replace_original', true,
      'blocks', bk->'blocks'
    );
  END IF;

  RETURN json_build_object(
    'replace_original', true,
    'text', format('*%s* updated to *%s*', rec.id, rec.state)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
