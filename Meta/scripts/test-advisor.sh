#!/bin/bash
# Smoke test for Advisor agent
# Validates: run-advisor.sh exists, parses args, parse-advisor-output.py works
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

echo "=== Advisor Smoke Tests ==="

# 1. Scripts exist and are executable
echo "--- File checks ---"
[ -x "$SCRIPT_DIR/run-advisor.sh" ] && pass "run-advisor.sh is executable" || fail "run-advisor.sh not executable"
[ -x "$SCRIPT_DIR/parse-advisor-output.py" ] && pass "parse-advisor-output.py is executable" || fail "parse-advisor-output.py not executable"
[ -f "$VAULT_DIR/Meta/Agents/Advisor.md" ] && pass "Advisor.md spec exists" || fail "Advisor.md spec missing"

# 2. Agent runtime config has ADVISOR
echo "--- Config checks ---"
grep -q "^ADVISOR=" "$VAULT_DIR/Meta/agent-runtimes.conf" && pass "ADVISOR in runtimes.conf" || fail "ADVISOR missing from runtimes.conf"

# 3. parse-advisor-output.py handles structured output
echo "--- Parser tests ---"

# Happy path
OUTPUT=$(echo '---RESPONSE---
Hello, this is the advisor response.
---TRIGGERS---
RESEARCH: Hamburg AI freelance rates
LOG_DECISION: Test | Decided | Because | Nothing | 2026-05-01
---END---' | python3 "$SCRIPT_DIR/parse-advisor-output.py")

echo "$OUTPUT" | grep -q "Hello, this is the advisor response" && pass "Parser extracts response" || fail "Parser failed to extract response"
echo "$OUTPUT" | grep -q "RESEARCH" && pass "Parser extracts triggers" || fail "Parser failed to extract triggers"

# No triggers section
OUTPUT2=$(echo '---RESPONSE---
Just a simple answer.
---END---' | python3 "$SCRIPT_DIR/parse-advisor-output.py")

echo "$OUTPUT2" | grep -q "Just a simple answer" && pass "Parser handles no triggers" || fail "Parser failed with no triggers"

# Raw output (no delimiters)
OUTPUT3=$(echo 'This is raw output without any delimiters.' | python3 "$SCRIPT_DIR/parse-advisor-output.py")

echo "$OUTPUT3" | grep -q "raw output" && pass "Parser handles raw output" || fail "Parser failed with raw output"

# 4. Session directory exists
echo "--- Directory checks ---"
[ -d "$VAULT_DIR/Meta/advisor-sessions" ] && pass "advisor-sessions/ exists" || fail "advisor-sessions/ missing"

# 5. vault-bot.py has advisor commands registered
echo "--- Bot integration ---"
grep -q 'CommandHandler("ask"' "$SCRIPT_DIR/vault-bot.py" && pass "cmd_ask registered" || fail "cmd_ask not registered"
grep -q 'CommandHandler("strategy"' "$SCRIPT_DIR/vault-bot.py" && pass "cmd_strategy registered" || fail "cmd_strategy not registered"
grep -q 'advisor_session' "$SCRIPT_DIR/vault-bot.py" && pass "advisor session routing exists" || fail "advisor session routing missing"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
