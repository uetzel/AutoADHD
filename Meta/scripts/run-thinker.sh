#!/bin/bash
# run-thinker.sh
# Thinking partner agent — reads the vault, finds patterns, writes reflections
# Usage: ./run-thinker.sh [topic]  (optional topic to focus on)

set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"
DATE=$(date +%Y-%m-%d)
WEEK=$(date +%Y-W%V)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TOPIC="${1:-}"

# Failure notification via Telegram
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Thinker FAILED* at $(date '+%H:%M')
Reason: $1" 2>/dev/null || true
}

echo "[$TIMESTAMP] Running Thinker agent..."
[ -n "$TOPIC" ] && echo "  Focus topic: $TOPIC"

agent_require_commands git python3
agent_assert_clean_worktree "Thinker"
agent_acquire_lock "vault-agent-pipeline"

# Gather vault contents for context
PEOPLE=$(ls Canon/People/ 2>/dev/null | sed 's/.md$//')
EVENTS=$(ls Canon/Events/ 2>/dev/null | sed 's/.md$//')
CONCEPTS=$(ls Canon/Concepts/ 2>/dev/null | sed 's/.md$//')
ACTIONS=$(ls Canon/Actions/*.md 2>/dev/null | xargs -I{} basename {} .md)
REFLECTIONS=$(ls Meta/AI-Reflections/ 2>/dev/null | sed 's/.md$//')
RECENT_MEMOS=$(ls -t Inbox/Voice/*.md Inbox/Voice/_extracted/*.md 2>/dev/null | head -20 | xargs -I{} basename {} .md)

# Build focus prompt
if [ -n "$TOPIC" ]; then
    FOCUS="Focus this reflection on: $TOPIC. Read all vault content related to this topic and think deeply about it."
else
    FOCUS="Do a broad vault reflection. Look for patterns, connections, and insights across the entire vault."
fi

# Load agent spec from Meta/Agents/ (editable in Obsidian)
AGENT_SPEC=$(cat "Meta/Agents/Thinker.md" 2>/dev/null || echo "Read CLAUDE.md for rules.")

PROMPT="You are the THINKER agent — the vault's thinking partner.

Read CLAUDE.md for vault rules first.

## YOUR SPEC (from Meta/Agents/Thinker.md — the human can edit this)
$AGENT_SPEC

## FOCUS
$FOCUS

## VAULT CONTENTS
People: $PEOPLE
Events: $EVENTS
Concepts: $CONCEPTS
Actions: $ACTIONS
Previous reflections: $REFLECTIONS
Recent memos: $RECENT_MEMOS

## OUTPUT
Write your reflection to: Meta/AI-Reflections/$DATE - Thinker Reflection.md
Commit all changes with a descriptive message."

INVOKE_EXIT=0
INVOKE_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" thinker "$PROMPT" 2>&1) || INVOKE_EXIT=$?

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

# Fallback commit scoped to thinker-owned paths.
agent_stage_and_commit "[Thinker] reflect: fallback commit [$TIMESTAMP]" \
    Meta/AI-Reflections/ \
    Meta/review-queue/ \
    Meta/changelog.md

# Log to changelog
TOPIC_STR="${TOPIC:-broad vault reflection}"
"$SCRIPT_DIR/log-change.sh" "Thinker" "Reflection on: $TOPIC_STR → Meta/AI-Reflections/$DATE - Thinker Reflection.md"
agent_commit_changelog_if_needed "[Thinker] log: changelog update [$TIMESTAMP]"

"$SCRIPT_DIR/log-agent-feedback.sh" "Thinker" "reflection_complete" "Reflection on: $TOPIC_STR" "Meta/AI-Reflections/$DATE - Thinker Reflection.md" "" "true" 2>/dev/null || true

echo "[$TIMESTAMP] Thinker complete."
