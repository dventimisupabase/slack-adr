-- Step 24: /adr list state filtering + full-text search improvements
-- 1. build_adr_list: accept optional state filter parameter
-- 2. build_adr_search: combine FTS (tsvector) with ILIKE fallback
-- 3. handle_slack_webhook: pass state filter from /adr list <state>
-- 4. Add search vector column + GIN index for FTS
-- 5. Trigger to keep search vector updated

-- 1. Add tsvector column for full-text search
ALTER TABLE adrs ADD COLUMN IF NOT EXISTS search_vector tsvector;

-- Populate existing rows
UPDATE adrs SET search_vector =
  setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
  setweight(to_tsvector('english', coalesce(context_text, '')), 'B') ||
  setweight(to_tsvector('english', coalesce(decision, '')), 'C');

-- GIN index for fast full-text search
CREATE INDEX IF NOT EXISTS idx_adrs_search_vector ON adrs USING GIN (search_vector);

-- 2. Trigger to keep search_vector updated on INSERT/UPDATE
CREATE OR REPLACE FUNCTION update_adr_search_vector() RETURNS trigger AS $$
BEGIN
  NEW.search_vector :=
    setweight(to_tsvector('english', coalesce(NEW.title, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(NEW.context_text, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(NEW.decision, '')), 'C');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_adrs_search_vector ON adrs;
CREATE TRIGGER trg_adrs_search_vector
  BEFORE INSERT OR UPDATE OF title, context_text, decision ON adrs
  FOR EACH ROW
  EXECUTE FUNCTION update_adr_search_vector();

-- 3. Drop old 2-param signature to avoid ambiguity, then create with optional state filter
DROP FUNCTION IF EXISTS build_adr_list(text, text);
CREATE OR REPLACE FUNCTION build_adr_list(p_team_id text, p_channel_id text, p_state text DEFAULT NULL)
RETURNS json AS $$
DECLARE
  adr_list text := '';
  rec record;
  filter_state adr_state;
  heading text;
BEGIN
  -- Validate state filter if provided
  IF p_state IS NOT NULL AND p_state != '' THEN
    BEGIN
      filter_state := upper(p_state)::adr_state;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', format('Unknown state `%s`. Valid states: draft, accepted, rejected, superseded', p_state)
      );
    END;
  END IF;

  FOR rec IN
    SELECT id, title, state, channel_id, created_at
    FROM adrs
    WHERE team_id = p_team_id
      AND (filter_state IS NULL OR state = filter_state)
    ORDER BY created_at DESC
    LIMIT 20
  LOOP
    adr_list := adr_list || format(
      E'\n\u2022 `%s` [%s] %s  (#%s)',
      rec.id, rec.state, rec.title, rec.channel_id
    );
  END LOOP;

  IF adr_list = '' THEN
    IF filter_state IS NOT NULL THEN
      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', format('No ADRs found with state `%s` in this workspace.', filter_state)
      );
    END IF;
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', 'No ADRs found in this workspace.'
    );
  END IF;

  IF filter_state IS NOT NULL THEN
    heading := format('*%s ADRs in this workspace:*', filter_state);
  ELSE
    heading := '*ADRs in this workspace:*';
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', heading || adr_list
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 4. Rewrite build_adr_search with FTS + ILIKE fallback
CREATE OR REPLACE FUNCTION build_adr_search(p_team_id text, p_channel_id text, p_query text)
RETURNS json AS $$
DECLARE
  results text := '';
  r record;
  cnt int := 0;
  tsquery_val tsquery;
BEGIN
  -- Try full-text search first
  BEGIN
    tsquery_val := plainto_tsquery('english', p_query);
  EXCEPTION WHEN OTHERS THEN
    tsquery_val := NULL;
  END;

  FOR r IN
    SELECT id, title, state FROM adrs
    WHERE team_id = p_team_id
      AND (
        (tsquery_val IS NOT NULL AND search_vector @@ tsquery_val)
        OR title ILIKE '%' || p_query || '%'
        OR context_text ILIKE '%' || p_query || '%'
      )
    ORDER BY
      CASE WHEN tsquery_val IS NOT NULL AND search_vector @@ tsquery_val
           THEN ts_rank(search_vector, tsquery_val) ELSE 0 END DESC,
      created_at DESC
    LIMIT 20
  LOOP
    cnt := cnt + 1;
    results := results || format(E'\u2022 `%s` [%s] %s', r.id, r.state, r.title) || E'\n';
  END LOOP;

  IF cnt = 0 THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('No ADRs found matching "%s" in this workspace.', p_query)
    );
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', format('*Found %s ADR(s) matching "%s":*', cnt, p_query) || E'\n' || results
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 5. Rewrite handle_slack_webhook to pass state filter to list
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
      -- subcommand_arg is optional state filter (draft, accepted, rejected, superseded)
      IF subcommand_arg = '' THEN
        RETURN build_adr_list(team_id, channel_id);
      ELSE
        RETURN build_adr_list(team_id, channel_id, subcommand_arg);
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
          || '`/adr list [state]` — List ADRs (filter: draft, accepted, rejected, superseded)'
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
