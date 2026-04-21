#!/bin/bash
# run-retro.sh
# Daily agent retrospective — agents review their work and propose improvements
# Usage: ./run-retro.sh

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
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HEAD_BEFORE_RUN=$(git rev-parse HEAD)

# Failure notification via Telegram
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Retro FAILED* at $(date '+%H:%M')
Reason: $1" 2>/dev/null || true
}

echo "[$TIMESTAMP] Running daily agent retrospective..."

agent_require_commands git python3
agent_assert_clean_worktree "Retro"
agent_acquire_lock "vault-agent-pipeline"

# Skip if no vault changes since last retro
LAST_RETRO_DATE=""
if [ -f "Meta/AI-Reflections/retro-log.md" ]; then
    LAST_RETRO_DATE=$(grep -oP '## Retro: \K\d{4}-\d{2}-\d{2}' "Meta/AI-Reflections/retro-log.md" | tail -1)
fi

if [ -n "$LAST_RETRO_DATE" ]; then
    COMMITS_SINCE=$(git log --since="$LAST_RETRO_DATE 21:00" --oneline -- . ':!Meta/AI-Reflections/retro-log.md' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$COMMITS_SINCE" -eq 0 ]; then
        echo "[$TIMESTAMP] No vault changes since last retro ($LAST_RETRO_DATE). Skipping."
        exit 0
    fi
    echo "  $COMMITS_SINCE commit(s) since last retro ($LAST_RETRO_DATE)"
fi

# Gather vault stats (using find for reliability across macOS/Linux)
PEOPLE_COUNT=$(find "$VAULT_DIR/Canon/People" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
EVENTS_COUNT=$(find "$VAULT_DIR/Canon/Events" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
CONCEPTS_COUNT=$(find "$VAULT_DIR/Canon/Concepts" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
ACTIONS_COUNT=$(find "$VAULT_DIR/Canon/Actions" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
DECISIONS_COUNT=$(find "$VAULT_DIR/Canon/Decisions" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
PLACES_COUNT=$(find "$VAULT_DIR/Canon/Places" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
PROJECTS_COUNT=$(find "$VAULT_DIR/Canon/Projects" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
ORGS_COUNT=$(find "$VAULT_DIR/Canon/Organizations" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
# Use grep -rl (lowercase, no -I) for macOS BSD grep compatibility
REFLECTIONS_COUNT=$(grep -rl '^type: reflection' "$VAULT_DIR/Thinking/" 2>/dev/null | wc -l | tr -d ' ')
BELIEFS_COUNT=$(grep -rl '^type: belief' "$VAULT_DIR/Thinking/" 2>/dev/null | wc -l | tr -d ' ')
THINKING_COUNT=$(find "$VAULT_DIR/Thinking" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
OPEN_ACTIONS=$(VAULT_DIR="$VAULT_DIR" python3 <<'PYEOF'
import os
import pathlib
import re

vault = pathlib.Path(os.environ["VAULT_DIR"]) / "Canon" / "Actions"
count = 0

for path in vault.glob("*.md"):
    text = path.read_text(encoding="utf-8")
    note_type = re.search(r'^type:\s*(.+)$', text, re.MULTILINE)
    status = re.search(r'^status:\s*(.+)$', text, re.MULTILINE)
    if note_type and note_type.group(1).strip() == "action" and status and status.group(1).strip() == "open":
        count += 1

print(count)
PYEOF
)
TOTAL_CANON=$(find "$VAULT_DIR"/Canon/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
TOTAL_INBOX=$(find "$VAULT_DIR"/Inbox/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
EXTRACTED=$(grep -rl "status: extracted" "$VAULT_DIR"/Inbox/ 2>/dev/null | wc -l | tr -d ' ')
UNPROCESSED=$(grep -rl "status: inbox" "$VAULT_DIR"/Inbox/ 2>/dev/null | wc -l | tr -d ' ')

# Verify stats are not zero (sanity check)
echo "  Vault stats: People=$PEOPLE_COUNT Events=$EVENTS_COUNT Actions=$ACTIONS_COUNT Reflections=$REFLECTIONS_COUNT Beliefs=$BELIEFS_COUNT"
if [ "$PEOPLE_COUNT" -eq 0 ] && [ "$EVENTS_COUNT" -eq 0 ]; then
    echo "  WARNING: Stats look wrong (People=0, Events=0). Check VAULT_DIR=$VAULT_DIR"
fi

# Check if today's briefing was answered (look for voice memos referencing it)
BRIEFING_ENGAGED="unknown"
if [ -f "Inbox/${DATE} - Daily Briefing.md" ]; then
    BRIEFING_ENGAGED="generated"
fi

# ── Agent health checks ──────────────────────────────────────────────
AGENT_HEALTH=""
NOW_TS=$(date +%s)
for hb in "$HOME/.vault/heartbeats"/*; do
    [ -f "$hb" ] || continue
    agent_name=$(basename "$hb")
    last_ts=$(cat "$hb" 2>/dev/null || echo 0)
    age_hours=$(( (NOW_TS - last_ts) / 3600 ))
    AGENT_HEALTH="$AGENT_HEALTH
- $agent_name: last ran ${age_hours}h ago"
done
[ -z "$AGENT_HEALTH" ] && AGENT_HEALTH="- No heartbeats found"

# Count overdue actions (due date in the past, status open)
OVERDUE_ACTIONS=$(VAULT_DIR="$VAULT_DIR" DATE_TODAY="$DATE" python3 <<'PYEOF'
import os, pathlib, re
vault = pathlib.Path(os.environ["VAULT_DIR"]) / "Canon" / "Actions"
today = os.environ["DATE_TODAY"]
count = 0
for path in vault.glob("*.md"):
    text = path.read_text(encoding="utf-8")
    status = re.search(r'^status:\s*(.+)$', text, re.MULTILINE)
    due = re.search(r'^due:\s*(.+)$', text, re.MULTILINE)
    if status and status.group(1).strip() == "open" and due:
        d = due.group(1).strip().strip('"')
        if d and d < today and d != "none" and d != "":
            count += 1
print(count)
PYEOF
)

# Review queue backlog (items in sent/pending status older than 3 days)
STALE_REVIEWS=$(find "$VAULT_DIR/Meta/review-queue" -name "*.md" -mtime +3 2>/dev/null | while read f; do
    grep -l "status: sent\|status: pending" "$f" 2>/dev/null
done | wc -l | tr -d ' ')

# Advisor session count this week
ADVISOR_SESSIONS_WEEK=$(find "$VAULT_DIR/Meta/advisor-sessions" -name "*.md" -mtime -7 2>/dev/null | wc -l | tr -d ' ')

# Knowledge file update count
KNOWLEDGE_UPDATES=$(grep -oP 'update_count:\s*\K\d+' "$VAULT_DIR/Meta/Agents/advisor-knowledge.md" 2>/dev/null || echo 0)

# Voice memos this week
VOICE_MEMOS_WEEK=$(find "$VAULT_DIR/Inbox/Voice" -name "*.md" -mtime -7 2>/dev/null | wc -l | tr -d ' ')

# Agent feedback queue entries this week
FEEDBACK_ENTRIES_WEEK=0
if [ -f "$VAULT_DIR/Meta/agent-feedback.jsonl" ]; then
    WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d 2>/dev/null || echo "2026-01-01")
    FEEDBACK_ENTRIES_WEEK=$(grep -c "\"$WEEK_AGO\|$(date +%Y-%m)" "$VAULT_DIR/Meta/agent-feedback.jsonl" 2>/dev/null || echo 0)
fi

# Load retro log history (last 3 retros for context)
RETRO_HISTORY=""
if [ -f "Meta/AI-Reflections/retro-log.md" ]; then
    RETRO_HISTORY=$(tail -100 "Meta/AI-Reflections/retro-log.md")
fi

# Get today's git activity
GIT_TODAY=$(git log --since="$DATE" --oneline 2>/dev/null || echo "no commits today")

# Load decisions log for tripwire checking + summary regeneration
DECISIONS_LOG=""
if [ -f "Meta/decisions-log.md" ]; then
    DECISIONS_LOG=$(cat "Meta/decisions-log.md")
fi

# Get recent retro dates (just last 3 dates, not content)
RECENT_RETRO_DATES=""
if [ -f "Meta/AI-Reflections/retro-log.md" ]; then
    RECENT_RETRO_DATES=$(grep -oP '## Retro: \K\d{4}-\d{2}-\d{2}' "Meta/AI-Reflections/retro-log.md" | tail -3 | paste -sd', ')
fi

PROMPT="You are running the DAILY AGENT RETROSPECTIVE for this Obsidian vault.

## STEP 1 — Read these files (do NOT skip)
- CLAUDE.md (vault rules)
- Meta/Agents/Retrospective.md (YOUR spec — follow it exactly)
- Meta/Agents/Extractor.md, Reviewer.md, Thinker.md, Briefing.md (agent specs you can modify)
- Last 30 lines of Meta/AI-Reflections/review-log.md (recent review scores)
- Last 50 lines of Meta/AI-Reflections/retro-log.md (previous retros — don't repeat them)
- Meta/decisions-log.md (below) — check 'Check later' tripwires against current vault state

## VAULT STATS TODAY
- People: $PEOPLE_COUNT | Events: $EVENTS_COUNT | Concepts: $CONCEPTS_COUNT | Actions: $ACTIONS_COUNT
- Decisions: $DECISIONS_COUNT | Places: $PLACES_COUNT | Projects: $PROJECTS_COUNT | Organizations: $ORGS_COUNT
- Thinking total: $THINKING_COUNT | Reflections: $REFLECTIONS_COUNT | Beliefs: $BELIEFS_COUNT
- Total Canon: $TOTAL_CANON | Total Inbox: $TOTAL_INBOX
- Open actions: $OPEN_ACTIONS
- Extracted: $EXTRACTED | Unprocessed: $UNPROCESSED
- Briefing: $BRIEFING_ENGAGED
- Recent retros: $RECENT_RETRO_DATES
- Overdue actions: $OVERDUE_ACTIONS
- Stale review items (>3 days): $STALE_REVIEWS
- Advisor sessions this week: $ADVISOR_SESSIONS_WEEK
- Advisor knowledge updates: $KNOWLEDGE_UPDATES
- Voice memos this week: $VOICE_MEMOS_WEEK
- Agent feedback entries this week: $FEEDBACK_ENTRIES_WEEK

## AGENT HEALTH (heartbeat ages)
$AGENT_HEALTH

## GIT ACTIVITY TODAY
$GIT_TODAY

## DECISIONS LOG (check tripwires, regenerate summary)
$DECISIONS_LOG

## STEP 2 — Do the retro
1. Sample 3-5 recent inbox notes and their corresponding Canon entries to assess quality
2. Run through ALL retro questions from the spec
3. Propose concrete changes — IMPLEMENT safe ones (edit agent specs, add rules, fix patterns)
4. Append the full retro to Meta/AI-Reflections/retro-log.md (APPEND, never overwrite)
5. **Decisions check:** Scan each 'Check later' tripwire in the decisions log. If any condition is now true, flag it in the retro and add a 'revised' entry to the log.
6. **Regenerate summary:** Overwrite Meta/decisions-summary.md with a fresh condensed version (active decisions as numbered list, active tripwires, any revised decisions, patterns you see). Keep it under 40 lines.
7. Do NOT run git add or git commit. Leave changes in the worktree.

## HARD BOUNDARIES (read-only for you)
- Do NOT edit: CLAUDE.md, META/Architecture.md, Meta/scripts/*.sh, Meta/agent-runtimes.conf, HOME.md
- Do NOT delete any file
- You MAY edit: Meta/Agents/*.md, Meta/AI-Reflections/*, Meta/review-queue/*, Meta/decisions-log.md, Meta/decisions-summary.md

Be specific. Reference actual notes. Don't be vague."

INVOKE_EXIT=0
INVOKE_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" retrospective "$PROMPT" 2>&1) || INVOKE_EXIT=$?

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
SPECS_CHANGED=$(git diff --name-only "$HEAD_BEFORE_RUN" -- Meta/Agents/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$SPECS_CHANGED" -gt 0 ] 2>/dev/null; then
    "$SCRIPT_DIR/log-change.sh" "Retro" "Daily retrospective: ${SPECS_CHANGED} agent spec(s) modified"
else
    "$SCRIPT_DIR/log-change.sh" "Retro" "Daily retrospective: observations logged, no spec changes"
fi

# Commit retro-owned paths, including the changelog entry.
agent_stage_and_commit "[Retro] reflect: daily retrospective [$TIMESTAMP]" \
    Meta/Agents/ \
    Meta/AI-Reflections/ \
    Meta/review-queue/ \
    Meta/decisions-log.md \
    Meta/decisions-summary.md \
    Meta/changelog.md

# Trigger Implementer to auto-fix findings
# Pass ALLOW_DIRTY and LOCK_HELD so Implementer doesn't block on worktree/lock
echo "[$TIMESTAMP] Triggering Implementer..."
VAULT_AGENT_ALLOW_DIRTY=1 VAULT_AGENT_LOCK_HELD=1 /bin/bash "$SCRIPT_DIR/run-implementer.sh" retro

# Log to agent feedback queue — include health metrics for Advisor digest
"$SCRIPT_DIR/log-agent-feedback.sh" \
    "Retro" \
    "retro_complete" \
    "Retro complete. Open: $OPEN_ACTIONS actions ($OVERDUE_ACTIONS overdue). Inbox: $UNPROCESSED unprocessed. Stale reviews: $STALE_REVIEWS. Voice memos (7d): $VOICE_MEMOS_WEEK. Advisor sessions (7d): $ADVISOR_SESSIONS_WEEK." \
    "Meta/AI-Reflections/retro-log.md" \
    "" \
    "true" 2>/dev/null || true

echo "[$TIMESTAMP] Retrospective + Implementer complete."
