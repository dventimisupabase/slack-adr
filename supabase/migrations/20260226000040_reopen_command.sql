-- Step 41: /adr reopen command
-- Allows REJECTED ADRs to be reopened (back to DRAFT) with optional reason
-- New event type: ADR_REOPENED
-- State transition: REJECTED + ADR_REOPENED → DRAFT

-- 1. Add ADR_REOPENED to the event type enum
ALTER TYPE adr_event_type ADD VALUE 'ADR_REOPENED';

-- 2. Update state machine to handle REJECTED + ADR_REOPENED → DRAFT
CREATE OR REPLACE FUNCTION compute_adr_next_state(
  current_state adr_state,
  event adr_event_type
) RETURNS adr_state AS $$
BEGIN
  CASE current_state
    WHEN 'DRAFT' THEN
      CASE event
        WHEN 'ADR_CREATED'      THEN RETURN 'DRAFT';
        WHEN 'ADR_UPDATED'      THEN RETURN 'DRAFT';
        WHEN 'ADR_ACCEPTED'     THEN RETURN 'ACCEPTED';
        WHEN 'ADR_REJECTED'     THEN RETURN 'REJECTED';
        WHEN 'EXPORT_REQUESTED' THEN RETURN 'DRAFT';
        WHEN 'EXPORT_COMPLETED' THEN RETURN 'ACCEPTED';
        WHEN 'EXPORT_FAILED'    THEN RETURN 'DRAFT';
        ELSE NULL;
      END CASE;
    WHEN 'ACCEPTED' THEN
      CASE event
        WHEN 'ADR_UPDATED'      THEN RETURN 'ACCEPTED';
        WHEN 'ADR_SUPERSEDED'   THEN RETURN 'SUPERSEDED';
        WHEN 'EXPORT_REQUESTED' THEN RETURN 'ACCEPTED';
        WHEN 'EXPORT_COMPLETED' THEN RETURN 'ACCEPTED';
        WHEN 'EXPORT_FAILED'    THEN RETURN 'ACCEPTED';
        ELSE NULL;
      END CASE;
    WHEN 'REJECTED' THEN
      CASE event
        WHEN 'ADR_REOPENED' THEN RETURN 'DRAFT';
        ELSE NULL;
      END CASE;
    ELSE NULL; -- SUPERSEDED is terminal
  END CASE;
  RAISE EXCEPTION 'Invalid transition: state=% event=%', current_state, event;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 3. Wire /adr reopen into handle_slack_webhook + update help text
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

    WHEN 'reopen' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_REOPENED', 'reopen');

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
          || '`/adr accept <id> [reason]` — Accept a draft ADR'
          || E'\n'
          || '`/adr reject <id> [reason]` — Reject a draft ADR'
          || E'\n'
          || '`/adr supersede <id> [reason]` — Supersede an accepted ADR'
          || E'\n'
          || '`/adr reopen <id> [reason]` — Reopen a rejected ADR (back to draft)'
          || E'\n'
          || '`/adr delete <id>` — Permanently delete a draft ADR'
          || E'\n'
          || '`/adr help` — Show this help message'
      );
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Update suggest_command to include 'reopen'
CREATE OR REPLACE FUNCTION suggest_command(input text) RETURNS text AS $$
DECLARE
  commands text[] := ARRAY['start','enable','disable','list','view','search','history','stats','health','export','accept','reject','supersede','reopen','delete','help'];
  cmd text;
  best_match text := NULL;
  best_score float := 0;
  score float;
BEGIN
  IF input IS NULL OR input = '' THEN
    RETURN NULL;
  END IF;

  FOREACH cmd IN ARRAY commands LOOP
    score := 0;
    FOR i IN 1..least(length(input), length(cmd)) LOOP
      IF substr(input, i, 1) = substr(cmd, i, 1) THEN
        score := score + 1;
      END IF;
    END LOOP;
    score := score / greatest(length(input), length(cmd));
    IF substr(input, 1, 1) = substr(cmd, 1, 1) THEN
      score := score + 0.3;
    END IF;
    IF input LIKE '%' || cmd || '%' OR cmd LIKE '%' || input || '%' THEN
      score := score + 0.5;
    END IF;

    IF score > best_score THEN
      best_score := score;
      best_match := cmd;
    END IF;
  END LOOP;

  IF best_score >= 0.5 AND best_match != input THEN
    RETURN best_match;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 5. Update build_adr_history to show ADR_REOPENED events with icon
CREATE OR REPLACE FUNCTION build_adr_history(
  p_team_id text,
  p_adr_id_raw text
) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  target_adr adrs;
  events_text text := '';
  evt record;
  event_icon text;
  cnt int := 0;
BEGIN
  IF p_adr_id_raw IS NULL OR trim(p_adr_id_raw) = '' THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', 'Usage: `/adr history <ADR-ID>` — view the event audit trail for an ADR'
    );
  END IF;

  SELECT * INTO target_adr FROM adrs a
  WHERE a.id = upper(trim(p_adr_id_raw))
    AND a.team_id = p_team_id;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('ADR `%s` not found.', p_adr_id_raw)
    );
  END IF;

  FOR evt IN
    SELECT e.event_type, e.actor_type, e.actor_id, e.created_at, e.payload
    FROM adr_events e
    WHERE e.adr_id = target_adr.id
    ORDER BY e.created_at ASC
  LOOP
    cnt := cnt + 1;
    event_icon := CASE evt.event_type
      WHEN 'ADR_CREATED' THEN ':pencil2:'
      WHEN 'ADR_UPDATED' THEN ':memo:'
      WHEN 'ADR_ACCEPTED' THEN ':white_check_mark:'
      WHEN 'ADR_REJECTED' THEN ':x:'
      WHEN 'ADR_SUPERSEDED' THEN ':arrows_counterclockwise:'
      WHEN 'ADR_REOPENED' THEN ':recycle:'
      WHEN 'EXPORT_REQUESTED' THEN ':outbox_tray:'
      WHEN 'EXPORT_COMPLETED' THEN ':tada:'
      WHEN 'EXPORT_FAILED' THEN ':warning:'
      ELSE ':diamond_shape_with_a_dot_inside:'
    END;

    events_text := events_text
      || format('%s `%s` by <@%s> — <!date^%s^{date_short_pretty} {time}|%s>',
           event_icon,
           evt.event_type,
           evt.actor_id,
           extract(epoch FROM evt.created_at)::bigint,
           to_char(evt.created_at, 'YYYY-MM-DD HH24:MI'))
      || E'\n';

    -- Show reason if present
    IF evt.payload IS NOT NULL AND evt.payload->>'reason' IS NOT NULL THEN
      events_text := events_text
        || format('    _Reason: %s_', evt.payload->>'reason')
        || E'\n';
    END IF;
  END LOOP;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', format('*History for %s: %s* [%s]', target_adr.id, target_adr.title, target_adr.state)
      || E'\n'
      || format('_%s event(s):_', cnt)
      || E'\n\n'
      || events_text
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
