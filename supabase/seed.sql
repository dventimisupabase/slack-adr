-- seed.sql
-- Local development setup: insert secrets into vault.
-- These are ONLY for local development. Production uses real vault secrets.

-- Slack secrets
SELECT vault.create_secret('xoxb-local-dev-token', 'SLACK_BOT_TOKEN');
SELECT vault.create_secret('local-dev-signing-secret', 'SLACK_SIGNING_SECRET');

-- GitHub secrets
SELECT vault.create_secret('ghp_local_dev_token', 'GITHUB_TOKEN');
SELECT vault.create_secret('myorg', 'GITHUB_REPO_OWNER');
SELECT vault.create_secret('architecture', 'GITHUB_REPO_NAME');
SELECT vault.create_secret('main', 'GITHUB_DEFAULT_BRANCH');

-- Supabase self-reference (for outbox → git-export Edge Function)
SELECT vault.create_secret('http://127.0.0.1:54321', 'SUPABASE_URL');
SELECT vault.create_secret('eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU', 'SUPABASE_SERVICE_ROLE_KEY');
