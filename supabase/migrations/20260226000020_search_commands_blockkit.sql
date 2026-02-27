-- Step 20: /adr search, /adr supersede, /adr reject, expanded Block Kit, statement_timeout
-- 1. build_adr_search: ILIKE on title + context_text
-- 2. handle_slack_webhook: add search, reject, supersede commands + statement_timeout
-- 3. build_adr_block_kit: show remaining ADR fields when populated
-- 4. handle_slack_event, handle_slack_modal_submission: add statement_timeout

-- 1. Search helper: ILIKE on title and context_text
CREATE FUNCTION build_adr_search(p_team_id text, p_channel_id text, p_query text)
RETURNS json AS $$
DECLARE
  results text := '';
  r record;
  cnt int := 0;
BEGIN
  FOR r IN
    SELECT id, title, state FROM adrs
    WHERE team_id = p_team_id
      AND channel_id = p_channel_id
      AND (title ILIKE '%' || p_query || '%'
           OR context_text ILIKE '%' || p_query || '%')
    ORDER BY created_at DESC
    LIMIT 10
  LOOP
    cnt := cnt + 1;
    results := results || format('• `%s` [%s] %s', r.id, r.state, r.title) || E'\n';
  END LOOP;

  IF cnt = 0 THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('No ADRs found matching "%s" in this channel.', p_query)
    );
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', format('*Found %s ADR(s) matching "%s":*', cnt, p_query) || E'\n' || results
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 2. Rewrite handle_slack_webhook with new commands and statement_timeout
CREATE OR REPLACE FUNCTION handle_slack_webhook(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  headers json;
  sig text;
  ts text;
  params json;
  command_text text;
  subcommand text;
  subcommand_arg text;
  team_id text;
  channel_id text;
  user_id text;
  payload jsonb;
  rec adrs;
  bk jsonb;
BEGIN
  -- Guard against slow queries hitting Slack's 3-second deadline
  SET LOCAL statement_timeout = '2900ms';

  -- Read signature headers
  headers := current_setting('request.headers', true)::json;
  sig := headers->>'x-slack-signature';
  ts := headers->>'x-slack-request-timestamp';

  -- Check if this is an interactive payload (JSON wrapped in form encoding)
  IF raw_body LIKE 'payload=%' THEN
    payload := url_decode(split_part(raw_body, 'payload=', 2))::jsonb;

    IF NOT verify_slack_signature(raw_body, ts, sig) THEN
      RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
    END IF;

    RETURN handle_interactive_payload(payload);
  END IF;

  -- Parse form-encoded slash command
  params := parse_form_body(raw_body);

  IF NOT verify_slack_signature(raw_body, ts, sig) THEN
    RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
  END IF;

  command_text := coalesce(trim(params->>'text'), '');
  team_id := params->>'team_id';
  channel_id := params->>'channel_id';
  user_id := params->>'user_id';

  -- Extract subcommand (first word) and argument (rest)
  subcommand := split_part(command_text, ' ', 1);
  subcommand_arg := trim(substring(command_text FROM length(subcommand) + 1));

  CASE subcommand
    WHEN 'start' THEN
      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', 'Opening ADR drafting form...'
      );

    WHEN 'enable' THEN
      INSERT INTO channel_config (team_id, channel_id, enabled)
      VALUES (team_id, channel_id, true)
      ON CONFLICT ON CONSTRAINT channel_config_pkey
      DO UPDATE SET enabled = true;

      RETURN json_build_object(
        'response_type', 'in_channel',
        'text', ':white_check_mark: *ADR Bot enabled in this channel.*'
          || E'\n\n'
          || 'I will listen for `/adr start` commands and `@adr` mentions to help you draft Architectural Decision Records.'
          || E'\n\n'
          || '*What I can see:* Only messages in this channel after I was invited.'
          || E'\n'
          || '*What I do:* Create structured ADR drafts and export them to Git as pull requests.'
          || E'\n'
          || '*To disable:* Run `/adr disable`'
      );

    WHEN 'disable' THEN
      UPDATE channel_config cc SET enabled = false
      WHERE cc.team_id = team_id
        AND cc.channel_id = channel_id;

      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', 'ADR Bot disabled in this channel. Run `/adr enable` to re-enable.'
      );

    WHEN 'list' THEN
      RETURN build_adr_list(team_id, channel_id);

    WHEN 'view' THEN
      RETURN build_adr_view(team_id, subcommand_arg);

    WHEN 'search' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr search <query>` — search ADRs by title or context'
        );
      END IF;
      RETURN build_adr_search(team_id, channel_id, subcommand_arg);

    WHEN 'reject' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr reject <ADR-ID>` — reject an ADR'
        );
      END IF;
      BEGIN
        PERFORM set_config('app.suppress_outbox', 'true', true);
        rec := apply_adr_event(upper(trim(subcommand_arg)), 'ADR_REJECTED', 'user', user_id);
        PERFORM set_config('app.suppress_outbox', 'false', true);
        bk := build_adr_block_kit(rec, 'ADR_REJECTED'::adr_event_type, user_id);
        IF bk IS NOT NULL THEN
          RETURN json_build_object('response_type', 'ephemeral', 'blocks', bk->'blocks');
        END IF;
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('*%s* has been *REJECTED*.', rec.id));
      EXCEPTION WHEN OTHERS THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('Error: %s', sqlerrm));
      END;

    WHEN 'supersede' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr supersede <ADR-ID>` — supersede an accepted ADR'
        );
      END IF;
      BEGIN
        PERFORM set_config('app.suppress_outbox', 'true', true);
        rec := apply_adr_event(upper(trim(subcommand_arg)), 'ADR_SUPERSEDED', 'user', user_id);
        PERFORM set_config('app.suppress_outbox', 'false', true);
        bk := build_adr_block_kit(rec, 'ADR_SUPERSEDED'::adr_event_type, user_id);
        IF bk IS NOT NULL THEN
          RETURN json_build_object('response_type', 'ephemeral', 'blocks', bk->'blocks');
        END IF;
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('*%s* has been *SUPERSEDED*.', rec.id));
      EXCEPTION WHEN OTHERS THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('Error: %s', sqlerrm));
      END;

    ELSE
      -- help or unknown command
      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', '*ADR Bot Commands:*'
          || E'\n'
          || '`/adr start` — Open a form to draft a new ADR'
          || E'\n'
          || '`/adr enable` — Enable ADR Bot in this channel'
          || E'\n'
          || '`/adr disable` — Disable ADR Bot in this channel'
          || E'\n'
          || '`/adr list` — List ADRs in this channel'
          || E'\n'
          || '`/adr view <id>` — View an ADR'
          || E'\n'
          || '`/adr search <query>` — Search ADRs by title or context'
          || E'\n'
          || '`/adr reject <id>` — Reject a draft ADR'
          || E'\n'
          || '`/adr supersede <id>` — Supersede an accepted ADR'
          || E'\n'
          || '`/adr help` — Show this help message'
      );
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Expand Block Kit with remaining ADR fields
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

-- 4. Add statement_timeout to handle_slack_event
CREATE OR REPLACE FUNCTION handle_slack_event(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  payload jsonb;
  event_type text;
  event jsonb;
  team_id text;
  channel text;
  thread_ts text;
  user_id text;
  is_enabled boolean;
BEGIN
  -- Guard against slow queries hitting Slack's 3-second deadline
  SET LOCAL statement_timeout = '2900ms';

  payload := raw_body::jsonb;

  -- URL verification challenge
  IF payload->>'type' = 'url_verification' THEN
    RETURN json_build_object('challenge', payload->>'challenge');
  END IF;

  -- Verify signature
  DECLARE
    headers json := current_setting('request.headers', true)::json;
    sig text := headers->>'x-slack-signature';
    ts text := headers->>'x-slack-request-timestamp';
  BEGIN
    IF sig IS NOT NULL AND sig != '' THEN
      IF NOT verify_slack_signature(raw_body, ts, sig) THEN
        RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
      END IF;
    END IF;
  END;

  IF payload->>'type' != 'event_callback' THEN
    RETURN json_build_object('ok', true);
  END IF;

  team_id := payload->>'team_id';
  event := payload->'event';
  event_type := event->>'type';

  IF event_type = 'app_mention' THEN
    channel := event->>'channel';
    thread_ts := coalesce(event->>'thread_ts', event->>'ts');
    user_id := event->>'user';

    SELECT cc.enabled INTO is_enabled FROM channel_config cc
    WHERE cc.channel_id = channel AND cc.team_id = team_id
    LIMIT 1;

    IF coalesce(is_enabled, false) = false THEN
      RETURN json_build_object('ok', true);
    END IF;

    PERFORM enqueue_outbox(
      p_adr_id := NULL,
      p_event_id := NULL,
      p_destination := 'slack',
      p_payload := jsonb_build_object(
        'channel', channel,
        'thread_ts', thread_ts,
        'text', 'Ready to start an ADR?',
        'blocks', jsonb_build_array(
          jsonb_build_object(
            'type', 'section',
            'text', jsonb_build_object(
              'type', 'mrkdwn',
              'text', 'Ready to start an ADR? Click the button below to open the drafting form.'
            )
          ),
          jsonb_build_object(
            'type', 'actions',
            'elements', jsonb_build_array(
              jsonb_build_object(
                'type', 'button',
                'text', jsonb_build_object('type', 'plain_text', 'text', 'Start ADR'),
                'action_id', 'start_adr_from_mention',
                'value', channel || '|' || thread_ts,
                'style', 'primary'
              )
            )
          )
        )
      )
    );
  END IF;

  RETURN json_build_object('ok', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Add statement_timeout to handle_slack_modal_submission
-- (latest version is from migration 18 — preserve full logic)
CREATE OR REPLACE FUNCTION handle_slack_modal_submission(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  payload jsonb;
  user_id text;
  private_metadata text;
  meta_parts text[];
  channel_id text;
  thread_ts text;
  adr_id text;
  vals jsonb;
  p_title text;
  p_context text;
  p_decision text;
  p_alternatives text;
  p_consequences text;
  p_open_questions text;
  p_decision_drivers text;
  p_implementation_plan text;
  p_reviewers text;
  errors jsonb := '{}'::jsonb;
  rec adrs;
  update_payload jsonb;
  looked_up_team_id text;
BEGIN
  -- Guard against slow queries
  SET LOCAL statement_timeout = '2900ms';

  payload := raw_body::jsonb;

  user_id := payload->'user'->>'id';
  private_metadata := payload->'view'->>'private_metadata';

  meta_parts := string_to_array(private_metadata, '|');
  channel_id := meta_parts[1];
  thread_ts := NULLIF(meta_parts[2], '');
  adr_id := NULLIF(meta_parts[3], '');

  vals := payload->'view'->'state'->'values';

  p_title := vals->'title_block'->'title_input'->>'value';
  p_context := vals->'context_block'->'context_input'->>'value';
  p_decision := vals->'decision_block'->'decision_input'->>'value';
  p_alternatives := vals->'alternatives_block'->'alternatives_input'->>'value';
  p_consequences := vals->'consequences_block'->'consequences_input'->>'value';
  p_open_questions := vals->'open_questions_block'->'open_questions_input'->>'value';
  p_decision_drivers := vals->'decision_drivers_block'->'decision_drivers_input'->>'value';
  p_implementation_plan := vals->'implementation_plan_block'->'implementation_plan_input'->>'value';
  p_reviewers := vals->'reviewers_block'->'reviewers_input'->>'value';

  -- Validate required fields
  IF p_title IS NULL OR trim(p_title) = '' THEN
    errors := errors || jsonb_build_object('title_block', 'Title is required');
  END IF;
  IF p_context IS NULL OR trim(p_context) = '' THEN
    errors := errors || jsonb_build_object('context_block', 'Context is required');
  END IF;

  IF errors != '{}'::jsonb THEN
    RETURN json_build_object('response_action', 'errors', 'errors', errors);
  END IF;

  IF adr_id IS NOT NULL AND adr_id != '' THEN
    update_payload := jsonb_build_object(
      'title', p_title,
      'context_text', p_context,
      'decision', p_decision,
      'alternatives', p_alternatives,
      'consequences', p_consequences,
      'open_questions', p_open_questions,
      'decision_drivers', p_decision_drivers,
      'implementation_plan', p_implementation_plan,
      'reviewers', p_reviewers
    );
    rec := apply_adr_event(adr_id, 'ADR_UPDATED', 'user', user_id, update_payload);
  ELSE
    -- Look up team_id from channel_config
    SELECT cc.team_id INTO looked_up_team_id
    FROM channel_config cc WHERE cc.channel_id = channel_id LIMIT 1;

    -- Reject if channel has no config (would create orphaned ADR)
    IF looked_up_team_id IS NULL THEN
      RETURN json_build_object(
        'response_action', 'errors',
        'errors', jsonb_build_object(
          'title_block',
          'ADR Bot is not enabled in this channel. Run /adr enable first.'
        )
      );
    END IF;

    rec := create_adr(
      p_team_id := looked_up_team_id,
      p_channel_id := channel_id,
      p_created_by := user_id,
      p_title := p_title,
      p_context_text := p_context,
      p_decision := p_decision,
      p_alternatives := p_alternatives,
      p_consequences := p_consequences,
      p_open_questions := p_open_questions,
      p_decision_drivers := p_decision_drivers,
      p_implementation_plan := p_implementation_plan,
      p_reviewers := p_reviewers,
      p_thread_ts := thread_ts
    );
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
