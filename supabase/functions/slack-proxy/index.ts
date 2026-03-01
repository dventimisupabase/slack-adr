// supabase/functions/slack-proxy/index.ts
// Thin Deno proxy for Slack slash commands, interactivity, and modal submissions.
// Four paths:
//   1. Modal opening (/adr start, edit_adr, start_adr_from_mention) — direct Slack API call
//   2. Interactive payloads (view_submission, block_actions) — forward to PostgREST RPCs
//   3. Canvas actions (draft_adr_canvas, finalize_adr_from_canvas) — Slack Canvas API
//   4. Default (slash commands) — forward raw body to PostgREST RPC

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const slackBotToken = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
const geminiApiKey = Deno.env.get("GEMINI_API_KEY") ?? "";

if (!supabaseUrl || !serviceRoleKey) {
  console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
}
if (!slackBotToken) {
  console.warn("SLACK_BOT_TOKEN not set — modal opening will fail");
}

function rpcHeaders(req: Request): Record<string, string> {
  return {
    "Content-Type": "application/json",
    apikey: serviceRoleKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    // Forward Slack signature headers (available via request.headers JSON in PG)
    "x-slack-signature": req.headers.get("x-slack-signature") ?? "",
    "x-slack-request-timestamp":
      req.headers.get("x-slack-request-timestamp") ?? "",
  };
}

function rpcBody(rawBody: string): string {
  return JSON.stringify({ raw_body: rawBody });
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
    // Return ephemeral error so user knows the modal didn't open
    return new Response(
      JSON.stringify({
        response_type: "ephemeral",
        text: `Failed to open form: ${result.error ?? "unknown error"}. Please try again.`,
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  // Return empty acknowledgment (Slack opens modal)
  return new Response("", { status: 200 });
}

async function fetchAdrPrefill(adrId: string): Promise<Record<string, string>> {
  try {
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/adrs?id=eq.${encodeURIComponent(adrId)}&select=title,context_text,decision,alternatives,consequences,open_questions,decision_drivers,implementation_plan,reviewers`,
      {
        headers: {
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
        },
      },
    );
    if (!resp.ok) {
      console.error("fetchAdrPrefill failed:", resp.status);
      return {};
    }
    const rows = await resp.json();
    return rows?.[0] ?? {};
  } catch (err) {
    console.error("fetchAdrPrefill error:", err);
    return {};
  }
}

async function fetchThreadMessages(
  channelId: string,
  threadTs: string,
): Promise<Array<{ user: string; text: string; ts: string }>> {
  try {
    const resp = await fetch(
      `https://slack.com/api/conversations.replies?channel=${encodeURIComponent(channelId)}&ts=${encodeURIComponent(threadTs)}&limit=200`,
      {
        headers: { Authorization: `Bearer ${slackBotToken}` },
      },
    );
    const result = await resp.json();
    if (!result.ok) {
      console.error("conversations.replies failed:", result.error);
      return [];
    }
    return (result.messages ?? [])
      .filter(
        (m: Record<string, unknown>) =>
          !m.bot_id && !m.subtype && typeof m.text === "string" && (m.text as string).trim() !== "",
      )
      .map((m: Record<string, unknown>) => ({
        user: (m.user as string) ?? "unknown",
        text: m.text as string,
        ts: (m.ts as string) ?? "",
      }));
  } catch (err) {
    console.error("fetchThreadMessages error:", err);
    return [];
  }
}

async function summarizeThread(
  messages: Array<{ user: string; text: string; ts: string }>,
): Promise<Record<string, string>> {
  if (!geminiApiKey) {
    console.warn("GEMINI_API_KEY not set — skipping thread summarization");
    return {};
  }
  try {
    const threadText = messages
      .map((m) => `<${m.user}>: ${m.text}`)
      .join("\n");

    const resp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${geminiApiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          systemInstruction: {
            parts: [
              {
                text:
                  "You extract structured Architecture Decision Record (ADR) fields from Slack conversations. " +
                  "Return ONLY valid JSON with these keys: title, context_text, decision, alternatives, consequences, open_questions, decision_drivers, implementation_plan. " +
                  "Each value is a string. Leave a field as an empty string if it cannot be inferred from the conversation. " +
                  "Be concise but capture the key points. Do not invent information not present in the conversation.",
              },
            ],
          },
          contents: [
            {
              role: "user",
              parts: [
                {
                  text:
                    "Extract ADR fields from this Slack thread:\n\n" +
                    threadText,
                },
              ],
            },
          ],
        }),
      },
    );

    if (!resp.ok) {
      console.error("Gemini API error:", resp.status, await resp.text());
      return {};
    }

    const result = await resp.json();
    const text = result.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    // Extract JSON from response (may be wrapped in markdown code block)
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      console.error("Gemini response contained no JSON:", text);
      return {};
    }
    const parsed = JSON.parse(jsonMatch[0]);
    // Only keep string values for known fields
    const fields = [
      "title",
      "context_text",
      "decision",
      "alternatives",
      "consequences",
      "open_questions",
      "decision_drivers",
      "implementation_plan",
    ];
    const prefill: Record<string, string> = {};
    for (const f of fields) {
      if (typeof parsed[f] === "string" && parsed[f].trim() !== "") {
        prefill[f] = parsed[f];
      }
    }
    return prefill;
  } catch (err) {
    console.error("summarizeThread error:", err);
    return {};
  }
}

// --- Canvas helpers ---

const ADR_HEADINGS: Array<{ heading: string; key: string }> = [
  { heading: "Title", key: "title" },
  { heading: "Context", key: "context_text" },
  { heading: "Decision", key: "decision" },
  { heading: "Alternatives Considered", key: "alternatives" },
  { heading: "Consequences", key: "consequences" },
  { heading: "Open Questions", key: "open_questions" },
  { heading: "Decision Drivers", key: "decision_drivers" },
  { heading: "Implementation Plan", key: "implementation_plan" },
  { heading: "Reviewers", key: "reviewers" },
];

function buildCanvasMarkdown(prefill: Record<string, string>): string {
  return ADR_HEADINGS.map(({ heading, key }) => {
    const value = prefill[key]?.trim() || "";
    return `## ${heading}\n\n${value}`;
  }).join("\n\n");
}

async function summarizeThreadForCanvas(
  messages: Array<{ user: string; text: string; ts: string }>,
): Promise<string> {
  if (!geminiApiKey || messages.length === 0) {
    return buildCanvasMarkdown({});
  }
  try {
    const threadText = messages
      .map((m) => `<${m.user}>: ${m.text}`)
      .join("\n");

    const resp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${geminiApiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          systemInstruction: {
            parts: [
              {
                text:
                  "You extract structured Architecture Decision Record (ADR) fields from Slack conversations. " +
                  "Return ONLY a markdown document with these ## headings: Title, Context, Decision, Alternatives Considered, Consequences, Open Questions, Decision Drivers, Implementation Plan, Reviewers. " +
                  "Under each heading, write a concise paragraph (or leave blank if nothing can be inferred). " +
                  "Do not invent information not present in the conversation.",
              },
            ],
          },
          contents: [
            {
              role: "user",
              parts: [
                {
                  text:
                    "Extract ADR fields from this Slack thread into markdown:\n\n" +
                    threadText,
                },
              ],
            },
          ],
        }),
      },
    );

    if (!resp.ok) {
      console.error("Gemini Canvas API error:", resp.status, await resp.text());
      return buildCanvasMarkdown({});
    }

    const result = await resp.json();
    const text = result.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    // If Gemini returned valid markdown with headings, use it directly
    if (text.includes("## ")) {
      return text;
    }
    return buildCanvasMarkdown({});
  } catch (err) {
    console.error("summarizeThreadForCanvas error:", err);
    return buildCanvasMarkdown({});
  }
}

async function createCanvas(
  markdown: string,
  title: string,
): Promise<string | null> {
  try {
    const resp = await fetch("https://slack.com/api/canvases.create", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${slackBotToken}`,
      },
      body: JSON.stringify({
        title: `ADR Draft: ${title}`,
        document_content: { type: "markdown", markdown },
      }),
    });
    const result = await resp.json();
    if (!result.ok) {
      console.error("canvases.create failed:", result.error);
      return null;
    }
    return result.canvas_id ?? null;
  } catch (err) {
    console.error("createCanvas error:", err);
    return null;
  }
}

async function grantCanvasAccess(
  canvasId: string,
  channelId: string,
): Promise<boolean> {
  try {
    const resp = await fetch("https://slack.com/api/canvases.access.set", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${slackBotToken}`,
      },
      body: JSON.stringify({
        canvas_id: canvasId,
        access_level: "can_edit",
        channel_ids: [channelId],
      }),
    });
    const result = await resp.json();
    if (!result.ok) {
      console.error("canvases.access.set failed:", result.error);
      return false;
    }
    return true;
  } catch (err) {
    console.error("grantCanvasAccess error:", err);
    return false;
  }
}

async function readCanvasContent(
  canvasId: string,
): Promise<string> {
  try {
    const resp = await fetch("https://slack.com/api/canvases.sections.lookup", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${slackBotToken}`,
      },
      body: JSON.stringify({
        canvas_id: canvasId,
        criteria: { contains_text: "" },
      }),
    });
    const result = await resp.json();
    if (!result.ok) {
      console.error("canvases.sections.lookup failed:", result.error);
      return "";
    }
    // Concatenate all section markdown content
    const sections = result.sections ?? [];
    return sections
      .map((s: Record<string, unknown>) => (s as Record<string, string>).markdown ?? "")
      .join("\n");
  } catch (err) {
    console.error("readCanvasContent error:", err);
    return "";
  }
}

function parseCanvasMarkdown(
  markdown: string,
): Record<string, string> {
  const fields: Record<string, string> = {};
  // Normalize heading aliases to ADR field keys
  const headingMap: Record<string, string> = {};
  for (const { heading, key } of ADR_HEADINGS) {
    headingMap[heading.toLowerCase()] = key;
  }
  // Also accept common variations
  headingMap["alternatives"] = "alternatives";
  headingMap["context"] = "context_text";

  const sections = markdown.split(/^## /m).filter(Boolean);
  for (const section of sections) {
    const newlineIdx = section.indexOf("\n");
    if (newlineIdx === -1) continue;
    const heading = section.substring(0, newlineIdx).trim().toLowerCase();
    const body = section.substring(newlineIdx + 1).trim();
    const key = headingMap[heading];
    if (key && body) {
      fields[key] = body;
    }
  }
  return fields;
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
        { method: "POST", headers: rpcHeaders(req), body: rpcBody(body) },
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
            body: rpcBody(JSON.stringify(payload)),
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

          // Step 1: Open modal immediately (blank) to beat the 3s trigger_id deadline
          const view = buildModalView(channelId, threadTs);
          const openResp = await fetch("https://slack.com/api/views.open", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${slackBotToken}`,
            },
            body: JSON.stringify({ trigger_id: triggerId, view }),
          });
          const openResult = await openResp.json();
          if (!openResult.ok) {
            console.error("views.open failed:", openResult);
            return new Response(
              JSON.stringify({
                response_type: "ephemeral",
                text: `Failed to open form: ${openResult.error ?? "unknown"}`,
              }),
              { status: 200, headers: { "Content-Type": "application/json" } },
            );
          }

          const viewId = openResult.view?.id;

          // Step 2: Background — fetch thread, summarize with AI, update modal
          // Use waitUntil to keep the edge function alive after response is sent
          if (viewId && threadTs) {
            const bgWork = (async () => {
              try {
                const messages = await fetchThreadMessages(channelId, threadTs);
                if (messages.length === 0) return;

                const prefill = await summarizeThread(messages);
                if (!prefill || Object.keys(prefill).length === 0) return;

                const updatedView = buildModalView(channelId, threadTs, undefined, prefill);
                const updateResp = await fetch("https://slack.com/api/views.update", {
                  method: "POST",
                  headers: {
                    "Content-Type": "application/json",
                    Authorization: `Bearer ${slackBotToken}`,
                  },
                  body: JSON.stringify({ view_id: viewId, view: updatedView }),
                });
                const updateResult = await updateResp.json();
                if (!updateResult.ok) {
                  console.error("views.update failed:", updateResult);
                }
              } catch (err) {
                console.error("Background thread summarization failed:", err);
              }
            })();
            // deno-lint-ignore no-explicit-any
            (globalThis as any).EdgeRuntime?.waitUntil?.(bgWork);
            bgWork.catch((err) => console.error("Unhandled bgWork error:", err));
          }

          return new Response("", { status: 200 });
        }

        // Canvas draft action — no modal needed, all background work
        if (actionId === "draft_adr_canvas") {
          const [channelId, threadTs] = (action.value ?? "|").split("|");

          const bgWork = (async () => {
            try {
              // Fetch thread messages and summarize to markdown
              const messages = await fetchThreadMessages(channelId, threadTs);
              const markdown = await summarizeThreadForCanvas(messages);

              // Extract title from markdown for Canvas name
              const titleMatch = markdown.match(/^## Title\n\n(.+)/m);
              const canvasTitle = titleMatch?.[1]?.trim() || "Untitled";

              // Create Canvas
              const canvasId = await createCanvas(markdown, canvasTitle);
              if (!canvasId) {
                if (responseUrl) {
                  await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      replace_original: false,
                      text: "Failed to create Canvas. Try the *Start ADR* button instead.",
                    }),
                  });
                }
                return;
              }

              // Grant channel edit access
              await grantCanvasAccess(canvasId, channelId);

              // Post Canvas link + Finalize button in thread
              const postBody = {
                channel: channelId,
                thread_ts: threadTs,
                text: `Draft your ADR collaboratively in this Canvas, then click *Finalize ADR* when ready.`,
                blocks: [
                  {
                    type: "section",
                    text: {
                      type: "mrkdwn",
                      text: `Draft your ADR collaboratively in this Canvas, then click *Finalize ADR* when ready.\n\n<https://slack.com/docs/canvas/${canvasId}|Open Canvas>`,
                    },
                  },
                  {
                    type: "actions",
                    elements: [
                      {
                        type: "button",
                        text: { type: "plain_text", text: "Finalize ADR" },
                        action_id: "finalize_adr_from_canvas",
                        value: `${canvasId}|${channelId}|${threadTs}`,
                        style: "primary",
                      },
                    ],
                  },
                ],
              };

              await fetch("https://slack.com/api/chat.postMessage", {
                method: "POST",
                headers: {
                  "Content-Type": "application/json",
                  Authorization: `Bearer ${slackBotToken}`,
                },
                body: JSON.stringify(postBody),
              });
            } catch (err) {
              console.error("draft_adr_canvas background error:", err);
              if (responseUrl) {
                try {
                  await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      replace_original: false,
                      text: "Something went wrong creating the Canvas. Try the *Start ADR* button instead.",
                    }),
                  });
                } catch { /* last resort */ }
              }
            }
          })();

          // deno-lint-ignore no-explicit-any
          (globalThis as any).EdgeRuntime?.waitUntil?.(bgWork);
          bgWork.catch((err) => console.error("Unhandled draft_adr_canvas error:", err));
          return new Response("", { status: 200 });
        }

        // Finalize ADR from Canvas — read Canvas content and create ADR
        if (actionId === "finalize_adr_from_canvas") {
          const parts = (action.value ?? "||").split("|");
          const canvasId = parts[0];
          const channelId = parts[1];
          const threadTs = parts[2];

          const bgWork = (async () => {
            try {
              // Read Canvas content
              const markdown = await readCanvasContent(canvasId);
              if (!markdown) {
                if (responseUrl) {
                  await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      replace_original: false,
                      text: "Could not read Canvas content. Please try again.",
                    }),
                  });
                }
                return;
              }

              // Parse markdown into ADR fields
              const fields = parseCanvasMarkdown(markdown);

              // Validate required fields
              const missing: string[] = [];
              if (!fields.title?.trim()) missing.push("Title");
              if (!fields.context_text?.trim()) missing.push("Context");

              if (missing.length > 0) {
                if (responseUrl) {
                  await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      replace_original: false,
                      text: `Missing required fields: *${missing.join("*, *")}*. Please fill them in the Canvas and try again.`,
                    }),
                  });
                }
                return;
              }

              // Look up team_id from channel_config
              const configResp = await fetch(
                `${supabaseUrl}/rest/v1/channel_config?channel_id=eq.${encodeURIComponent(channelId)}&select=team_id&limit=1`,
                {
                  headers: {
                    apikey: serviceRoleKey,
                    Authorization: `Bearer ${serviceRoleKey}`,
                  },
                },
              );
              const configRows = await configResp.json();
              const teamId = configRows?.[0]?.team_id;

              if (!teamId) {
                if (responseUrl) {
                  await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      replace_original: false,
                      text: "ADR Bot is not enabled in this channel. Run `/adr enable` first.",
                    }),
                  });
                }
                return;
              }

              // Create ADR via RPC
              const userId = payload.user?.id ?? "unknown";
              const createResp = await fetch(
                `${supabaseUrl}/rest/v1/rpc/create_adr`,
                {
                  method: "POST",
                  headers: {
                    "Content-Type": "application/json",
                    apikey: serviceRoleKey,
                    Authorization: `Bearer ${serviceRoleKey}`,
                  },
                  body: JSON.stringify({
                    p_team_id: teamId,
                    p_channel_id: channelId,
                    p_created_by: userId,
                    p_title: fields.title,
                    p_context_text: fields.context_text,
                    p_thread_ts: threadTs || null,
                    p_decision: fields.decision || null,
                    p_alternatives: fields.alternatives || null,
                    p_consequences: fields.consequences || null,
                    p_open_questions: fields.open_questions || null,
                    p_decision_drivers: fields.decision_drivers || null,
                    p_implementation_plan: fields.implementation_plan || null,
                    p_reviewers: fields.reviewers || null,
                  }),
                },
              );

              if (!createResp.ok) {
                const errText = await createResp.text();
                console.error("create_adr RPC failed:", createResp.status, errText);
                if (responseUrl) {
                  await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      replace_original: false,
                      text: "Failed to create ADR. Please try again.",
                    }),
                  });
                }
                return;
              }

              const adr = await createResp.json();
              const adrId = adr?.id ?? "unknown";

              // Post confirmation in thread
              if (responseUrl) {
                await fetch(responseUrl, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({
                    replace_original: false,
                    text: `ADR *${adrId}: ${fields.title}* created from Canvas. Use \`/adr view ${adrId}\` to see it.`,
                  }),
                });
              }
            } catch (err) {
              console.error("finalize_adr_from_canvas background error:", err);
              if (responseUrl) {
                try {
                  await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({
                      replace_original: false,
                      text: "Something went wrong finalizing the ADR. Please try again.",
                    }),
                  });
                } catch { /* last resort */ }
              }
            }
          })();

          // deno-lint-ignore no-explicit-any
          (globalThis as any).EdgeRuntime?.waitUntil?.(bgWork);
          bgWork.catch((err) => console.error("Unhandled finalize_adr_from_canvas error:", err));
          return new Response("", { status: 200 });
        }

        // Other block actions → fire-and-forget to RPC, post result to response_url
        const bgWork = (async () => {
          try {
            const resp = await fetch(
              `${supabaseUrl}/rest/v1/rpc/handle_slack_webhook`,
              {
                method: "POST",
                headers: rpcHeaders(req),
                body: rpcBody(body),
              },
            );

            if (responseUrl) {
              if (resp.ok) {
                const webhookResult = await resp.json();
                if (webhookResult) {
                  const postResp = await fetch(responseUrl, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify(webhookResult),
                  });
                  if (!postResp.ok) {
                    console.error("response_url post failed:", postResp.status, await postResp.text().catch(() => ""));
                  }
                }
              } else {
                // Post error back to user via response_url
                const errText = await resp.text();
                console.error("RPC failed:", resp.status, errText);
                await fetch(responseUrl, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({
                    replace_original: false,
                    text: "Something went wrong processing that action. Please try again.",
                  }),
                });
              }
            }
          } catch (err) {
            console.error("Background block_actions processing failed:", err);
            if (responseUrl) {
              try {
                await fetch(responseUrl, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({
                    replace_original: false,
                    text: "Something went wrong. Please try again.",
                  }),
                });
              } catch { /* last resort — nothing we can do */ }
            }
          }
        })();

        // Don't await — acknowledge immediately. Catch to surface errors.
        bgWork.catch((err) => console.error("Unhandled bgWork error:", err));
        return new Response("", { status: 200 });
      }
    }

    // Path 3: Default — forward raw body to PostgREST
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/rpc/handle_slack_webhook`,
      { method: "POST", headers: rpcHeaders(req), body: rpcBody(body) },
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
