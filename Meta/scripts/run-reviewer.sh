#!/bin/bash
# run-reviewer.sh
# QA agent — checks extraction quality and vault integrity
# Usage: ./run-reviewer.sh

set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
unset PWD OLDPWD 2>/dev/null || true
cd "$VAULT_DIR"


SCRIPT_DIR="$VAULT_DIR/Meta/scripts"
source "$SCRIPT_DIR/lib-agent.sh"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HEAD_BEFORE_RUN=$(agent_git rev-parse HEAD)

# Failure notification via Telegram
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Reviewer FAILED* at $(date '+%H:%M')
Reason: $1" 2>/dev/null || true
}

echo "[$TIMESTAMP] Running Reviewer agent..."

agent_require_commands git python3
agent_assert_clean_worktree "Reviewer"
agent_acquire_lock "vault-agent-pipeline"

# Gather vault stats
INBOX_COUNT=$(find Inbox/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
EXTRACTED_COUNT=$(grep -rl "status: extracted" Inbox/ 2>/dev/null | wc -l | tr -d ' ')
UNPROCESSED_COUNT=$(grep -rl "status: inbox" Inbox/ 2>/dev/null | wc -l | tr -d ' ')
PEOPLE_COUNT=$(find Canon/People/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
EVENTS_COUNT=$(find Canon/Events/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
CONCEPTS_COUNT=$(find Canon/Concepts/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
ACTIONS_COUNT=$(find Canon/Actions/ -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')

# Get notes to review — in voice pipeline mode, only review the new note (fast path)
if [ "${VAULT_AGENT_CONTEXT:-}" = "voice-pipeline" ] && [ -n "${1:-}" ]; then
    # Voice pipeline passes the specific note to review
    RECENT="$1"
    echo "  Voice pipeline mode: reviewing only $(basename "$1")"
else
    # Standalone mode: review last 10 extracted notes
    RECENT=$(grep -rl "status: extracted" Inbox/ 2>/dev/null | sort -r | head -10)
fi

# Build lean prompt — agent reads files at runtime
PROMPT="You are the REVIEWER agent for this Obsidian vault.

## STEP 1: Read these files (in this order)
1. Read .claude/skills/vault-writer/SKILL.md — note format, frontmatter, emoji headings, provenance rules
2. Read Meta/Agents/Reviewer.md — your full spec and QA checklist

## STEP 2: Quick vault stats (for context)
- Inbox notes: $INBOX_COUNT (extracted: $EXTRACTED_COUNT, unprocessed: $UNPROCESSED_COUNT)
- Canon/People: $PEOPLE_COUNT, Events: $EVENTS_COUNT, Concepts: $CONCEPTS_COUNT, Actions: $ACTIONS_COUNT

## STEP 3: Review these recently extracted notes
$RECENT

For EACH note:
1. Read the inbox note (cat the file)
2. Read every Canon entry it should have created/updated (follow wikilinks)
3. Check: did Extractor miss anyone mentioned by name?
4. Check: are all wikilinks pointing to real notes? (use find to verify)
5. Check: are locked fields intact? (compare frontmatter locked array vs values)
6. Check: does the inbox note itself have `source_agent` / `source_date`, and do AI-created notes include them too?
7. Check: are provenance markers (source field + inline comments with agent + timestamp) present?
8. Check: does the note have an ## Extracted section? (MANDATORY per spec)
9. Check: do any materially updated notes have stale or contradictory `updated:` / `status:` frontmatter?
10. Check: do all notes have emoji in H1 heading?

## STEP 4: Output
Append findings to Meta/AI-Reflections/review-log.md:
## Review: $TIMESTAMP
### Issues Found
[list each issue with file path]
### Fixes Applied
[list what you fixed directly]

Fix simple issues yourself (broken links, recoverable missing source fields, missing emoji headings, explicit stale `updated:`/`status:` mismatches when the correct value is recoverable from the note evidence).
Do NOT run git add or git commit. Leave changes in the worktree for the runner to validate, log, and commit."

PROMPT="$PROMPT

## HARD BOUNDARY
You may modify ONLY:
- Inbox/
- Canon/
- Thinking/ (but do NOT create Thinking/Research/)
- Meta/AI-Reflections/
- Meta/review-queue/
- Meta/changelog.md

You must NOT create or edit:
- Meta/Agents/
- Meta/scripts/
- Meta/research/
- Thinking/Research/
- CLAUDE.md
- HOME.md
- AGENTS.md
- Meta/Architecture.md
- Meta/agent-runtimes.conf

If you think the specs or automation should change, write that as a finding in Meta/AI-Reflections or Meta/review-queue instead of editing control files."

INVOKE_EXIT=0
INVOKE_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" reviewer "$PROMPT" 2>&1) || INVOKE_EXIT=$?

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

if ! agent_assert_no_forbidden_commits "Reviewer" "$HEAD_BEFORE_RUN" \
    Meta/Agents \
    Meta/scripts \
    Meta/research \
    Thinking/Research \
    CLAUDE.md \
    HOME.md \
    AGENTS.md \
    Meta/Architecture.md \
    Meta/agent-runtimes.conf; then
    notify_failure "forbidden control-file edits detected"
    exit 1
fi

# Log to changelog
FIXES=$(agent_git diff --name-only "$HEAD_BEFORE_RUN" -- Canon/ 2>/dev/null | wc -l | tr -d ' ')
"$SCRIPT_DIR/log-change.sh" "Reviewer" "QA pass: ${FIXES} files touched, reviewed $EXTRACTED_COUNT extracted notes"

if [ "${VAULT_AGENT_CONTEXT:-}" = "voice-pipeline" ]; then
    echo "[$TIMESTAMP] Reviewer complete (voice pipeline mode; commit handled by caller)."
    exit 0
fi

# Commit reviewer-owned paths, including the changelog entry.
agent_stage_and_commit "[Reviewer] review: QA pass [$TIMESTAMP]" \
    Inbox/ \
    Canon/ \
    Thinking/ \
    Meta/AI-Reflections/ \
    Meta/review-queue/ \
    Meta/changelog.md

# Trigger Implementer to auto-fix findings
# Pass ALLOW_DIRTY and LOCK_HELD so Implementer doesn't block on worktree/lock
echo "[$TIMESTAMP] Triggering Implementer..."
VAULT_AGENT_ALLOW_DIRTY=1 VAULT_AGENT_LOCK_HELD=1 /bin/bash "$SCRIPT_DIR/run-implementer.sh" reviewer

"$SCRIPT_DIR/log-agent-feedback.sh" "Reviewer" "review_complete" "QA pass: reviewed $EXTRACTED_COUNT notes, $FIXES files touched" "Meta/AI-Reflections/review-log.md" "" "false" 2>/dev/null || true

echo "[$TIMESTAMP] Reviewer + Implementer complete."
