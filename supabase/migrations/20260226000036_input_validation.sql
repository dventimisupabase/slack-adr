-- Step 36: Input validation and UX improvements
-- 1. Modal field length limits (title ≤ 200, other fields ≤ 3000)
-- 2. Unknown subcommand "did you mean?" hints
-- 3. Better error messages

-- Helper: Levenshtein-like distance for short strings (simple approach)
-- Uses pg_trgm similarity for fuzzy matching
CREATE OR REPLACE FUNCTION suggest_command(input text) RETURNS text AS $$
DECLARE
  commands text[] := ARRAY['start','enable','disable','list','view','search','history','stats','health','export','accept','reject','supersede','delete','help'];
  cmd text;
  best_match text := NULL;
  best_score float := 0;
  score float;
BEGIN
  IF input IS NULL OR input = '' THEN
    RETURN NULL;
  END IF;

  FOREACH cmd IN ARRAY commands LOOP
    -- Simple similarity: count matching characters at start
    score := 0;
    FOR i IN 1..least(length(input), length(cmd)) LOOP
      IF substr(input, i, 1) = substr(cmd, i, 1) THEN
        score := score + 1;
      END IF;
    END LOOP;
    -- Normalize by max length and penalize length difference
    score := score / greatest(length(input), length(cmd));
    -- Boost if first letter matches
    IF substr(input, 1, 1) = substr(cmd, 1, 1) THEN
      score := score + 0.3;
    END IF;
    -- Boost if contains the command or vice versa
    IF input LIKE '%' || cmd || '%' OR cmd LIKE '%' || input || '%' THEN
      score := score + 0.5;
    END IF;

    IF score > best_score THEN
      best_score := score;
      best_match := cmd;
    END IF;
  END LOOP;

  -- Only suggest if reasonably similar (threshold)
  IF best_score >= 0.5 AND best_match != input THEN
    RETURN best_match;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Rewrite handle_slack_modal_submission with length validation
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
  MAX_TITLE_LEN int := 200;
  MAX_FIELD_LEN int := 3000;
BEGIN
  SET LOCAL statement_timeout = '2900ms';

  payload := raw_body::jsonb;

  user_id := payload->'user'->>'id';
  private_metadata := payload->'view'->>'private_metadata';

  meta_parts := string_to_array(private_metadata, '|');
  channel_id := meta_parts[1];
  thread_ts := NULLIF(meta_parts[2], '');
  adr_id := NULLIF(meta_parts[3], '');

  vals := payload->'view'->'state'->'values';

  IF vals IS NULL THEN
    RETURN json_build_object(
      'response_action', 'errors',
      'errors', jsonb_build_object(
        'title_block', 'Form submission incomplete. Please try again.'
      )
    );
  END IF;

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
  ELSIF length(p_title) > MAX_TITLE_LEN THEN
    errors := errors || jsonb_build_object('title_block', format('Title must be %s characters or fewer (currently %s)', MAX_TITLE_LEN, length(p_title)));
  END IF;

  IF p_context IS NULL OR trim(p_context) = '' THEN
    errors := errors || jsonb_build_object('context_block', 'Context is required');
  ELSIF length(p_context) > MAX_FIELD_LEN THEN
    errors := errors || jsonb_build_object('context_block', format('Context must be %s characters or fewer (currently %s)', MAX_FIELD_LEN, length(p_context)));
  END IF;

  -- Validate optional field lengths
  IF p_decision IS NOT NULL AND length(p_decision) > MAX_FIELD_LEN THEN
    errors := errors || jsonb_build_object('decision_block', format('Decision must be %s characters or fewer', MAX_FIELD_LEN));
  END IF;
  IF p_alternatives IS NOT NULL AND length(p_alternatives) > MAX_FIELD_LEN THEN
    errors := errors || jsonb_build_object('alternatives_block', format('Alternatives must be %s characters or fewer', MAX_FIELD_LEN));
  END IF;
  IF p_consequences IS NOT NULL AND length(p_consequences) > MAX_FIELD_LEN THEN
    errors := errors || jsonb_build_object('consequences_block', format('Consequences must be %s characters or fewer', MAX_FIELD_LEN));
  END IF;
  IF p_open_questions IS NOT NULL AND length(p_open_questions) > MAX_FIELD_LEN THEN
    errors := errors || jsonb_build_object('open_questions_block', format('Open Questions must be %s characters or fewer', MAX_FIELD_LEN));
  END IF;
  IF p_decision_drivers IS NOT NULL AND length(p_decision_drivers) > MAX_FIELD_LEN THEN
    errors := errors || jsonb_build_object('decision_drivers_block', format('Decision Drivers must be %s characters or fewer', MAX_FIELD_LEN));
  END IF;
  IF p_implementation_plan IS NOT NULL AND length(p_implementation_plan) > MAX_FIELD_LEN THEN
    errors := errors || jsonb_build_object('implementation_plan_block', format('Implementation Plan must be %s characters or fewer', MAX_FIELD_LEN));
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
    SELECT cc.team_id INTO looked_up_team_id
    FROM channel_config cc WHERE cc.channel_id = channel_id LIMIT 1;

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
      p_thread_ts := thread_ts,
      p_decision := p_decision,
      p_alternatives := p_alternatives,
      p_consequences := p_consequences,
      p_open_questions := p_open_questions,
      p_decision_drivers := p_decision_drivers,
      p_implementation_plan := p_implementation_plan,
      p_reviewers := p_reviewers
    );
  END IF;

  RETURN NULL; -- Close modal
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Rewrite handle_slack_webhook with "did you mean" hints
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
  parsed_remaining text;
  parsed_page int;
  target_adr adrs;
  rec adrs;
  suggestion text;
BEGIN
  SET LOCAL statement_timeout = '2900ms';

  headers := current_setting('request.headers', true)::json;
  sig := headers->>'x-slack-signature';
  ts := headers->>'x-slack-request-timestamp';

  IF raw_body LIKE 'payload=%' THEN
    payload := url_decode(split_part(raw_body, 'payload=', 2))::jsonb;
    IF NOT verify_slack_signature(raw_body, ts, sig) THEN
      RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
    END IF;
    RETURN handle_interactive_payload(payload);
  END IF;

  params := parse_form_body(raw_body);
  IF NOT verify_slack_signature(raw_body, ts, sig) THEN
    RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
  END IF;

  command_text := coalesce(trim(params->>'text'), '');
  team_id := params->>'team_id';
  channel_id := params->>'channel_id';
  user_id := params->>'user_id';

  IF NOT check_rate_limit(team_id, 'slash_command') THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', 'You''re sending too many commands. Please slow down and try again in a minute.'
    );
  END IF;

  subcommand := split_part(command_text, ' ', 1);
  subcommand_arg := trim(substring(command_text FROM length(subcommand) + 1));

  CASE subcommand
    WHEN 'start' THEN
      RETURN json_build_object('response_type', 'ephemeral', 'text', 'Opening ADR drafting form...');

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
      WHERE cc.team_id = team_id AND cc.channel_id = channel_id;
      RETURN json_build_object('response_type', 'ephemeral',
        'text', 'ADR Bot disabled in this channel. Run `/adr enable` to re-enable.');

    WHEN 'list' THEN
      SELECT * INTO parsed_remaining, parsed_page FROM extract_page_number(subcommand_arg);
      IF parsed_remaining = '' THEN
        RETURN build_adr_list(team_id, channel_id, NULL, parsed_page);
      ELSE
        RETURN build_adr_list(team_id, channel_id, parsed_remaining, parsed_page);
      END IF;

    WHEN 'view' THEN
      RETURN build_adr_view(team_id, subcommand_arg);

    WHEN 'search' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', 'Usage: `/adr search <query>` — search ADRs by title or context');
      END IF;
      SELECT * INTO parsed_remaining, parsed_page FROM extract_page_number(subcommand_arg);
      IF parsed_remaining = '' THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', 'Usage: `/adr search <query>` — search ADRs by title or context');
      END IF;
      RETURN build_adr_search(team_id, channel_id, parsed_remaining, parsed_page);

    WHEN 'stats' THEN
      RETURN build_adr_stats(team_id);

    WHEN 'history' THEN
      RETURN build_adr_history(team_id, subcommand_arg);

    WHEN 'delete' THEN
      RETURN execute_slash_delete(team_id, user_id, subcommand_arg);

    WHEN 'accept' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_ACCEPTED', 'accept');

    WHEN 'reject' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_REJECTED', 'reject');

    WHEN 'supersede' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_SUPERSEDED', 'supersede');

    WHEN 'export' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', 'Usage: `/adr export <ADR-ID>` — export an ADR to GitHub as a pull request');
      END IF;
      SELECT * INTO target_adr FROM adrs a
      WHERE a.id = upper(trim(subcommand_arg)) AND a.team_id = team_id;
      IF NOT FOUND THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('ADR `%s` not found.', subcommand_arg));
      END IF;
      BEGIN
        rec := apply_adr_event(target_adr.id, 'EXPORT_REQUESTED', 'user', user_id);
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('Export started for *%s: %s*. A pull request will be created shortly.', rec.id, rec.title));
      EXCEPTION WHEN OTHERS THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('Error: %s', sqlerrm));
      END;

    WHEN 'health' THEN
      RETURN build_system_health();

    ELSE
      -- Check for typos and suggest similar command
      suggestion := suggest_command(subcommand);
      IF suggestion IS NOT NULL THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', format('Unknown command `%s`. Did you mean `/adr %s`?', subcommand, suggestion)
            || E'\n\n'
            || 'Run `/adr help` to see all available commands.'
        );
      END IF;

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
          || '`/adr list [state] [page N]` — List ADRs (filter: draft, accepted, rejected, superseded)'
          || E'\n'
          || '`/adr view <id>` — View an ADR'
          || E'\n'
          || '`/adr search <query> [page N]` — Search ADRs by title or context'
          || E'\n'
          || '`/adr history <id>` — View the event audit trail for an ADR'
          || E'\n'
          || '`/adr stats` — Show ADR counts by state'
          || E'\n'
          || '`/adr health` — Show system health (outbox, dead letters)'
          || E'\n'
          || '`/adr export <id>` — Export an ADR to GitHub as a pull request'
          || E'\n'
          || '`/adr accept <id>` — Accept a draft ADR'
          || E'\n'
          || '`/adr reject <id>` — Reject a draft ADR'
          || E'\n'
          || '`/adr supersede <id>` — Supersede an accepted ADR'
          || E'\n'
          || '`/adr delete <id>` — Permanently delete a draft ADR'
          || E'\n'
          || '`/adr help` — Show this help message'
      );
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
