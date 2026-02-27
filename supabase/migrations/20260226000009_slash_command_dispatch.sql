-- Step 9: Full Slash Command Dispatch
-- Replace build_adr_view with Block Kit version.
-- Replace handle_interactive_payload with full implementation.

-- Upgrade build_adr_view to use Block Kit
CREATE OR REPLACE FUNCTION build_adr_view(p_team_id text, p_adr_id text) RETURNS json AS $$
DECLARE
  rec adrs;
  bk jsonb;
BEGIN
  SELECT * INTO rec FROM adrs WHERE id = upper(trim(p_adr_id));
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
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Full interactive payload handler
CREATE OR REPLACE FUNCTION handle_interactive_payload(payload jsonb) RETURNS json AS $$
DECLARE
  action_id text;
  adr_id text;
  user_id text;
  rec adrs;
  bk jsonb;
BEGIN
  -- Extract action info
  action_id := payload->'actions'->0->>'action_id';
  adr_id := payload->'actions'->0->>'value';
  user_id := payload->'user'->>'id';

  IF action_id IS NULL OR adr_id IS NULL THEN
    RETURN json_build_object('text', 'Unknown action.');
  END IF;

  -- Suppress outbox for interactive actions (response_url handles the update)
  PERFORM set_config('app.suppress_outbox', 'true', true);

  CASE action_id
    WHEN 'accept_adr' THEN
      rec := apply_adr_event(adr_id, 'ADR_ACCEPTED', 'user', user_id);
    WHEN 'reject_adr' THEN
      rec := apply_adr_event(adr_id, 'ADR_REJECTED', 'user', user_id);
    WHEN 'supersede_adr' THEN
      rec := apply_adr_event(adr_id, 'ADR_SUPERSEDED', 'user', user_id);
    WHEN 'export_adr' THEN
      -- Don't suppress outbox for export (it needs the git-export outbox row)
      PERFORM set_config('app.suppress_outbox', 'false', true);
      rec := apply_adr_event(adr_id, 'EXPORT_REQUESTED', 'user', user_id);
    WHEN 'edit_adr', 'start_adr_from_mention' THEN
      -- These are handled by the Edge Function (modal opening)
      -- Return nothing here; the Edge Function will open the modal
      RETURN NULL;
    ELSE
      RETURN json_build_object('text', format('Unknown action: %s', action_id));
  END CASE;

  -- Clear suppress flag
  PERFORM set_config('app.suppress_outbox', 'false', true);

  -- Return updated Block Kit for response_url
  bk := build_adr_block_kit(rec, NULL, user_id);
  IF bk IS NOT NULL THEN
    RETURN json_build_object(
      'replace_original', true,
      'blocks', bk->'blocks'
    );
  END IF;

  RETURN json_build_object(
    'replace_original', true,
    'text', format('*%s* updated to *%s*', rec.id, rec.state)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
