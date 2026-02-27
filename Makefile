# Makefile for ADR Slack Bot
# Usage:
#   make test          — run all SQL + smoke tests
#   make test-sql      — run SQL tests only
#   make test-smoke    — run smoke tests only (Edge Functions must be running)
#   make reset         — db reset + SQL tests
#   make serve         — start Edge Functions
#   make reset-all     — db reset + all tests (starts/stops Edge Functions)

DB_URL := postgresql://postgres:postgres@127.0.0.1:54322/postgres
PASS := 0
FAIL := 0

.PHONY: test test-sql test-smoke reset serve reset-all

test: test-sql test-smoke

test-sql:
	@echo "=== Running SQL Tests ==="
	@pass=0; fail=0; \
	for f in test/test_*.sql; do \
		output=$$(psql "$(DB_URL)" -v ON_ERROR_STOP=1 -f "$$f" 2>&1); \
		rc=$$?; \
		count=$$(echo "$$output" | grep -c "PASS:" || true); \
		pass=$$((pass + count)); \
		if [ $$rc -ne 0 ]; then \
			fail=$$((fail + 1)); \
			echo "FAILED: $$f"; \
			echo "$$output" | grep -E "ERROR"; \
		fi; \
	done; \
	echo "=== $$pass SQL tests passed, $$fail files failed ==="; \
	[ $$fail -eq 0 ]

test-smoke:
	@echo "=== Running Smoke Tests ==="
	@bash test/smoke_test.sh

reset:
	supabase db reset
	@$(MAKE) test-sql

serve:
	supabase functions serve --no-verify-jwt

reset-all:
	supabase db reset
	@$(MAKE) test-sql
	@echo ""
	@echo "Starting Edge Functions for smoke tests..."
	@supabase functions serve --no-verify-jwt &
	@sleep 4
	@$(MAKE) test-smoke; rc=$$?; kill %1 2>/dev/null; exit $$rc
