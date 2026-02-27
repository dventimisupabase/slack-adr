// supabase/functions/slack-proxy/index.ts
// Thin Deno proxy for Slack slash commands, interactivity, and modal submissions.
// Three paths:
//   1. Modal opening (/adr start, edit_adr, start_adr_from_mention) — direct Slack API call
//   2. Interactive payloads (view_submission, block_actions) — forward to PostgREST RPCs
//   3. Default (slash commands) — forward raw body to PostgREST RPC

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const slackBotToken = Deno.env.get("SLACK_BOT_TOKEN")!;

function rpcHeaders(req: Request): Record<string, string> {
  return {
    "Content-Type": "text/plain",
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    // Forward Slack signature headers with underscore names (PG GUC constraint)
    x_slack_signature: req.headers.get("x-slack-signature") ?? "",
    x_slack_request_timestamp:
      req.headers.get("x-slack-request-timestamp") ?? "",
  };
}

// ADR modal view definition
function buildModalView(
  channelId: string,
  threadTs: string,
  adrId?: string,
  prefill?: Record<string, string>,
): Record<string, unknown> {
  const privateMetadata = `${channelId}|${threadTs}|${adrId ?? ""}`;
  const title = adrId ? "Edit ADR" : "New ADR";

  const textInput = (
    blockId: string,
    actionId: string,
    label: string,
    placeholder: string,
    optional: boolean,
    initialValue?: string,
  ) => ({
    type: "input",
    block_id: blockId,
    optional,
    element: {
      type: "plain_text_input",
      action_id: actionId,
      multiline: true,
      placeholder: { type: "plain_text", text: placeholder },
      ...(initialValue ? { initial_value: initialValue } : {}),
    },
    label: { type: "plain_text", text: label },
  });

  return {
    type: "modal",
    title: { type: "plain_text", text: title },
    submit: { type: "plain_text", text: adrId ? "Update" : "Create" },
    close: { type: "plain_text", text: "Cancel" },
    private_metadata: privateMetadata,
    blocks: [
      textInput(
        "title_block",
        "title_input",
        "Title",
        "Short descriptive title for the decision",
        false,
        prefill?.title,
      ),
      textInput(
        "context_block",
        "context_input",
        "Context",
        "What is the issue that we're seeing that is motivating this decision?",
        false,
        prefill?.context_text,
      ),
      textInput(
        "decision_block",
        "decision_input",
        "Decision",
        "What is the change that we're proposing and/or doing?",
        true,
        prefill?.decision,
      ),
      textInput(
        "alternatives_block",
        "alternatives_input",
        "Alternatives Considered",
        "What alternatives were considered?",
        true,
        prefill?.alternatives,
      ),
      textInput(
        "consequences_block",
        "consequences_input",
        "Consequences",
        "What are the positive and negative consequences?",
        true,
        prefill?.consequences,
      ),
      textInput(
        "open_questions_block",
        "open_questions_input",
        "Open Questions",
        "What remains to be decided or investigated?",
        true,
        prefill?.open_questions,
      ),
      textInput(
        "decision_drivers_block",
        "decision_drivers_input",
        "Decision Drivers",
        "Key factors influencing the decision",
        true,
        prefill?.decision_drivers,
      ),
      textInput(
        "implementation_plan_block",
        "implementation_plan_input",
        "Implementation Plan",
        "Steps to implement the decision",
        true,
        prefill?.implementation_plan,
      ),
      textInput(
        "reviewers_block",
        "reviewers_input",
        "Reviewers",
        "Who should review this ADR?",
        true,
        prefill?.reviewers,
      ),
    ],
  };
}

async function openModal(
  triggerId: string,
  channelId: string,
  threadTs: string,
  adrId?: string,
  prefill?: Record<string, string>,
): Promise<Response> {
  const view = buildModalView(channelId, threadTs, adrId, prefill);
  const slackResp = await fetch("https://slack.com/api/views.open", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${slackBotToken}`,
    },
    body: JSON.stringify({ trigger_id: triggerId, view }),
  });

  const result = await slackResp.json();
  if (!result.ok) {
    console.error("views.open failed:", result);
  }

  // Return ephemeral acknowledgment
  return new Response("", { status: 200 });
}

async function fetchAdrPrefill(adrId: string): Promise<Record<string, string>> {
  const resp = await fetch(
    `${supabaseUrl}/rest/v1/adrs?id=eq.${encodeURIComponent(adrId)}&select=title,context_text,decision,alternatives,consequences,open_questions,decision_drivers,implementation_plan,reviewers`,
    {
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
    },
  );
  const rows = await resp.json();
  return rows?.[0] ?? {};
}

Deno.serve(async (req: Request) => {
  try {
    const body = await req.text();
    const params = new URLSearchParams(body);

    // Path 1: Slash command — check if it's /adr start (needs modal)
    if (params.has("command")) {
      const text = (params.get("text") ?? "").trim();
      if (text === "start" || text === "") {
        const triggerId = params.get("trigger_id") ?? "";
        const channelId = params.get("channel_id") ?? "";
        const threadTs = "";
        return await openModal(triggerId, channelId, threadTs);
      }

      // Other slash commands → forward to PostgREST
      const resp = await fetch(
        `${supabaseUrl}/rest/v1/rpc/handle_slack_webhook`,
        { method: "POST", headers: rpcHeaders(req), body },
      );
      const result = await resp.text();
      return new Response(result, {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    // Path 2: Interactive payload (JSON wrapped in form payload field)
    if (params.has("payload")) {
      const payload = JSON.parse(params.get("payload")!);

      // Path 2a: Modal submission
      if (payload.type === "view_submission") {
        const resp = await fetch(
          `${supabaseUrl}/rest/v1/rpc/handle_slack_modal_submission`,
          {
            method: "POST",
            headers: rpcHeaders(req),
            body: JSON.stringify(payload),
          },
        );
        const result = await resp.text();
        // Null/empty means close the modal
        if (!result || result === "null") {
          return new Response("", { status: 200 });
        }
        // Validation errors or other response
        return new Response(result, {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }

      // Path 2b: Block actions
      if (payload.type === "block_actions") {
        const action = payload.actions?.[0];
        const actionId = action?.action_id ?? "";
        const responseUrl = payload.response_url;

        // Modal-opening actions → need trigger_id
        if (actionId === "edit_adr") {
          const adrId = action.value;
          const triggerId = payload.trigger_id;
          const channelId = payload.channel?.id ?? payload.container?.channel_id ?? "";
          const threadTs = payload.message?.thread_ts ?? "";
          const prefill = await fetchAdrPrefill(adrId);
          return await openModal(triggerId, channelId, threadTs, adrId, prefill);
        }

        if (actionId === "start_adr_from_mention") {
          const triggerId = payload.trigger_id;
          const [channelId, threadTs] = (action.value ?? "|").split("|");
          return await openModal(triggerId, channelId, threadTs);
        }

        // Other block actions → fire-and-forget to RPC, post result to response_url
        const bgWork = (async () => {
          try {
            const resp = await fetch(
              `${supabaseUrl}/rest/v1/rpc/handle_slack_webhook`,
              {
                method: "POST",
                headers: {
                  ...rpcHeaders(req),
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({ raw_body: body }),
              },
            );

            if (resp.ok && responseUrl) {
              const webhookResult = await resp.json();
              if (webhookResult) {
                await fetch(responseUrl, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify(webhookResult),
                });
              }
            }
          } catch (err) {
            console.error("Background block_actions processing failed:", err);
          }
        })();

        // Don't await — acknowledge immediately
        void bgWork;
        return new Response("", { status: 200 });
      }
    }

    // Path 3: Default — forward raw body to PostgREST
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/rpc/handle_slack_webhook`,
      { method: "POST", headers: rpcHeaders(req), body },
    );
    const result = await resp.text();
    return new Response(result, {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("slack-proxy error:", err);
    return new Response(
      JSON.stringify({ response_type: "ephemeral", text: "Internal error. Please try again." }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
});
