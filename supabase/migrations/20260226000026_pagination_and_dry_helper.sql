-- Step 26: Pagination for list/search + DRY state transition helper
-- 1. build_adr_list: add page parameter, show total count + pagination hints
-- 2. build_adr_search: add page parameter, show total count
-- 3. execute_slash_transition: DRY helper for accept/reject/supersede
-- 4. handle_slack_webhook: parse "page N" from args, use DRY helper

-- Page size constant
-- (Using 20 per page as established)

-- 1. Drop old signatures to avoid overload ambiguity
DROP FUNCTION IF EXISTS build_adr_list(text, text);
DROP FUNCTION IF EXISTS build_adr_list(text, text, text);

CREATE OR REPLACE FUNCTION build_adr_list(
  p_team_id text,
  p_channel_id text,
  p_state text DEFAULT NULL,
  p_page int DEFAULT 1
) RETURNS json AS $$
DECLARE
  adr_list text := '';
  rec record;
  filter_state adr_state;
  heading text;
  total int;
  page_size int := 20;
  offset_val int;
  total_pages int;
BEGIN
  -- Clamp page to >= 1
  IF p_page < 1 THEN
    p_page := 1;
  END IF;
  offset_val := (p_page - 1) * page_size;

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

  -- Get total count
  SELECT count(*) INTO total
  FROM adrs
  WHERE team_id = p_team_id
    AND (filter_state IS NULL OR state = filter_state);

  IF total = 0 THEN
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

  total_pages := ceil(total::float / page_size)::int;

  -- Beyond last page
  IF p_page > total_pages THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('No more ADRs to show. (page %s of %s)', p_page, total_pages)
    );
  END IF;

  FOR rec IN
    SELECT id, title, state, channel_id, created_at
    FROM adrs
    WHERE team_id = p_team_id
      AND (filter_state IS NULL OR state = filter_state)
    ORDER BY created_at DESC
    LIMIT page_size OFFSET offset_val
  LOOP
    adr_list := adr_list || format(
      E'\n\u2022 `%s` [%s] %s  (#%s)',
      rec.id, rec.state, rec.title, rec.channel_id
    );
  END LOOP;

  -- Build heading
  IF filter_state IS NOT NULL THEN
    heading := format('*%s ADRs in this workspace (%s total):*', filter_state, total);
  ELSE
    heading := format('*ADRs in this workspace (%s total):*', total);
  END IF;

  -- Add pagination hint if there are more pages
  IF total_pages > 1 THEN
    heading := heading || format(E'\n_Page %s of %s._', p_page, total_pages);
    IF p_page < total_pages THEN
      IF filter_state IS NOT NULL THEN
        heading := heading || format(' Use `/adr list %s page %s` for more.', lower(filter_state::text), p_page + 1);
      ELSE
        heading := heading || format(' Use `/adr list page %s` for more.', p_page + 1);
      END IF;
    END IF;
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', heading || adr_list
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 2. Rewrite build_adr_search with pagination
DROP FUNCTION IF EXISTS build_adr_search(text, text, text);

CREATE OR REPLACE FUNCTION build_adr_search(
  p_team_id text,
  p_channel_id text,
  p_query text,
  p_page int DEFAULT 1
) RETURNS json AS $$
DECLARE
  results text := '';
  r record;
  cnt int := 0;
  total int;
  tsquery_val tsquery;
  page_size int := 20;
  offset_val int;
  total_pages int;
BEGIN
  IF p_page < 1 THEN
    p_page := 1;
  END IF;
  offset_val := (p_page - 1) * page_size;

  -- Try full-text search first
  BEGIN
    tsquery_val := plainto_tsquery('english', p_query);
  EXCEPTION WHEN OTHERS THEN
    tsquery_val := NULL;
  END;

  -- Get total count
  SELECT count(*) INTO total FROM adrs
  WHERE team_id = p_team_id
    AND (
      (tsquery_val IS NOT NULL AND search_vector @@ tsquery_val)
      OR title ILIKE '%' || p_query || '%'
      OR context_text ILIKE '%' || p_query || '%'
    );

  IF total = 0 THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('No ADRs found matching "%s" in this workspace.', p_query)
    );
  END IF;

  total_pages := ceil(total::float / page_size)::int;

  IF p_page > total_pages THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('No more results for "%s". (page %s of %s)', p_query, p_page, total_pages)
    );
  END IF;

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
    LIMIT page_size OFFSET offset_val
  LOOP
    cnt := cnt + 1;
    results := results || format(E'\u2022 `%s` [%s] %s', r.id, r.state, r.title) || E'\n';
  END LOOP;

  IF total_pages > 1 THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('*Found %s ADR(s) matching "%s" (page %s of %s):*', total, p_query, p_page, total_pages)
        || E'\n' || results
        || CASE WHEN p_page < total_pages
             THEN format('_Use `/adr search %s page %s` for more._', p_query, p_page + 1)
             ELSE '' END
    );
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', format('*Found %s ADR(s) matching "%s":*', total, p_query) || E'\n' || results
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 3. DRY helper for slash command state transitions (accept/reject/supersede)
CREATE OR REPLACE FUNCTION execute_slash_transition(
  p_team_id text,
  p_user_id text,
  p_adr_id_raw text,
  p_event_type adr_event_type,
  p_verb text  -- e.g. 'accept', 'reject', 'supersede'
) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  target_adr adrs;
  rec adrs;
  bk jsonb;
BEGIN
  IF p_adr_id_raw = '' OR p_adr_id_raw IS NULL THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('Usage: `/adr %s <ADR-ID>`', p_verb)
    );
  END IF;

  -- Verify team ownership (alias needed: #variable_conflict use_variable)
  SELECT * INTO target_adr FROM adrs a
  WHERE a.id = upper(trim(p_adr_id_raw))
    AND a.team_id = p_team_id;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('ADR `%s` not found.', p_adr_id_raw)
    );
  END IF;

  BEGIN
    PERFORM set_config('app.suppress_outbox', 'true', true);
    rec := apply_adr_event(target_adr.id, p_event_type, 'user', p_user_id);
    PERFORM set_config('app.suppress_outbox', 'false', true);
    bk := build_adr_block_kit(rec, p_event_type, p_user_id);
    IF bk IS NOT NULL THEN
      RETURN json_build_object('response_type', 'ephemeral', 'blocks', bk->'blocks');
    END IF;
    RETURN json_build_object('response_type', 'ephemeral',
      'text', format('*%s* has been *%s*.', rec.id, rec.state));
  EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object('response_type', 'ephemeral',
      'text', format('Error: %s', sqlerrm));
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Helper to extract "page N" from end of argument string
CREATE OR REPLACE FUNCTION extract_page_number(args text, OUT remaining text, OUT page_num int) AS $$
BEGIN
  -- Match "page <number>" at end of string (\m = word start in PostgreSQL ARE)
  IF args ~ '(?i)\mpage\s+\d+$' THEN
    page_num := (regexp_match(args, '(?i)\mpage\s+(\d+)$'))[1]::int;
    remaining := trim(regexp_replace(args, '(?i)\s*\mpage\s+\d+$', ''));
  ELSE
    remaining := args;
    page_num := 1;
  END IF;

  -- Clamp
  IF page_num < 1 THEN
    page_num := 1;
  END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 5. Rewrite handle_slack_webhook with pagination parsing + DRY helper
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

    WHEN 'accept' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_ACCEPTED', 'accept');

    WHEN 'reject' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_REJECTED', 'reject');

    WHEN 'supersede' THEN
      RETURN execute_slash_transition(team_id, user_id, subcommand_arg, 'ADR_SUPERSEDED', 'supersede');

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
          || '`/adr stats` — Show ADR counts by state'
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
