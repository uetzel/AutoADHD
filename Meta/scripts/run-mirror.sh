#!/bin/bash
# run-mirror.sh
# Mirror agent — reflects Usman's patterns, strengths, growth edges
# Usage: ./run-mirror.sh [topic]
# Runs weekly after Thinker, or on-demand with optional topic focus

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

DATE=$(date +%Y-%m-%d)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TOPIC="${1:-}"

source "$SCRIPT_DIR/lib-agent.sh"

# Failure notification via Telegram
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Mirror FAILED* at $(date '+%H:%M')
Reason: $1" 2>/dev/null || true
}

echo "[$TIMESTAMP] Running Mirror agent..."

agent_require_commands git
agent_assert_clean_worktree "Mirror"
agent_acquire_lock "vault-agent-pipeline"
HEAD_BEFORE_RUN=$(agent_git rev-parse HEAD)

# Load agent spec
AGENT_SPEC=$(cat "Meta/Agents/Mirror.md" 2>/dev/null || echo "Read Meta/Architecture.md")

# Gather action stats
TOTAL_ACTIONS=$(find Canon/Actions/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
OPEN_ACTIONS=$(grep -rl "status: open" Canon/Actions/ 2>/dev/null | wc -l | tr -d ' ')
DONE_ACTIONS=$(grep -rl "status: done" Canon/Actions/ 2>/dev/null | wc -l | tr -d ' ')
DROPPED_ACTIONS=$(grep -rl "status: dropped" Canon/Actions/ 2>/dev/null | wc -l | tr -d ' ')

# Get action details (names + status + due dates)
ACTION_DETAILS=""
for f in Canon/Actions/*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .md)
    status=$(grep -m1 "^status:" "$f" 2>/dev/null | sed 's/status: *//' || echo "unknown")
    due=$(grep -m1 "^due:" "$f" 2>/dev/null | sed 's/due: *//' || echo "none")
    created=$(grep -m1 "^created:" "$f" 2>/dev/null | sed 's/created: *//' || echo "unknown")
    mentions=$(grep -c "^  - " "$f" 2>/dev/null || echo "0")
    ACTION_DETAILS="$ACTION_DETAILS\n- $name | status: $status | due: $due | created: $created | mention_lines: $mentions"
done

# Get recent git activity patterns (timestamps for engagement analysis)
GIT_TIMESTAMPS=$(git log --since="30 days ago" --format="%ai %s" 2>/dev/null | head -50)

# Load reflections
REFLECTIONS=""
if [ -d "Canon/Reflections" ]; then
    REFLECTIONS=$(find Canon/Reflections/ -name "*.md" -type f 2>/dev/null | sort -r | head -10 | while read f; do echo "=== $(basename "$f") ==="; head -30 "$f"; echo; done)
fi

# Load beliefs
BELIEFS=""
if [ -d "Canon/Beliefs" ]; then
    BELIEFS=$(find Canon/Beliefs/ -name "*.md" -type f 2>/dev/null | while read f; do echo "=== $(basename "$f") ==="; cat "$f"; echo; done)
fi

# Load recent decisions
DECISIONS=$(find Canon/Decisions/ -name "*.md" -type f 2>/dev/null | sort -r | head -5 | while read f; do echo "=== $(basename "$f") ==="; head -30 "$f"; echo; done)

# Load previous Mirror for delta
PREV_MIRROR=""
PREV_MIRROR_FILE=$(find Meta/AI-Reflections/ -name "*Mirror*" -type f 2>/dev/null | sort -r | head -1)
if [ -n "$PREV_MIRROR_FILE" ]; then
    PREV_MIRROR=$(cat "$PREV_MIRROR_FILE")
fi

# Load style guide for voice consistency check
STYLE_GUIDE=$(cat "Meta/style-guide.md" 2>/dev/null || echo "")

# Load decisions summary (token-cheap) for alignment checking
DECISIONS_SUMMARY=$(cat "Meta/decisions-summary.md" 2>/dev/null || echo "")

# Topic focus
TOPIC_PROMPT=""
if [ -n "$TOPIC" ]; then
    TOPIC_PROMPT="FOCUS TOPIC: The human specifically asked for a Mirror focused on: $TOPIC. Weight your analysis toward this topic while still covering other sections."
fi

MIRROR_PROMPT="You are the MIRROR agent for this Obsidian vault.

Read CLAUDE.md for vault rules. Then read your spec carefully.

## YOUR SPEC (from Meta/Agents/Mirror.md)
$AGENT_SPEC

$TOPIC_PROMPT

## ACTION DATA
Total: $TOTAL_ACTIONS | Open: $OPEN_ACTIONS | Done: $DONE_ACTIONS | Dropped: $DROPPED_ACTIONS

Action details:
$(echo -e "$ACTION_DETAILS")

## GIT ACTIVITY (last 30 days — for engagement/energy analysis)
$GIT_TIMESTAMPS

## REFLECTIONS (Canon/Reflections/)
$REFLECTIONS

## BELIEFS (Canon/Beliefs/)
$BELIEFS

## RECENT DECISIONS
$DECISIONS

## PREVIOUS MIRROR (for delta section)
$PREV_MIRROR

## STYLE GUIDE (for voice consistency)
$STYLE_GUIDE

## DECISIONS SUMMARY (for decision-action alignment)
$DECISIONS_SUMMARY

## YOUR JOB
1. Read ALL Canon/Actions/ files for completion patterns
2. Read Canon/Reflections/ for mood and energy patterns
3. Read Canon/Beliefs/ for alignment checking
4. Read Canon/People/ for relationship pulse (sample 10 most-linked people)
5. Analyze git timestamps for engagement patterns
6. Write the full 7-section Mirror to Meta/AI-Reflections/$DATE - Mirror.md
7. Be direct. Use Usman's own words. Don't soften.
8. End with ONE question.
9. Git commit: 'vault: mirror [$DATE]'"

INVOKE_EXIT=0
INVOKE_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" MIRROR "$MIRROR_PROMPT" 2>&1) || INVOKE_EXIT=$?

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

# Output validation: check mirror file was actually created
MIRROR_FILE="Meta/AI-Reflections/$DATE - Mirror.md"
if [ ! -f "$MIRROR_FILE" ]; then
    notify_failure "No mirror file produced at $MIRROR_FILE"
    exit 1
fi

# Validate: file should have some content (not empty/garbage)
MIRROR_LINES=$(wc -l < "$MIRROR_FILE" | tr -d ' ')
if [ "$MIRROR_LINES" -lt 10 ]; then
    notify_failure "Mirror file too short (${MIRROR_LINES} lines), likely malformed"
    exit 1
fi

# Fallback commit: ONLY the mirror file and changelog (no git add -A)
agent_stage_and_commit "[Mirror] reflect: weekly mirror [$TIMESTAMP]" \
    "$MIRROR_FILE" \
    Meta/AI-Reflections/ \
    Meta/changelog.md

"$SCRIPT_DIR/log-change.sh" "Mirror" "Weekly mirror reflection generated"
agent_commit_changelog_if_needed "[Mirror] log: changelog update [$TIMESTAMP]"

# Heartbeat
mkdir -p "$HOME/.vault/heartbeats"
date +%s > "$HOME/.vault/heartbeats/mirror"

# Telegram notification with closing question
CLOSING_QUESTION=$(grep -m1 '?' "$MIRROR_FILE" | tail -1 || echo "")
"$SCRIPT_DIR/send-telegram.sh" "🪞 Weekly Mirror
${CLOSING_QUESTION:-Reflection ready.}
Full reflection: $MIRROR_FILE" 2>/dev/null || true

# Log to agent feedback queue
"$SCRIPT_DIR/log-agent-feedback.sh" \
    "Mirror" \
    "mirror_complete" \
    "Mirror reflection complete" \
    "" \
    "" \
    "true" 2>/dev/null || true

echo "[$TIMESTAMP] Mirror complete."
