#!/bin/bash
# Smoke test for Task-Enricher decompose/execute modes
# Validates: script modes exist, frontmatter parsing, bot integration
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

echo "=== Enricher Decompose Smoke Tests ==="

# 1. Script exists and supports new modes
echo "--- Mode checks ---"
[ -x "$SCRIPT_DIR/run-task-enricher.sh" ] && pass "run-task-enricher.sh is executable" || fail "not executable"
grep -q "\-\-decompose" "$SCRIPT_DIR/run-task-enricher.sh" && pass "--decompose mode exists" || fail "--decompose missing"
grep -q "\-\-execute" "$SCRIPT_DIR/run-task-enricher.sh" && pass "--execute mode exists" || fail "--execute missing"
grep -q "\-\-status" "$SCRIPT_DIR/run-task-enricher.sh" && pass "--status mode exists" || fail "--status missing"
grep -q "\-\-redecompose" "$SCRIPT_DIR/run-task-enricher.sh" && pass "--redecompose mode exists" || fail "--redecompose missing"

# 2. Spec updated
echo "--- Spec checks ---"
grep -q "decompose" "$VAULT_DIR/Meta/Agents/Task-Enricher.md" && pass "Task-Enricher spec has decompose" || fail "spec missing decompose"
grep -q "execution_type" "$VAULT_DIR/Meta/Agents/Task-Enricher.md" && pass "spec has execution_type" || fail "spec missing execution_type"
grep -q "parent_action" "$VAULT_DIR/Meta/Agents/Task-Enricher.md" && pass "spec has parent_action" || fail "spec missing parent_action"

# 3. Directories exist
echo "--- Directory checks ---"
[ -d "$VAULT_DIR/Meta/decomposer/pending-input" ] && pass "pending-input/ exists" || fail "pending-input/ missing"
[ -d "$VAULT_DIR/Meta/decomposer/answers" ] && pass "answers/ exists" || fail "answers/ missing"

# 4. Calendar bridge
echo "--- Calendar bridge ---"
[ -x "$SCRIPT_DIR/create-calendar-op.sh" ] && pass "create-calendar-op.sh executable" || fail "create-calendar-op.sh missing"
[ -x "$SCRIPT_DIR/calendar-create.sh" ] && pass "calendar-create.sh executable" || fail "calendar-create.sh missing"

# 5. Bot integration
echo "--- Bot integration ---"
grep -q 'CommandHandler("decompose"' "$SCRIPT_DIR/vault-bot.py" && pass "cmd_decompose registered" || fail "cmd_decompose not registered"
grep -q 'CommandHandler("steps"' "$SCRIPT_DIR/vault-bot.py" && pass "cmd_steps registered" || fail "cmd_steps not registered"
grep -q 'CommandHandler("replan"' "$SCRIPT_DIR/vault-bot.py" && pass "cmd_replan registered" || fail "cmd_replan not registered"
grep -q 'run_executor' "$SCRIPT_DIR/vault-bot.py" && pass "run_executor exists" || fail "run_executor missing"
grep -q 'decomposer_executor' "$SCRIPT_DIR/vault-bot.py" && pass "executor job_queue registered" || fail "executor job_queue missing"
grep -q 'decomposer_input' "$SCRIPT_DIR/vault-bot.py" && pass "input collection routing exists" || fail "input collection missing"

# 6. asyncio.to_thread retrofit
echo "--- Async retrofit ---"
grep -q 'asyncio.to_thread' "$SCRIPT_DIR/vault-bot.py" && pass "asyncio.to_thread used" || fail "asyncio.to_thread missing"
# Count usages (should be at least 6: advisor, email, think, briefing, voice, extractor)
ASYNC_COUNT=$(grep -c 'asyncio.to_thread' "$SCRIPT_DIR/vault-bot.py")
[ "$ASYNC_COUNT" -ge 6 ] && pass "asyncio.to_thread used $ASYNC_COUNT times (>=6)" || fail "asyncio.to_thread only $ASYNC_COUNT times (<6)"

# 7. Calendar type in cmd_approve
echo "--- Calendar approval ---"
grep -q 'op_type == "calendar"' "$SCRIPT_DIR/vault-bot.py" && pass "calendar type in cmd_approve" || fail "calendar type missing from cmd_approve"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
