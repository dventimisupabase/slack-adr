-- Step 10: Modal Submission Handler
-- Receives JSON view_submission payload from Edge Function.

CREATE FUNCTION handle_slack_modal_submission(raw_body text) RETURNS json AS $$
#variable_conflict use_variable
DECLARE
  payload jsonb;
  sig text;
  ts text;
  user_id text;
  private_metadata text;
  meta_parts text[];
  channel_id text;
  thread_ts text;
  adr_id text;
  vals jsonb;
  p_title text;
  p_context text;
  p_decision text;
  p_alternatives text;
  p_consequences text;
  p_open_questions text;
  p_decision_drivers text;
  p_implementation_plan text;
  p_reviewers text;
  errors jsonb := '{}'::jsonb;
  rec adrs;
  update_payload jsonb;
  looked_up_team_id text;
BEGIN
  -- Parse JSON payload
  payload := raw_body::jsonb;

  -- Verify signature
  sig := current_setting('request.header.x_slack_signature', true);
  ts := current_setting('request.header.x_slack_request_timestamp', true);
  IF sig IS NOT NULL AND sig != '' THEN
    IF NOT verify_slack_signature(raw_body, ts, sig) THEN
      RAISE EXCEPTION 'Invalid Slack signature' USING ERRCODE = 'P0401';
    END IF;
  END IF;

  -- Extract user and metadata
  user_id := payload->'user'->>'id';
  private_metadata := payload->'view'->>'private_metadata';

  -- Parse private_metadata: channel_id|thread_ts|adr_id
  meta_parts := string_to_array(private_metadata, '|');
  channel_id := meta_parts[1];
  thread_ts := NULLIF(meta_parts[2], '');
  adr_id := NULLIF(meta_parts[3], '');

  -- Extract form values from view.state.values
  vals := payload->'view'->'state'->'values';

  p_title := vals->'title_block'->'title_input'->>'value';
  p_context := vals->'context_block'->'context_input'->>'value';
  p_decision := vals->'decision_block'->'decision_input'->>'value';
  p_alternatives := vals->'alternatives_block'->'alternatives_input'->>'value';
  p_consequences := vals->'consequences_block'->'consequences_input'->>'value';
  p_open_questions := vals->'open_questions_block'->'open_questions_input'->>'value';
  p_decision_drivers := vals->'decision_drivers_block'->'decision_drivers_input'->>'value';
  p_implementation_plan := vals->'implementation_plan_block'->'implementation_plan_input'->>'value';
  p_reviewers := vals->'reviewers_block'->'reviewers_input'->>'value';

  -- Validate required fields
  IF p_title IS NULL OR trim(p_title) = '' THEN
    errors := errors || jsonb_build_object('title_block', 'Title is required');
  END IF;
  IF p_context IS NULL OR trim(p_context) = '' THEN
    errors := errors || jsonb_build_object('context_block', 'Context is required');
  END IF;

  IF errors != '{}'::jsonb THEN
    RETURN json_build_object('response_action', 'errors', 'errors', errors);
  END IF;

  IF adr_id IS NOT NULL AND adr_id != '' THEN
    -- Edit existing ADR
    update_payload := jsonb_build_object(
      'title', p_title,
      'context_text', p_context,
      'decision', p_decision,
      'alternatives', p_alternatives,
      'consequences', p_consequences,
      'open_questions', p_open_questions,
      'decision_drivers', p_decision_drivers,
      'implementation_plan', p_implementation_plan,
      'reviewers', p_reviewers
    );
    rec := apply_adr_event(adr_id, 'ADR_UPDATED', 'user', user_id, update_payload);
  ELSE
    -- Create new ADR — look up team_id from channel_config
    SELECT cc.team_id INTO looked_up_team_id
    FROM channel_config cc WHERE cc.channel_id = channel_id LIMIT 1;

    rec := create_adr(
      p_team_id := looked_up_team_id,
      p_channel_id := channel_id,
      p_created_by := user_id,
      p_title := p_title,
      p_context_text := p_context,
      p_decision := p_decision,
      p_alternatives := p_alternatives,
      p_consequences := p_consequences,
      p_open_questions := p_open_questions,
      p_decision_drivers := p_decision_drivers,
      p_implementation_plan := p_implementation_plan,
      p_reviewers := p_reviewers,
      p_thread_ts := thread_ts
    );
  END IF;

  -- Return NULL to close the modal
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
