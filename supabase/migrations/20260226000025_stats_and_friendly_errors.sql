-- Step 25: /adr stats command + friendly state transition error messages
-- 1. build_adr_stats: count ADRs by state for a workspace
-- 2. Improve compute_adr_next_state error messages
-- 3. Add stats to handle_slack_webhook + updated help text

-- 1. Stats helper function
CREATE FUNCTION build_adr_stats(p_team_id text) RETURNS json AS $$
DECLARE
  total int;
  draft_count int;
  accepted_count int;
  rejected_count int;
  superseded_count int;
BEGIN
  SELECT count(*) INTO total FROM adrs WHERE team_id = p_team_id;

  IF total = 0 THEN
    RETURN json_build_object(
      'response_type', 'ephemeral',
      'text', 'No ADRs found in this workspace.'
    );
  END IF;

  SELECT count(*) INTO draft_count FROM adrs WHERE team_id = p_team_id AND state = 'DRAFT';
  SELECT count(*) INTO accepted_count FROM adrs WHERE team_id = p_team_id AND state = 'ACCEPTED';
  SELECT count(*) INTO rejected_count FROM adrs WHERE team_id = p_team_id AND state = 'REJECTED';
  SELECT count(*) INTO superseded_count FROM adrs WHERE team_id = p_team_id AND state = 'SUPERSEDED';

  RETURN json_build_object(
    'response_type', 'ephemeral',
    'text', format(
      '*Workspace ADR Overview (%s total):*'
      || E'\n'
      || E'\u2022 DRAFT: %s'
      || E'\n'
      || E'\u2022 ACCEPTED: %s'
      || E'\n'
      || E'\u2022 REJECTED: %s'
      || E'\n'
      || E'\u2022 SUPERSEDED: %s',
      total, draft_count, accepted_count, rejected_count, superseded_count
    )
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- 2. Rewrite compute_adr_next_state with friendly error messages
CREATE OR REPLACE FUNCTION compute_adr_next_state(
  current_state adr_state,
  event adr_event_type
) RETURNS adr_state AS $$
BEGIN
  RETURN CASE
    WHEN current_state = 'DRAFT' AND event = 'ADR_CREATED'          THEN 'DRAFT'
    WHEN current_state = 'DRAFT' AND event = 'ADR_UPDATED'          THEN 'DRAFT'
    WHEN current_state = 'DRAFT' AND event = 'ADR_ACCEPTED'         THEN 'ACCEPTED'
    WHEN current_state = 'DRAFT' AND event = 'ADR_REJECTED'         THEN 'REJECTED'
    WHEN current_state = 'DRAFT' AND event = 'EXPORT_REQUESTED'     THEN 'DRAFT'
    WHEN current_state = 'DRAFT' AND event = 'EXPORT_COMPLETED'     THEN 'ACCEPTED'
    WHEN current_state = 'DRAFT' AND event = 'EXPORT_FAILED'        THEN 'DRAFT'
    WHEN current_state = 'ACCEPTED' AND event = 'ADR_UPDATED'       THEN 'ACCEPTED'
    WHEN current_state = 'ACCEPTED' AND event = 'ADR_SUPERSEDED'    THEN 'SUPERSEDED'
    WHEN current_state = 'ACCEPTED' AND event = 'EXPORT_REQUESTED'  THEN 'ACCEPTED'
    WHEN current_state = 'ACCEPTED' AND event = 'EXPORT_COMPLETED'  THEN 'ACCEPTED'
    ELSE NULL
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 3. Rewrite apply_adr_event to produce friendly error on invalid transition
-- Preserves original call signature and dispatch_side_effects(req, old, new, event) pattern
CREATE OR REPLACE FUNCTION apply_adr_event(
  p_adr_id text,
  p_event_type adr_event_type,
  p_actor_type adr_actor_type,
  p_actor_id text,
  p_payload jsonb DEFAULT '{}'
) RETURNS adrs AS $$
DECLARE
  req adrs;
  old_state adr_state;
  new_state adr_state;
BEGIN
  -- Pessimistic lock
  SELECT * INTO req FROM adrs WHERE id = p_adr_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ADR % not found', p_adr_id;
  END IF;

  old_state := req.state;
  new_state := compute_adr_next_state(req.state, p_event_type);

  IF new_state IS NULL THEN
    RAISE EXCEPTION 'ADR `%` is currently %. You cannot % it.',
      p_adr_id, req.state,
      CASE p_event_type
        WHEN 'ADR_ACCEPTED' THEN 'accept'
        WHEN 'ADR_REJECTED' THEN 'reject'
        WHEN 'ADR_SUPERSEDED' THEN 'supersede'
        WHEN 'ADR_UPDATED' THEN 'update'
        WHEN 'EXPORT_REQUESTED' THEN 'export'
        ELSE lower(p_event_type::text)
      END;
  END IF;

  -- Append event
  INSERT INTO adr_events (adr_id, event_type, actor_type, actor_id, payload)
  VALUES (p_adr_id, p_event_type, p_actor_type, p_actor_id, p_payload);

  -- Update projection with optimistic concurrency
  UPDATE adrs SET
    state = new_state,
    version = version + 1,
    updated_at = now(),
    title = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'title'
                 THEN p_payload->>'title' ELSE adrs.title END,
    context_text = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'context_text'
                        THEN p_payload->>'context_text' ELSE adrs.context_text END,
    decision = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'decision'
                    THEN p_payload->>'decision' ELSE adrs.decision END,
    alternatives = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'alternatives'
                        THEN p_payload->>'alternatives' ELSE adrs.alternatives END,
    consequences = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'consequences'
                        THEN p_payload->>'consequences' ELSE adrs.consequences END,
    open_questions = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'open_questions'
                          THEN p_payload->>'open_questions' ELSE adrs.open_questions END,
    decision_drivers = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'decision_drivers'
                            THEN p_payload->>'decision_drivers' ELSE adrs.decision_drivers END,
    implementation_plan = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'implementation_plan'
                               THEN p_payload->>'implementation_plan' ELSE adrs.implementation_plan END,
    reviewers = CASE WHEN p_event_type = 'ADR_UPDATED' AND p_payload ? 'reviewers'
                     THEN p_payload->>'reviewers' ELSE adrs.reviewers END,
    git_pr_url = CASE WHEN p_event_type = 'EXPORT_COMPLETED' AND p_payload ? 'pr_url'
                      THEN p_payload->>'pr_url' ELSE adrs.git_pr_url END,
    git_branch = CASE WHEN p_event_type = 'EXPORT_COMPLETED' AND p_payload ? 'branch'
                      THEN p_payload->>'branch' ELSE adrs.git_branch END
  WHERE id = p_adr_id AND version = req.version
  RETURNING * INTO STRICT req;

  -- Dispatch side effects (original signature: req adrs, old_state, new_state, event_type)
  PERFORM dispatch_side_effects(req, old_state, new_state, p_event_type);

  RETURN req;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Add stats to handle_slack_webhook + updated help text
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

    WHEN 'stats' THEN
      RETURN build_adr_stats(team_id);

    WHEN 'accept' THEN
      IF subcommand_arg = '' THEN
        RETURN json_build_object(
          'response_type', 'ephemeral',
          'text', 'Usage: `/adr accept <ADR-ID>` — accept a draft ADR'
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
