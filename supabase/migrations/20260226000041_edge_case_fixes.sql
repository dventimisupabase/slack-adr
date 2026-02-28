-- Step 42: Edge case fixes
-- 1. handle_interactive_payload: catch invalid transition errors from stale buttons
-- 2. Return user-friendly error instead of 500

CREATE OR REPLACE FUNCTION handle_interactive_payload(payload jsonb) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  action_id text;
  adr_id text;
  user_id text;
  team_id text;
  target_adr adrs;
  rec adrs;
  bk jsonb;
BEGIN
  -- Extract action info
  action_id := payload->'actions'->0->>'action_id';
  adr_id := payload->'actions'->0->>'value';
  user_id := payload->'user'->>'id';
  team_id := coalesce(payload->'team'->>'id', payload->>'team_id');

  IF action_id IS NULL THEN
    RETURN json_build_object('text', 'Unknown action.');
  END IF;

  -- For modal-opening actions, no team ownership check needed (Edge Function handles)
  IF action_id IN ('edit_adr', 'start_adr_from_mention') THEN
    RETURN json_build_object('response_type', 'ephemeral', 'text', 'Opening form...');
  END IF;

  -- Require both adr_id and team_id for state-changing actions
  IF adr_id IS NULL THEN
    RETURN json_build_object('text', 'Missing ADR ID.');
  END IF;

  -- Verify team ownership before any state-changing action
  SELECT * INTO target_adr FROM adrs a
  WHERE a.id = adr_id
    AND a.team_id = team_id;

  IF NOT FOUND THEN
    RETURN json_build_object('text', format('ADR `%s` not found.', adr_id));
  END IF;

  -- Handle delete separately (different flow — no event, just delete)
  IF action_id = 'delete_adr' THEN
    IF target_adr.state != 'DRAFT' THEN
      RETURN json_build_object(
        'replace_original', false,
        'text', format('Cannot delete *%s* — only DRAFT ADRs can be deleted. This ADR is %s.', target_adr.id, target_adr.state)
      );
    END IF;
    DELETE FROM adr_outbox WHERE adr_id = target_adr.id;
    DELETE FROM adr_events WHERE adr_id = target_adr.id;
    DELETE FROM adrs WHERE id = target_adr.id;
    RETURN json_build_object(
      'replace_original', true,
      'text', format('Deleted *%s: %s*. This action cannot be undone.', target_adr.id, target_adr.title)
    );
  END IF;

  -- Suppress outbox for interactive actions (response_url handles the update)
  PERFORM set_config('app.suppress_outbox', 'true', true);

  BEGIN
    CASE action_id
      WHEN 'accept_adr' THEN
        rec := apply_adr_event(target_adr.id, 'ADR_ACCEPTED', 'user', user_id);
      WHEN 'reject_adr' THEN
        rec := apply_adr_event(target_adr.id, 'ADR_REJECTED', 'user', user_id);
      WHEN 'supersede_adr' THEN
        rec := apply_adr_event(target_adr.id, 'ADR_SUPERSEDED', 'user', user_id);
      WHEN 'export_adr' THEN
        -- Don't suppress outbox for export (it needs the git-export outbox row)
        PERFORM set_config('app.suppress_outbox', 'false', true);
        rec := apply_adr_event(target_adr.id, 'EXPORT_REQUESTED', 'user', user_id);
      ELSE
        PERFORM set_config('app.suppress_outbox', 'false', true);
        RETURN json_build_object('text', format('Unknown action: %s', action_id));
    END CASE;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.suppress_outbox', 'false', true);
    RETURN json_build_object(
      'replace_original', false,
      'text', format('Cannot %s *%s* — this ADR is currently %s.',
        replace(action_id, '_adr', ''),
        target_adr.id,
        target_adr.state)
    );
  END;

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
