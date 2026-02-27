-- Step 7: Block Kit Messages
-- Build structured Slack Block Kit payloads from ADR state.

CREATE FUNCTION build_adr_block_kit(
  req adrs,
  p_event_type adr_event_type DEFAULT NULL,
  p_actor_id text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  blocks jsonb := '[]'::jsonb;
  actions jsonb := '[]'::jsonb;
  result jsonb;
  context_truncated text;
  decision_truncated text;
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

  -- Context section (truncated)
  IF req.context_text IS NOT NULL AND req.context_text != '' THEN
    context_truncated := left(req.context_text, 300);
    IF length(req.context_text) > 300 THEN
      context_truncated := context_truncated || '...';
    END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Context:* %s', context_truncated))
    ));
  END IF;

  -- Decision section (truncated)
  IF req.decision IS NOT NULL AND req.decision != '' THEN
    decision_truncated := left(req.decision, 300);
    IF length(req.decision) > 300 THEN
      decision_truncated := decision_truncated || '...';
    END IF;
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'section',
      'text', jsonb_build_object('type', 'mrkdwn', 'text', format('*Decision:* %s', decision_truncated))
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
      -- Add export button if no PR yet
      IF req.git_pr_url IS NULL THEN
        actions := actions || jsonb_build_array(jsonb_build_object(
          'type', 'button', 'text', jsonb_build_object('type', 'plain_text', 'text', 'Export to Git'),
          'action_id', 'export_adr', 'value', req.id
        ));
      END IF;
    ELSE
      -- REJECTED, SUPERSEDED: no action buttons
      NULL;
  END CASE;

  IF jsonb_array_length(actions) > 0 THEN
    blocks := blocks || jsonb_build_array(jsonb_build_object(
      'type', 'actions',
      'elements', actions
    ));
  END IF;

  result := jsonb_build_object('blocks', blocks);
  RETURN result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
