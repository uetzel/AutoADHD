#!/bin/bash
# weekly-maintenance.sh
# Runs every Sunday: temperature update → manifest rebuild → thinker reflection
# This is the weekly cadence stolen from COG's temporal design:
#   Daily: extract (per-memo, automatic)
#   Weekly: patterns + temperature + maintenance (this script)
#   Monthly: deep synthesis (manual trigger or scheduled)

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"
cd "$VAULT_DIR"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
echo "[$TIMESTAMP] Weekly maintenance starting..."

agent_require_commands git
agent_assert_clean_worktree "Weekly maintenance"
agent_acquire_lock "vault-agent-pipeline"

# Step 1: Update note temperatures
echo "--- Step 1: Temperature Update ---"
"$SCRIPT_DIR/update-temperature.sh"

# Step 2: Rebuild manifest
echo "--- Step 2: Manifest Rebuild ---"
/bin/bash "$SCRIPT_DIR/build-manifest.sh"

# Step 3: Run Thinker agent
echo "--- Step 3: Thinker Reflection ---"
/bin/bash "$SCRIPT_DIR/run-thinker.sh"

# Step 4: Run Reviewer for overall vault QA
echo "--- Step 4: Reviewer QA ---"
/bin/bash "$SCRIPT_DIR/run-reviewer.sh"

# (Mirror removed per 2026-04-07 simplification — not essential for core loop)

# Step 5: Commit only weekly-maintenance owned paths
agent_stage_and_commit "[Maintenance] weekly: temperature, manifest, reflection, review [$TIMESTAMP]" \
    Canon/ \
    Meta/MANIFEST.md \
    Meta/AI-Reflections/ \
    Meta/review-queue/ \
    Meta/changelog.md

echo "[$TIMESTAMP] Weekly maintenance complete."
