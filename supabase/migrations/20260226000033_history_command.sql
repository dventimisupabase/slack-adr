-- Step 33: /adr history <id> command
-- Shows the full event audit trail for an ADR.
-- Useful for compliance and understanding decision history.

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
    SELECT e.event_type, e.actor_type, e.actor_id, e.created_at
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

-- Wire into handle_slack_webhook
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
  -- pagination
  parsed_remaining text;
  parsed_page int;
  -- export
  target_adr adrs;
  rec adrs;
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

  -- Rate limit check (30 requests/minute per team)
  IF NOT check_rate_limit(team_id, 'slash_command') THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', 'You''re sending too many commands. Please slow down and try again in a minute.'
    );
  END IF;

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
      -- Parse "page N" from end of arg, remainder is state filter
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
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr search <query>` — search ADRs by title or context'
        );
      END IF;
      -- Parse "page N" from end of arg, remainder is search query
      SELECT * INTO parsed_remaining, parsed_page FROM extract_page_number(subcommand_arg);
      IF parsed_remaining = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr search <query>` — search ADRs by title or context'
        );
      END IF;
      RETURN build_adr_search(team_id, channel_id, parsed_remaining, parsed_page);

    WHEN 'stats' THEN
      RETURN build_adr_stats(team_id);

    WHEN 'history' THEN
      RETURN build_adr_history(team_id, subcommand_arg);

    WHEN 'accept' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_ACCEPTED', 'accept');

    WHEN 'reject' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_REJECTED', 'reject');

    WHEN 'supersede' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_SUPERSEDED', 'supersede');

    WHEN 'export' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr export <ADR-ID>` — export an ADR to GitHub as a pull request'
        );
      END IF;
      SELECT * INTO target_adr FROM adrs a
      WHERE a.id = upper(trim(subcommand_arg))
        AND a.team_id = team_id;
      IF NOT FOUND THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', format('ADR `%s` not found.', subcommand_arg)
        );
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
          || '`/adr help` — Show this help message'
      );
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
