-- Step 21: Make list and search workspace-scoped, not channel-scoped
-- ADRs are born in channels but belong to the workspace.
-- /adr list and /adr search should show all ADRs for the team.

-- Rewrite build_adr_list to scope by team_id only
CREATE OR REPLACE FUNCTION build_adr_list(p_team_id text, p_channel_id text) RETURNS json AS $$
DECLARE
  adr_list text := '';
  rec record;
BEGIN
  FOR rec IN
    SELECT id, title, state, created_at
    FROM adrs
    WHERE team_id = p_team_id
    ORDER BY created_at DESC
    LIMIT 20
  LOOP
    adr_list := adr_list || format(
      E'\n• `%s` [%s] %s',
      rec.id, rec.state, rec.title
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

-- Rewrite build_adr_search to scope by team_id only
CREATE OR REPLACE FUNCTION build_adr_search(p_team_id text, p_channel_id text, p_query text)
RETURNS json AS $$
DECLARE
  results text := '';
  r record;
  cnt int := 0;
BEGIN
  FOR r IN
    SELECT id, title, state FROM adrs
    WHERE team_id = p_team_id
      AND (title ILIKE '%' || p_query || '%'
           OR context_text ILIKE '%' || p_query || '%')
    ORDER BY created_at DESC
    LIMIT 20
  LOOP
    cnt := cnt + 1;
    results := results || format('• `%s` [%s] %s', r.id, r.state, r.title) || E'\n';
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
