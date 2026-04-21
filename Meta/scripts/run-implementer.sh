#!/bin/bash
# run-implementer.sh
# Self-healing loop — reads retro/reviewer findings and applies safe fixes
# Usage: ./run-implementer.sh [retro|reviewer]
# Triggered automatically after retro and reviewer runs

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HEAD_BEFORE_RUN=$(git rev-parse HEAD)
TRIGGER="${1:-manual}"

# Failure notification via Telegram
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Implementer FAILED* at $(date '+%H:%M')
Trigger: $TRIGGER
Reason: $1" 2>/dev/null || true
}

echo "[$TIMESTAMP] Running Implementer agent (triggered by: $TRIGGER)..."

agent_require_commands git python3
agent_assert_clean_worktree "Implementer"
agent_acquire_lock "vault-agent-pipeline"

# Load the latest findings based on trigger
RETRO_LATEST=""
REVIEW_LATEST=""

if [ -f "Meta/AI-Reflections/retro-log.md" ]; then
    # Get the last retro entry (from last ## Retro: header to end)
    RETRO_LATEST=$(awk '/^## Retro:/{buf=""} /^## Retro:/{found=1} found{buf=buf"\n"$0} END{print buf}' "Meta/AI-Reflections/retro-log.md")
fi

if [ -f "Meta/AI-Reflections/review-log.md" ]; then
    # Get the last review entry (from last ## Review: header to end)
    REVIEW_LATEST=$(awk '/^## Review:/{buf=""} /^## Review:/{found=1} found{buf=buf"\n"$0} END{print buf}' "Meta/AI-Reflections/review-log.md")
fi

# Load previous implementer actions to avoid re-fixing
IMPLEMENTER_HISTORY=""
if [ -f "Meta/AI-Reflections/implementer-log.md" ]; then
    IMPLEMENTER_HISTORY=$(tail -100 "Meta/AI-Reflections/implementer-log.md")
fi

# Load agent spec
AGENT_SPEC=$(cat "Meta/Agents/Implementer.md" 2>/dev/null || echo "Read Meta/Architecture.md for rules.")

# Load architecture for review gate tiers
ARCHITECTURE=$(cat "Meta/Architecture.md" 2>/dev/null || echo "")

PROMPT="You are the IMPLEMENTER agent for this Obsidian vault.

Read CLAUDE.md for vault rules first. Then read Meta/Architecture.md for the system blueprint.

## YOUR SPEC (from Meta/Agents/Implementer.md)
$AGENT_SPEC

## ARCHITECTURE (review gate tiers)
$ARCHITECTURE

## LATEST RETRO FINDINGS
$RETRO_LATEST

## LATEST REVIEW FINDINGS
$REVIEW_LATEST

## PREVIOUS IMPLEMENTER ACTIONS (don't re-fix these)
$IMPLEMENTER_HISTORY

## YOUR JOB
1. Read all findings from the latest retro and review entries
2. For each finding, classify: Tier 1 (auto-fix), Tier 2 (fix + notify), or Tier 3 (queue for human)
3. Apply ALL Tier 1 fixes immediately — edit the actual files
4. Apply Tier 2 fixes and note them for Telegram notification
5. Create review-queue files for Tier 3 items
6. Run build-manifest.sh if you changed Canon files
7. Append a summary to Meta/AI-Reflections/implementer-log.md (APPEND, never overwrite)
8. Do NOT run git add or git commit. Leave changes in the worktree for the runner to log and commit.

CRITICAL RULES:
- Never touch locked fields
- Never delete Canon entries without human approval
- Never re-fix something already in the implementer log
- Always verify your fix actually works before committing
- If a finding has been flagged 3+ retros in a row and is still unfixed, that's HIGH urgency

Triggered by: $TRIGGER run at $TIMESTAMP"

INVOKE_EXIT=0
INVOKE_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" implementer "$PROMPT" 2>&1) || INVOKE_EXIT=$?

if [ "$INVOKE_EXIT" -ne 0 ]; then
    ERROR_DETAIL=""
    if echo "$INVOKE_OUTPUT" | grep -qi "not logged in"; then
        ERROR_DETAIL="Auth failed — CLI not logged in from this context"
    elif echo "$INVOKE_OUTPUT" | grep -qi "not a git repository"; then
        ERROR_DETAIL="TCC/git error — can't access .git under launchd (exit $INVOKE_EXIT)"
    elif echo "$INVOKE_OUTPUT" | grep -qi "rate limit\|429"; then
        ERROR_DETAIL="Rate limited — too many API calls"
    elif echo "$INVOKE_OUTPUT" | grep -qi "overloaded\|529"; then
        ERROR_DETAIL="API overloaded — servers busy"
    elif echo "$INVOKE_OUTPUT" | grep -qi "token\|context.*length\|too long"; then
        ERROR_DETAIL="Token limit exceeded — prompt too large"
    else
        LAST_LINES=$(echo "$INVOKE_OUTPUT" | tail -2 | tr '\n' ' ')
        ERROR_DETAIL="exit $INVOKE_EXIT — $LAST_LINES"
    fi
    notify_failure "$ERROR_DETAIL"
    exit 1
fi
echo "$INVOKE_OUTPUT"

# Log to changelog
FIXES=$(git diff --name-only "$HEAD_BEFORE_RUN" 2>/dev/null | wc -l | tr -d ' ')
"$SCRIPT_DIR/log-change.sh" "Implementer" "Self-healing pass ($TRIGGER): ${FIXES} files touched"

# Commit implementer-owned paths, including the changelog entry.
agent_stage_and_commit "[Implementer] fix: $TRIGGER run [$TIMESTAMP]" \
    Inbox/ \
    Canon/ \
    Thinking/ \
    Meta/Agents/ \
    Meta/AI-Reflections/ \
    Meta/review-queue/ \
    Meta/MANIFEST.md \
    Meta/changelog.md

# Build a rich summary of what changed
CHANGED_FILES=$(git diff --name-only "$HEAD_BEFORE_RUN" 2>/dev/null || true)
FIXES=$(echo "$CHANGED_FILES" | grep -c '.' 2>/dev/null || echo "0")

# Categorize changes for the human
CANON_CHANGES=$(echo "$CHANGED_FILES" | grep '^Canon/' | sed 's|^Canon/||; s|\.md$||' | head -5)
REVIEW_ITEMS=$(echo "$CHANGED_FILES" | grep '^Meta/review-queue/' | sed 's|^Meta/review-queue/||; s|\.md$||' | head -3)
SCRIPT_CHANGES=$(echo "$CHANGED_FILES" | grep '^Meta/scripts/' | sed 's|^Meta/scripts/||' | head -3)
AGENT_CHANGES=$(echo "$CHANGED_FILES" | grep '^Meta/Agents/' | sed 's|^Meta/Agents/||; s|\.md$||' | head -3)

# Notify with full context
if [ "$FIXES" -gt 0 ]; then
    MSG="🔧 Implementer done ($TRIGGER)\n"
    MSG="${MSG}${FIXES} files touched\n"

    if [ -n "$CANON_CHANGES" ]; then
        MSG="${MSG}\n📝 Updated:\n"
        while IFS= read -r f; do
            [ -n "$f" ] && MSG="${MSG}  • ${f}\n"
        done <<< "$CANON_CHANGES"
    fi

    if [ -n "$REVIEW_ITEMS" ]; then
        MSG="${MSG}\n❓ Queued for your review:\n"
        while IFS= read -r f; do
            [ -n "$f" ] && MSG="${MSG}  • ${f}\n"
        done <<< "$REVIEW_ITEMS"
        MSG="${MSG}Use /review to see them.\n"
    fi

    if [ -n "$SCRIPT_CHANGES" ]; then
        MSG="${MSG}\n⚙️ Scripts: $(echo "$SCRIPT_CHANGES" | tr '\n' ', ' | sed 's/, $//')\n"
    fi

    if [ -n "$AGENT_CHANGES" ]; then
        MSG="${MSG}\n🤖 Agent specs: $(echo "$AGENT_CHANGES" | tr '\n' ', ' | sed 's/, $//')\n"
    fi

    MSG="${MSG}\nCheck Meta/AI-Reflections/implementer-log.md for details."

    "$SCRIPT_DIR/send-telegram.sh" "$(echo -e "$MSG")" 2>/dev/null || true
else
    echo "[$TIMESTAMP] No changes made."
fi

# Log to agent feedback queue
"$SCRIPT_DIR/log-agent-feedback.sh" \
    "Implementer" \
    "implementer_complete" \
    "Self-healing pass ($TRIGGER): ${FIXES} files touched" \
    "" \
    "$(echo "$CHANGED_FILES" | head -5 | tr '\n' ',')" \
    "true" 2>/dev/null || true

echo "[$TIMESTAMP] Implementer complete."
