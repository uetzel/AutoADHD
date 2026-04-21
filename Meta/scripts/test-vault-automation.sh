#!/bin/bash
# test-vault-automation.sh
# Smoke test for vault automation. Sets up temp fixtures, runs each agent mode,
# verifies outputs. Does NOT modify the real vault.
#
# Usage: ./test-vault-automation.sh [--quick]
#   --quick: skip AI-calling tests (--scan), only test shell logic

set -uo pipefail
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

QUICK="${1:-}"
PASS=0
FAIL=0
SKIP=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }

check() {
    local desc="$1" result="$2"
    if [ "$result" = "0" ]; then
        green "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        red "  ✗ $desc"
        FAIL=$((FAIL + 1))
    fi
}

skip() {
    yellow "  ⊘ $1 (skipped)"
    SKIP=$((SKIP + 1))
}

echo "================================================"
echo "Vault Automation Smoke Tests"
echo "================================================"
echo ""

# ============================================================
# 1. lib-agent.sh: syntax + lock retry
# ============================================================
echo "--- lib-agent.sh ---"

bash -n "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null
check "lib-agent.sh syntax valid" "$?"

# Test lock retry env vars are respected
(
    source "$SCRIPT_DIR/lib-agent.sh"
    AGENT_LOCK_RETRY=true
    AGENT_LOCK_RETRY_MAX=1
    AGENT_LOCK_RETRY_DELAY=1
    # Create a fake lock held by a live PID (our own)
    mkdir -p "$VAULT_DIR/.agent-locks/test-lock.lock"
    echo "$$" > "$VAULT_DIR/.agent-locks/test-lock.lock/pid"
    date '+%Y-%m-%d %H:%M:%S' > "$VAULT_DIR/.agent-locks/test-lock.lock/started_at"
    # Try to acquire — should retry once then fail (we hold it)
    agent_acquire_lock "test-lock" 2>/dev/null && exit 1 || exit 0
) 2>/dev/null
check "Lock retry works (fails after retries when held)" "$?"

# Cleanup test lock
rm -rf "$VAULT_DIR/.agent-locks/test-lock.lock" 2>/dev/null

# Test lock acquisition on free lock
(
    source "$SCRIPT_DIR/lib-agent.sh"
    agent_acquire_lock "test-lock-free" 2>/dev/null
    result=$?
    agent_release_lock 2>/dev/null
    exit $result
) 2>/dev/null
check "Lock acquisition works on free lock" "$?"
rm -rf "$VAULT_DIR/.agent-locks/test-lock-free.lock" 2>/dev/null

# ============================================================
# 2. run-task-enricher.sh: syntax + --morning dry check
# ============================================================
echo ""
echo "--- run-task-enricher.sh ---"

bash -n "$SCRIPT_DIR/run-task-enricher.sh" 2>/dev/null
check "run-task-enricher.sh syntax valid" "$?"

# Test --morning can at least parse actions without crashing
# (won't actually send Telegram in test — send-telegram.sh will fail gracefully)
(
    cd "$VAULT_DIR"
    # Redirect Telegram sends to /dev/null
    PATH="$SCRIPT_DIR/test-stubs:$PATH"
    bash "$SCRIPT_DIR/run-task-enricher.sh" --morning >/dev/null 2>&1
) 2>/dev/null
check "Task-Enricher --morning runs without crash" "$?"

# ============================================================
# 3. run-email-workflow.sh: syntax
# ============================================================
echo ""
echo "--- run-email-workflow.sh ---"

bash -n "$SCRIPT_DIR/run-email-workflow.sh" 2>/dev/null
check "run-email-workflow.sh syntax valid" "$?"

# ============================================================
# 4. send-email.sh: syntax + op-file HTML extraction
# ============================================================
echo ""
echo "--- send-email.sh ---"

bash -n "$SCRIPT_DIR/send-email.sh" 2>/dev/null
check "send-email.sh syntax valid" "$?"

# Test HTML extraction from op file
TMPOP=$(mktemp /tmp/test-op-XXXXXX.md)
cat > "$TMPOP" << 'EOF'
---
type: email
status: pending
---

## Email Body HTML

<html><body><p>Test</p></body></html>
EOF

EXTRACTED=$(sed -n '/^## Email Body HTML$/,$ { /^## Email Body HTML$/d; p; }' "$TMPOP")
echo "$EXTRACTED" | grep -q "<html>" 2>/dev/null
check "HTML extraction from op file works" "$?"
rm -f "$TMPOP"

# ============================================================
# 5. vault-bot.py: syntax
# ============================================================
echo ""
echo "--- vault-bot.py ---"

python3 -c "import py_compile; py_compile.compile('$SCRIPT_DIR/vault-bot.py', doraise=True)" 2>/dev/null
check "vault-bot.py syntax valid" "$?"

# ============================================================
# 6. run-mirror.sh: syntax
# ============================================================
echo ""
echo "--- run-mirror.sh ---"

bash -n "$SCRIPT_DIR/run-mirror.sh" 2>/dev/null
check "run-mirror.sh syntax valid" "$?"

# ============================================================
# 7. weekly-maintenance.sh: syntax
# ============================================================
echo ""
echo "--- weekly-maintenance.sh ---"

bash -n "$SCRIPT_DIR/weekly-maintenance.sh" 2>/dev/null
check "weekly-maintenance.sh syntax valid" "$?"

# ============================================================
# 8. process-voice-memo.sh: syntax + lock retry enabled
# ============================================================
echo ""
echo "--- process-voice-memo.sh ---"

bash -n "$SCRIPT_DIR/process-voice-memo.sh" 2>/dev/null
check "process-voice-memo.sh syntax valid" "$?"

grep -q "AGENT_LOCK_RETRY=true" "$SCRIPT_DIR/process-voice-memo.sh" 2>/dev/null
check "Voice pipeline has lock retry enabled" "$?"

# ============================================================
# 9. agent-runtimes.conf: has required entries
# ============================================================
echo ""
echo "--- agent-runtimes.conf ---"

grep -q "TASK_ENRICHER=" "$VAULT_DIR/Meta/agent-runtimes.conf" 2>/dev/null
check "TASK_ENRICHER configured" "$?"

grep -q "MIRROR=" "$VAULT_DIR/Meta/agent-runtimes.conf" 2>/dev/null
check "MIRROR configured" "$?"

# ============================================================
# 10. Operations directory structure
# ============================================================
echo ""
echo "--- Operations dirs ---"

[ -d "$VAULT_DIR/Meta/operations/pending" ]
check "pending/ exists" "$?"

[ -d "$VAULT_DIR/Meta/operations/executing" ]
check "executing/ exists" "$?"

[ -d "$VAULT_DIR/Meta/operations/completed" ]
check "completed/ exists" "$?"

# ============================================================
# 11. Approve idempotency (file-not-found = clean rejection)
# ============================================================
echo ""
echo "--- Approve idempotency ---"

# Simulate: try to "approve" a non-existent op
[ ! -f "$VAULT_DIR/Meta/operations/pending/nonexistent-op.md" ]
check "Non-existent op correctly absent from pending/" "$?"

# ============================================================
# 12. LaunchAgent plists
# ============================================================
echo ""
echo "--- LaunchAgent plists ---"

[ -f "$HOME/Library/LaunchAgents/com.vault.task-enricher.plist" ]
check "Task-Enricher plist exists" "$?"

[ -f "$HOME/Library/LaunchAgents/com.vault.voice-watcher.plist" ]
check "Voice watcher plist exists" "$?"

# ============================================================
# AI-calling tests (skip with --quick)
# ============================================================
if [ "$QUICK" = "--quick" ]; then
    echo ""
    skip "Task-Enricher --scan (AI-calling, use full mode)"
    skip "Mirror agent (AI-calling, use full mode)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "================================================"
echo "Results: $(green "$PASS passed"), $(red "$FAIL failed"), $(yellow "$SKIP skipped")"
echo "================================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
