// supabase/functions/event-proxy/index.ts
// Thin Deno proxy for Slack Events API.
// Handles url_verification directly (no DB round-trip).
// Forwards all other events to PostgREST RPC.

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req: Request) => {
  try {
    const body = await req.text();
    const payload = JSON.parse(body);

    // Handle URL verification challenge directly (no DB needed)
    if (payload.type === "url_verification") {
      return new Response(
        JSON.stringify({ challenge: payload.challenge }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    // Forward all other events to PostgREST RPC
    const resp = await fetch(
      `${supabaseUrl}/rest/v1/rpc/handle_slack_event`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
          "x-slack-signature": req.headers.get("x-slack-signature") ?? "",
          "x-slack-request-timestamp":
            req.headers.get("x-slack-request-timestamp") ?? "",
        },
        body: JSON.stringify({ raw_body: body }),
      },
    );

    const result = await resp.text();
    return new Response(result, {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("event-proxy error:", err);
    // Always return 200 to prevent Slack retries
    return new Response(
      JSON.stringify({ ok: true }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }
});
