# ADR Bot — Deploy Checklist

## Prerequisites

- [ ] Supabase account (free tier works)
- [ ] Slack workspace with admin access
- [ ] GitHub repo for ADR exports (e.g. `myorg/architecture`)
- [ ] GitHub PAT with `repo` scope
- [ ] Supabase CLI installed (`npm i -g supabase`)

## 1. Create Supabase Project

- [ ] Go to [supabase.com/dashboard](https://supabase.com/dashboard) → **New Project**
- [ ] Note your **project ref** (e.g. `abcdefghijkl`)
- [ ] Note your **service role key** (Settings → API → Service Role Key)
- [ ] Note your **project URL** (`https://<ref>.supabase.co`)

## 2. Create Slack App

- [ ] Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**
- [ ] Paste contents of `slack-app-manifest.yaml`
- [ ] Replace all `<PROJECT_REF>` with your Supabase project ref
- [ ] Install to your workspace
- [ ] Note your **Bot Token** (`xoxb-...`) from OAuth & Permissions
- [ ] Note your **Signing Secret** from Basic Information

## 3. Store Secrets in Supabase Vault

Run these in the Supabase SQL Editor (Dashboard → SQL Editor):

```sql
SELECT vault.create_secret('xoxb-your-bot-token',    'SLACK_BOT_TOKEN');
SELECT vault.create_secret('your-signing-secret',     'SLACK_SIGNING_SECRET');
SELECT vault.create_secret('ghp_your_github_token',   'GITHUB_TOKEN');
SELECT vault.create_secret('myorg',                   'GITHUB_REPO_OWNER');
SELECT vault.create_secret('architecture',            'GITHUB_REPO_NAME');
SELECT vault.create_secret('main',                    'GITHUB_DEFAULT_BRANCH');
SELECT vault.create_secret('https://abcdefghijkl.supabase.co', 'SUPABASE_URL');
SELECT vault.create_secret('eyJ...your-service-role-key...', 'SUPABASE_SERVICE_ROLE_KEY');
```

## 4. Push Database Migrations

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

This creates all tables, functions, cron jobs, and RLS policies (41 migrations).

## 5. Deploy Edge Functions

```bash
supabase functions deploy slack-proxy --no-verify-jwt
supabase functions deploy event-proxy --no-verify-jwt
supabase functions deploy git-export --no-verify-jwt
```

`--no-verify-jwt` is required because Slack sends its own auth (HMAC signatures), not Supabase JWTs.

## 6. Set Edge Function Secrets

```bash
supabase secrets set \
  SLACK_BOT_TOKEN=xoxb-your-bot-token \
  SUPABASE_URL=https://abcdefghijkl.supabase.co \
  SUPABASE_SERVICE_ROLE_KEY=eyJ...your-service-role-key... \
  GITHUB_TOKEN=ghp_your_github_token \
  GITHUB_REPO_OWNER=myorg \
  GITHUB_REPO_NAME=architecture \
  GITHUB_DEFAULT_BRANCH=main
```

## 7. Verify Cron Jobs

In the SQL Editor, confirm all cron jobs were created:

```sql
SELECT jobname, schedule, command FROM cron.job ORDER BY jobid;
```

Expected jobs:

| Job | Schedule | Purpose |
|---|---|---|
| `process-outbox` | `*/30 * * * * *` | Deliver Slack messages + git exports |
| `check-outbox-deliveries` | `*/30 * * * * *` | Confirm delivery, retry failures |
| `capture-thread-ts` | `*/30 * * * * *` | Extract Slack thread timestamps |
| `dead-letter-outbox` | `*/5 * * * *` | Mark exhausted retries |
| `purge-old-outbox` | `0 3 * * *` | Clean delivered rows >30 days |
| `cleanup-rate-limit-buckets` | `*/10 * * * *` | Prune expired rate limit windows |

## 8. Smoke Test

In any Slack channel:

1. `/adr help` — should show usage
2. `/adr enable` — should enable the channel (shows privacy notice)
3. `/adr start` — should open a modal to create an ADR
4. Fill in Title + Context, submit — should post Block Kit message
5. Click **Accept** button — should transition to ACCEPTED
6. `/adr list` — should show the ADR
7. `/adr history <id>` — should show event timeline
8. `/adr export <id>` — should create a GitHub PR (check your repo)

## Troubleshooting

### "not_authed" on modal open
The `SLACK_BOT_TOKEN` Edge Function secret is missing or wrong. Re-run `supabase secrets set`.

### Buttons don't respond
Check Edge Function logs: Dashboard → Edge Functions → slack-proxy → Logs. The outbox cron may not be running — verify with `SELECT * FROM cron.job`.

### Export creates no PR
Check `adr_outbox` for failed git-export rows:
```sql
SELECT id, attempts, last_error FROM adr_outbox
WHERE destination = 'git-export' AND delivered_at IS NULL;
```
Common cause: `GITHUB_TOKEN` doesn't have `repo` scope, or target repo doesn't exist.

### Messages not posting to threads
The `capture-thread-ts` cron extracts Slack `ts` from API responses. Check:
```sql
SELECT id, slack_message_ts FROM adrs WHERE slack_message_ts IS NULL;
```

### Rate limit errors
Clears automatically (10-minute windows). To manually reset:
```sql
DELETE FROM rate_limit_buckets;
```

## Architecture Summary

```
Slack → Edge Function (thin proxy) → PostgREST → SQL functions → outbox → pg_cron → Slack/GitHub
```

All business logic lives in PostgreSQL. Edge Functions only handle:
- Modal opening (3-second `trigger_id` constraint)
- GitHub API calls (sequential, multi-step)
- Content-Type rewriting for PostgREST

## Test Suite

Run locally against `supabase start`:

```bash
# SQL tests (263 tests)
for f in test/test_*.sql; do
  psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
    -v ON_ERROR_STOP=1 -f "$f"
done

# Smoke tests (60 tests)
bash test/smoke_test.sh
```
