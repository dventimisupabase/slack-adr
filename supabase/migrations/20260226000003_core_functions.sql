-- Step 3: Core Functions — state machine, reducer, create_adr

-- Pure state transition function. No side effects, no I/O.
CREATE FUNCTION compute_adr_next_state(
  current_state adr_state,
  event adr_event_type
) RETURNS adr_state AS $$
BEGIN
  CASE current_state
    WHEN 'DRAFT' THEN
      CASE event
        WHEN 'ADR_CREATED'      THEN RETURN 'DRAFT';
        WHEN 'ADR_UPDATED'      THEN RETURN 'DRAFT';
        WHEN 'ADR_ACCEPTED'     THEN RETURN 'ACCEPTED';
        WHEN 'ADR_REJECTED'     THEN RETURN 'REJECTED';
        WHEN 'EXPORT_REQUESTED' THEN RETURN 'DRAFT';
        WHEN 'EXPORT_COMPLETED' THEN RETURN 'ACCEPTED';
        WHEN 'EXPORT_FAILED'    THEN RETURN 'DRAFT';
        ELSE NULL;
      END CASE;
    WHEN 'ACCEPTED' THEN
      CASE event
        WHEN 'ADR_UPDATED'      THEN RETURN 'ACCEPTED';
        WHEN 'ADR_SUPERSEDED'   THEN RETURN 'SUPERSEDED';
        WHEN 'EXPORT_REQUESTED' THEN RETURN 'ACCEPTED';
        WHEN 'EXPORT_COMPLETED' THEN RETURN 'ACCEPTED';
        WHEN 'EXPORT_FAILED'    THEN RETURN 'ACCEPTED';
        ELSE NULL;
      END CASE;
    ELSE NULL; -- REJECTED and SUPERSEDED are terminal
  END CASE;
  RAISE EXCEPTION 'Invalid transition: state=% event=%', current_state, event;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Stub for side effects — will be replaced by outbox in step 6
CREATE FUNCTION dispatch_side_effects(
  req adrs,
  old_state adr_state,
  new_state adr_state,
  event_type adr_event_type
) RETURNS void AS $$
BEGIN
  -- Stub: no-op until outbox is wired (step 6)
  NULL;
END;
$$ LANGUAGE plpgsql;

-- The single reducer: all state mutations go through here.
CREATE FUNCTION apply_adr_event(
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
  SELECT * INTO STRICT req FROM adrs WHERE id = p_adr_id FOR UPDATE;
  old_state := req.state;

  -- Compute transition
  new_state := compute_adr_next_state(req.state, p_event_type);

  -- Append event
  INSERT INTO adr_events (adr_id, event_type, actor_type, actor_id, payload)
  VALUES (p_adr_id, p_event_type, p_actor_type, p_actor_id, p_payload);

  -- Update projection with optimistic concurrency
  UPDATE adrs SET
    state = new_state,
    version = version + 1,
    updated_at = now(),
    -- Update fields from payload on ADR_UPDATED
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
    -- Set git fields on EXPORT_COMPLETED
    git_pr_url = CASE WHEN p_event_type = 'EXPORT_COMPLETED' AND p_payload ? 'pr_url'
                      THEN p_payload->>'pr_url' ELSE adrs.git_pr_url END,
    git_branch = CASE WHEN p_event_type = 'EXPORT_COMPLETED' AND p_payload ? 'branch'
                      THEN p_payload->>'branch' ELSE adrs.git_branch END
  WHERE id = p_adr_id AND version = req.version
  RETURNING * INTO STRICT req;

  -- Dispatch side effects
  PERFORM dispatch_side_effects(req, old_state, new_state, p_event_type);

  RETURN req;
END;
$$ LANGUAGE plpgsql;

-- Create a new ADR
CREATE FUNCTION create_adr(
  p_team_id text,
  p_channel_id text,
  p_created_by text,
  p_title text,
  p_context_text text DEFAULT NULL,
  p_decision text DEFAULT NULL,
  p_alternatives text DEFAULT NULL,
  p_consequences text DEFAULT NULL,
  p_open_questions text DEFAULT NULL,
  p_decision_drivers text DEFAULT NULL,
  p_implementation_plan text DEFAULT NULL,
  p_reviewers text DEFAULT NULL,
  p_slack_thread_link text DEFAULT NULL,
  p_thread_ts text DEFAULT NULL
) RETURNS adrs AS $$
DECLARE
  adr_id text;
  rec adrs;
BEGIN
  adr_id := next_adr_id();

  INSERT INTO adrs (
    id, state, team_id, channel_id, thread_ts, created_by,
    title, context_text, decision, alternatives, consequences,
    open_questions, decision_drivers, implementation_plan, reviewers,
    slack_thread_link
  ) VALUES (
    adr_id, 'DRAFT', p_team_id, p_channel_id, p_thread_ts, p_created_by,
    p_title, p_context_text, p_decision, p_alternatives, p_consequences,
    p_open_questions, p_decision_drivers, p_implementation_plan, p_reviewers,
    p_slack_thread_link
  );

  -- Apply creation event
  rec := apply_adr_event(adr_id, 'ADR_CREATED', 'user', p_created_by);

  RETURN rec;
END;
$$ LANGUAGE plpgsql;
