-- Step 4: Side Effects and Webhooks
-- get_secret, url_decode, verify_slack_signature, handle_slack_webhook, check_request

-- Vault helper: read decrypted secret by name
-- Supports test override via session variable: SET LOCAL app.test_secret_<name> = 'value'
CREATE OR REPLACE FUNCTION get_secret(secret_name text) RETURNS text AS $$
DECLARE
  val text;
  test_override text;
BEGIN
  -- Check for test override first
  test_override := current_setting('app.test_secret_' || secret_name, true);
  IF test_override IS NOT NULL AND test_override != '' THEN
    RETURN test_override;
  END IF;

  SELECT decrypted_secret INTO val
  FROM vault.decrypted_secrets
  WHERE name = secret_name
  LIMIT 1;
  IF val IS NULL THEN
    RAISE EXCEPTION 'Secret not found: %', secret_name;
  END IF;
  RETURN val;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- URL decode: handles %XX hex sequences and + to space
CREATE FUNCTION url_decode(input text) RETURNS text AS $$
DECLARE
  result text := input;
  hex_match text[];
BEGIN
  result := replace(result, '+', ' ');
  WHILE result ~ '%[0-9a-fA-F]{2}' LOOP
    hex_match := regexp_match(result, '%([0-9a-fA-F]{2})');
    result := regexp_replace(
      result,
      '%' || hex_match[1],
      chr(('x' || hex_match[1])::bit(8)::int),
      'i'
    );
  END LOOP;
  RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Parse URL-encoded form body into jsonb
CREATE FUNCTION parse_form_body(raw_body text) RETURNS jsonb AS $$
DECLARE
  params jsonb := '{}'::jsonb;
  pair text;
  k text;
  v text;
BEGIN
  IF raw_body IS NULL OR raw_body = '' THEN
    RETURN params;
  END IF;
  FOR pair IN SELECT unnest(string_to_array(raw_body, '&'))
  LOOP
    k := url_decode(split_part(pair, '=', 1));
    v := url_decode(split_part(pair, '=', 2));
    params := params || jsonb_build_object(k, v);
  END LOOP;
  RETURN params;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Verify Slack request signature using HMAC-SHA256
CREATE FUNCTION verify_slack_signature(
  raw_body text,
  timestamp_ text,
  signature text
) RETURNS boolean AS $$
DECLARE
  signing_secret text;
  base_string text;
  computed_sig text;
BEGIN
  signing_secret := get_secret('SLACK_SIGNING_SECRET');
  base_string := 'v0:' || timestamp_ || ':' || raw_body;
  computed_sig := 'v0=' || encode(hmac(base_string, signing_secret, 'sha256'), 'hex');
  -- Constant-time comparison via digest
  RETURN digest(computed_sig, 'sha256') = digest(signature, 'sha256');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- PostgREST pre-request hook: validate Slack signatures before RPC execution
CREATE FUNCTION check_request() RETURNS void AS $$
DECLARE
  request_path text;
  sig text;
  ts text;
  ts_epoch bigint;
BEGIN
  request_path := current_setting('request.path', true);

  -- Gate Slack webhook and modal submission endpoints
  IF request_path IN (
    '/rpc/handle_slack_webhook',
    '/rpc/handle_slack_modal_submission',
    '/rpc/handle_slack_event'
  ) THEN
    sig := current_setting('request.header.x_slack_signature', true);
    ts := current_setting('request.header.x_slack_request_timestamp', true);

    IF sig IS NULL OR sig = '' OR ts IS NULL OR ts = '' THEN
      RAISE EXCEPTION 'Missing Slack signature headers'
        USING ERRCODE = 'P0401';
    END IF;

    -- Replay protection: reject timestamps older than 5 minutes
    ts_epoch := ts::bigint;
    IF abs(extract(epoch FROM now()) - ts_epoch) > 300 THEN
      RAISE EXCEPTION 'Slack request timestamp too old'
        USING ERRCODE = 'P0401';
    END IF;
  END IF;

  -- Gate git export callback
  IF request_path = '/rpc/handle_git_export_callback' THEN
    IF coalesce(current_setting('request.header.x_export_api_key', true), '') = '' THEN
      RAISE EXCEPTION 'Missing export API key'
        USING ERRCODE = 'P0401';
    END IF;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Set pre-request hook
ALTER ROLE authenticator SET pgrst.db_pre_request = 'check_request';
-- Notify PostgREST to reload config
NOTIFY pgrst, 'reload config';

-- Main Slack webhook handler: receives raw form-encoded body
CREATE FUNCTION handle_slack_webhook(raw_body text) RETURNS json AS $$
DECLARE
  params jsonb;
  sig text;
  ts text;
  command_text text;
  subcommand text;
  team_id text;
  channel_id text;
  user_id text;
  payload jsonb;
BEGIN
  -- Read signature headers
  sig := current_setting('request.header.x_slack_signature', true);
  ts := current_setting('request.header.x_slack_request_timestamp', true);

  -- Check if this is an interactive payload (JSON wrapped in form encoding)
  IF raw_body LIKE 'payload=%' THEN
    -- Interactive payload: extract and parse the JSON
    payload := url_decode(split_part(raw_body, 'payload=', 2))::jsonb;

    -- Verify signature
    IF NOT verify_slack_signature(raw_body, ts, sig) THEN
      RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
    END IF;

    RETURN handle_interactive_payload(payload);
  END IF;

  -- Parse form-encoded slash command
  params := parse_form_body(raw_body);

  -- Verify signature
  IF NOT verify_slack_signature(raw_body, ts, sig) THEN
    RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
  END IF;

  command_text := coalesce(trim(params->>'text'), '');
  team_id := params->>'team_id';
  channel_id := params->>'channel_id';
  user_id := params->>'user_id';

  -- Extract subcommand (first word)
  subcommand := split_part(command_text, ' ', 1);

  CASE subcommand
    WHEN 'start' THEN
      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', 'Opening ADR drafting form...'
      );

    WHEN 'enable' THEN
      INSERT INTO channel_config (team_id, channel_id, enabled)
      VALUES (team_id, channel_id, true)
      ON CONFLICT (team_id, channel_id)
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
      UPDATE channel_config SET enabled = false
      WHERE channel_config.team_id = handle_slack_webhook.team_id
        AND channel_config.channel_id = handle_slack_webhook.channel_id;

      RETURN json_build_object(
        'response_type', 'ephemeral',
        'text', 'ADR Bot disabled in this channel. Run `/adr enable` to re-enable.'
      );

    WHEN 'list' THEN
      RETURN build_adr_list(team_id, channel_id);

    WHEN 'view' THEN
      RETURN build_adr_view(team_id, split_part(command_text, ' ', 2));

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
          || '`/adr help` — Show this help message'
      );
  END CASE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Build ADR list response
CREATE FUNCTION build_adr_list(p_team_id text, p_channel_id text) RETURNS json AS $$
DECLARE
  adr_list text := '';
  rec record;
BEGIN
  FOR rec IN
    SELECT id, title, state, created_at
    FROM adrs
    WHERE team_id = p_team_id AND channel_id = p_channel_id
    ORDER BY created_at DESC
    LIMIT 10
  LOOP
    adr_list := adr_list || format(
      E'\n• `%s` [%s] %s',
      rec.id, rec.state, rec.title
    );
  END LOOP;

  IF adr_list = '' THEN
    adr_list := E'\nNo ADRs found in this channel.';
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', '*ADRs in this channel:*' || adr_list
  );
END;
$$ LANGUAGE plpgsql;

-- Build ADR view response (placeholder — full Block Kit in step 7)
CREATE FUNCTION build_adr_view(p_team_id text, p_adr_id text) RETURNS json AS $$
DECLARE
  rec adrs;
BEGIN
  SELECT * INTO rec FROM adrs WHERE id = upper(trim(p_adr_id));
  IF NOT FOUND THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', format('ADR `%s` not found.', p_adr_id)
    );
  END IF;

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', format(
      '*%s: %s*' || E'\n' || 'Status: %s' || E'\n' || 'Created by: <@%s>' || E'\n' || 'Context: %s',
      rec.id, rec.title, rec.state, rec.created_by,
      coalesce(left(rec.context_text, 200), '(none)')
    )
  );
END;
$$ LANGUAGE plpgsql;

-- Interactive payload handler (placeholder — full implementation in step 9)
CREATE FUNCTION handle_interactive_payload(payload jsonb) RETURNS json AS $$
BEGIN
  -- Stub: will be implemented with full interactive action handling in step 9
  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', 'Interactive action received.'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
