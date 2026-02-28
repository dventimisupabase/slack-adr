// supabase/functions/git-export/index.ts
// Handles sequential GitHub API calls for ADR export.
// Called by the outbox processor via pg_net.
// Creates branch, commits markdown file, opens PR, calls back to PostgREST.

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const githubToken = Deno.env.get("GITHUB_TOKEN") ?? "";
const repoOwner = Deno.env.get("GITHUB_REPO_OWNER") ?? "";
const repoName = Deno.env.get("GITHUB_REPO_NAME") ?? "";
const defaultBranch = Deno.env.get("GITHUB_DEFAULT_BRANCH") ?? "main";

if (!supabaseUrl || !serviceRoleKey || !githubToken || !repoOwner || !repoName) {
  console.error(
    "Missing required env vars: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GITHUB_TOKEN, GITHUB_REPO_OWNER, GITHUB_REPO_NAME",
  );
}

const githubApi = "https://api.github.com";
const GITHUB_TIMEOUT_MS = 30_000;

async function githubFetch(
  path: string,
  options: RequestInit = {},
): Promise<Response> {
  const url = `${githubApi}${path}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GITHUB_TIMEOUT_MS);
  try {
    return await fetch(url, {
      ...options,
      signal: controller.signal,
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${githubToken}`,
        "X-GitHub-Api-Version": "2022-11-28",
        ...(options.headers ?? {}),
      },
    });
  } finally {
    clearTimeout(timer);
  }
}

function slugify(title: string): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 50);
  return slug || "untitled";
}

async function exportToGitHub(
  adrId: string,
  title: string,
  markdown: string,
): Promise<{ pr_url: string; branch: string }> {
  const date = new Date().toISOString().slice(0, 10);
  const slug = slugify(title);
  const branchName = `adr/${date}-${slug}`;
  const filePath = `docs/adr/${adrId}.md`;

  // 1. Get base branch SHA
  const refResp = await githubFetch(
    `/repos/${repoOwner}/${repoName}/git/ref/heads/${defaultBranch}`,
  );
  if (!refResp.ok) {
    throw new Error(
      `Failed to get base branch: ${refResp.status} ${await refResp.text()}`,
    );
  }
  const refData = await refResp.json();
  const baseSha = refData.object.sha;

  // 2. Create branch
  const createRefResp = await githubFetch(
    `/repos/${repoOwner}/${repoName}/git/refs`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ref: `refs/heads/${branchName}`,
        sha: baseSha,
      }),
    },
  );
  if (!createRefResp.ok) {
    const errText = await createRefResp.text();
    // Branch might already exist — try to continue
    if (!errText.includes("Reference already exists")) {
      throw new Error(`Failed to create branch: ${createRefResp.status} ${errText}`);
    }
  }

  // 3. Create (or update) file on the branch
  // First check if file exists to get its sha
  const existingResp = await githubFetch(
    `/repos/${repoOwner}/${repoName}/contents/${filePath}?ref=${encodeURIComponent(branchName)}`,
  );
  let existingSha: string | undefined;
  if (existingResp.ok) {
    const existingData = await existingResp.json();
    existingSha = existingData.sha;
  }

  // Encode UTF-8 markdown to base64 for GitHub API
  const bytes = new TextEncoder().encode(markdown);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  const content = btoa(binary);

  const createFileResp = await githubFetch(
    `/repos/${repoOwner}/${repoName}/contents/${filePath}`,
    {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        message: `Add ${adrId}: ${title}`,
        content,
        branch: branchName,
        ...(existingSha ? { sha: existingSha } : {}),
      }),
    },
  );
  if (!createFileResp.ok) {
    throw new Error(
      `Failed to create file: ${createFileResp.status} ${await createFileResp.text()}`,
    );
  }

  // 4. Open pull request
  const prResp = await githubFetch(
    `/repos/${repoOwner}/${repoName}/pulls`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: `${adrId}: ${title}`,
        head: branchName,
        base: defaultBranch,
        body: `## Architectural Decision Record\n\n**${adrId}**: ${title}\n\nExported from Slack ADR Bot.`,
      }),
    },
  );
  if (!prResp.ok) {
    const errText = await prResp.text();
    // PR might already exist
    if (errText.includes("A pull request already exists")) {
      // Try to find the existing PR
      const searchResp = await githubFetch(
        `/repos/${repoOwner}/${repoName}/pulls?head=${repoOwner}:${encodeURIComponent(branchName)}&state=open`,
      );
      if (searchResp.ok) {
        const prs = await searchResp.json();
        if (prs.length > 0) {
          return { pr_url: prs[0].html_url, branch: branchName };
        }
      }
    }
    throw new Error(`Failed to create PR: ${prResp.status} ${errText}`);
  }

  const prData = await prResp.json();
  return { pr_url: prData.html_url, branch: branchName };
}

async function sendCallback(
  adrId: string,
  status: "complete" | "failed",
  data: Record<string, string>,
): Promise<void> {
  const payload = JSON.stringify({ adr_id: adrId, status, ...data });
  const maxRetries = 3;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const resp = await fetch(
        `${supabaseUrl}/rest/v1/rpc/handle_git_export_callback`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            apikey: serviceRoleKey,
            Authorization: `Bearer ${serviceRoleKey}`,
            "x-export-api-key": serviceRoleKey,
          },
          body: JSON.stringify({ raw_body: payload }),
        },
      );
      if (resp.ok) return;
      const errText = await resp.text();
      console.error(
        `Callback attempt ${attempt}/${maxRetries} failed:`,
        resp.status,
        errText,
      );
    } catch (err) {
      console.error(
        `Callback attempt ${attempt}/${maxRetries} error:`,
        err,
      );
    }
    if (attempt < maxRetries) {
      await new Promise((r) => setTimeout(r, attempt * 1000));
    }
  }
  console.error(
    `Callback for ${adrId} (${status}) failed after ${maxRetries} attempts`,
  );
}

Deno.serve(async (req: Request) => {
  try {
    const body = await req.text();
    const payload = JSON.parse(body);

    const adrId = payload.adr_id;
    const title = payload.title;
    const markdown = payload.markdown;

    if (!adrId || !markdown) {
      return new Response(
        JSON.stringify({ error: "Missing adr_id or markdown" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    try {
      const result = await exportToGitHub(adrId, title ?? adrId, markdown);
      await sendCallback(adrId, "complete", {
        pr_url: result.pr_url,
        branch: result.branch,
      });
      return new Response(
        JSON.stringify({ ok: true, pr_url: result.pr_url }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    } catch (exportErr) {
      console.error("Git export failed:", exportErr);
      await sendCallback(adrId, "failed", {
        error: String(exportErr),
      });
      return new Response(
        JSON.stringify({ ok: true, error: String(exportErr) }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }
  } catch (err) {
    console.error("git-export error:", err);
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
