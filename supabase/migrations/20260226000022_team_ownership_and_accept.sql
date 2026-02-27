-- Step 22: Team ownership verification + /adr accept command
-- 1. build_adr_view: add team_id filter (prevents cross-workspace viewing)
-- 2. handle_slack_webhook: verify team_id before reject/supersede, add /adr accept
-- 3. build_adr_list: include origin channel_id in output
-- 4. Help text: add /adr accept, fix workspace wording

-- 1. Rewrite build_adr_view with team ownership check
CREATE OR REPLACE FUNCTION build_adr_view(p_team_id text, p_adr_id text) RETURNS json AS $$
DECLARE
  rec adrs;
  bk jsonb;
BEGIN
  SELECT * INTO rec FROM adrs
  WHERE id = upper(trim(p_adr_id))
    AND team_id = p_team_id;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('ADR `%s` not found.', p_adr_id)
    );
  END IF;

  bk := build_adr_block_kit(rec);
  IF bk IS NULL THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('*%s: %s* (Status: %s)', rec.id, rec.title, rec.state)
    );
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'blocks', bk->'blocks'
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 2. Rewrite build_adr_list with origin channel
CREATE OR REPLACE FUNCTION build_adr_list(p_team_id text, p_channel_id text) RETURNS json AS $$
DECLARE
  adr_list text := '';
  rec record;
BEGIN
  FOR rec IN
    SELECT id, title, state, channel_id, created_at
    FROM adrs
    WHERE team_id = p_team_id
    ORDER BY created_at DESC
    LIMIT 20
  LOOP
    adr_list := adr_list || format(
      E'\n\u2022 `%s` [%s] %s  (#%s)',
      rec.id, rec.state, rec.title, rec.channel_id
    );
  END LOOP;

  IF adr_list = '' THEN
    adr_list := E'\nNo ADRs found in this workspace.';
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', '*ADRs in this workspace:*' || adr_list
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 3. Rewrite handle_slack_webhook: team ownership + /adr accept
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
  target_adr adrs;
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

    WHEN 'accept' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr accept <ADR-ID>` — accept a draft ADR'
        );
      END IF;
      -- Verify team ownership before accepting (alias needed: #variable_conflict use_variable)
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
        PERFORM set_config('app.suppress_outbox', 'true', true);
        rec := apply_adr_event(target_adr.id, 'ADR_ACCEPTED', 'user', user_id);
        PERFORM set_config('app.suppress_outbox', 'false', true);
        bk := build_adr_block_kit(rec, 'ADR_ACCEPTED'::adr_event_type, user_id);
        IF bk IS NOT NULL THEN
          RETURN json_build_object('response_type', 'ephemeral', 'blocks', bk->'blocks');
        END IF;
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('*%s* has been *ACCEPTED*.', rec.id));
      EXCEPTION WHEN OTHERS THEN
        RETURN json_build_object('response_type', 'ephemeral',
          'text', format('Error: %s', sqlerrm));
      END;

    WHEN 'reject' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr reject <ADR-ID>` — reject an ADR'
        );
      END IF;
      -- Verify team ownership before rejecting (alias needed: #variable_conflict use_variable)
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
        PERFORM set_config('app.suppress_outbox', 'true', true);
        rec := apply_adr_event(target_adr.id, 'ADR_REJECTED', 'user', user_id);
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
      -- Verify team ownership before superseding (alias needed: #variable_conflict use_variable)
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
        PERFORM set_config('app.suppress_outbox', 'true', true);
        rec := apply_adr_event(target_adr.id, 'ADR_SUPERSEDED', 'user', user_id);
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
          || '`/adr list` — List ADRs in this workspace'
          || E'\n'
          || '`/adr view <id>` — View an ADR'
          || E'\n'
          || '`/adr search <query>` — Search ADRs by title or context'
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
