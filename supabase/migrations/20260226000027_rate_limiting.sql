-- Step 27: Per-team rate limiting for slash commands
-- Prevents abuse via a sliding window counter per team+action.
-- Default: 30 requests per minute per team per action type.

-- 1. Rate limit buckets table
CREATE TABLE IF NOT EXISTS rate_limit_buckets (
  team_id text NOT NULL,
  action text NOT NULL,
  window_start timestamptz NOT NULL DEFAULT now(),
  request_count int NOT NULL DEFAULT 1,
  PRIMARY KEY (team_id, action)
);

-- 2. check_rate_limit: returns true if allowed, false if rate-limited
-- Uses a 1-minute sliding window with 30 requests max.
CREATE OR REPLACE FUNCTION check_rate_limit(
  p_team_id text,
  p_action text,
  p_max_requests int DEFAULT 30,
  p_window interval DEFAULT interval '1 minute'
) RETURNS boolean AS $$
DECLARE
  bucket rate_limit_buckets;
BEGIN
  -- Try to get existing bucket
  SELECT * INTO bucket FROM rate_limit_buckets
  WHERE team_id = p_team_id AND action = p_action
  FOR UPDATE;

  IF NOT FOUND THEN
    -- First request: create bucket
    INSERT INTO rate_limit_buckets (team_id, action, window_start, request_count)
    VALUES (p_team_id, p_action, now(), 1)
    ON CONFLICT (team_id, action) DO UPDATE SET
      request_count = rate_limit_buckets.request_count + 1;
    RETURN true;
  END IF;

  -- Check if window has expired
  IF bucket.window_start + p_window < now() THEN
    -- Reset window
    UPDATE rate_limit_buckets SET
      window_start = now(),
      request_count = 1
    WHERE team_id = p_team_id AND action = p_action;
    RETURN true;
  END IF;

  -- Within window: check count
  IF bucket.request_count >= p_max_requests THEN
    RETURN false;
  END IF;

  -- Increment counter
  UPDATE rate_limit_buckets SET
    request_count = request_count + 1
  WHERE team_id = p_team_id AND action = p_action;

  RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Wire rate limiting into handle_slack_webhook
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

-- 4. RLS for rate_limit_buckets (internal use only)
ALTER TABLE rate_limit_buckets ENABLE ROW LEVEL SECURITY;

-- 5. Cron job to clean up stale rate limit buckets (daily at 4am)
SELECT cron.schedule(
  'cleanup-rate-limits',
  '0 4 * * *',
  $$DELETE FROM rate_limit_buckets WHERE window_start < now() - interval '1 hour'$$
);
