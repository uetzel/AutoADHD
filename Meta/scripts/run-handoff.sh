#!/bin/bash
# run-handoff.sh — Execute a Claude→Codex handoff
# Usage: ./run-handoff.sh Meta/handoffs/20260327-2300-extractor.md
#
# Reads the handoff file, feeds it to Codex (no auto-commit),
# validates the result BEFORE committing, and notifies via Telegram.

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

HANDOFF_FILE="${1:?Usage: run-handoff.sh <handoff-file.md>}"

if [ ! -f "$HANDOFF_FILE" ]; then
    echo "Handoff file not found: $HANDOFF_FILE" >&2
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
HEAD_BEFORE_RUN=$(git rev-parse HEAD)

# FIX P1: Set agent context so pre-commit guard blocks control-file edits
export VAULT_AGENT_CONTEXT="handoff"

# FIX P1 (round 2): Require clean worktree before starting.
# Without this, a failed handoff's revert (checkout/clean) could wipe
# unrelated local edits that were already in the worktree.
agent_assert_clean_worktree "Handoff"

# --- Read handoff metadata ---
TASK_NAME=$(grep -m1 '^## Task' "$HANDOFF_FILE" | sed 's/^## Task: *//' || echo "unknown")
PRIORITY=$(grep -m1 'priority:' "$HANDOFF_FILE" | sed 's/.*priority: *//' | tr -d ' ' || echo "medium")

echo "[$TIMESTAMP] Executing handoff: $HANDOFF_FILE"
echo "  Task: $TASK_NAME"
echo "  Priority: $PRIORITY"

# --- Mark as picked up ---
sed -i '' "s/status: pending/status: picked-up/" "$HANDOFF_FILE" 2>/dev/null || \
    sed -i "s/status: pending/status: picked-up/" "$HANDOFF_FILE" 2>/dev/null || true

# --- Build Codex prompt from handoff file ---
HANDOFF_CONTENT=$(cat "$HANDOFF_FILE")

# FIX P2: Tell Codex NOT to commit. We validate and commit ourselves.
PROMPT="You are picking up a task that was handed off to you by Claude.

## Instructions
Read the handoff file below carefully. It tells you:
1. What's already done
2. What you need to do (numbered steps)
3. What NOT to touch (forbidden paths)
4. How to verify you're done (done criteria)

Read the context files listed before doing any work.

## HARD BOUNDARY
Do NOT edit any file listed under 'What NOT to touch' in the handoff.
Do NOT delete files unless the handoff explicitly says to.
Do NOT add features, refactors, or improvements not mentioned in the handoff.
Stick to the plan. Nothing more, nothing less.

## CRITICAL: Do NOT commit
Do NOT run git add or git commit. Leave all changes unstaged.
The handoff runner will validate your changes and commit them after review.
If you commit, the handoff will be marked as failed.

## Handoff Content
$HANDOFF_CONTENT"

# --- Execute via Codex ---
echo "Running Codex..."
if ! /bin/bash "$SCRIPT_DIR/invoke-agent.sh" handoff "$PROMPT"; then
    # Mark failed
    sed -i '' "s/status: picked-up/status: failed/" "$HANDOFF_FILE" 2>/dev/null || \
        sed -i "s/status: picked-up/status: failed/" "$HANDOFF_FILE" 2>/dev/null || true

    "$SCRIPT_DIR/send-telegram.sh" "❌ *Handoff FAILED*
Task: $TASK_NAME
File: $HANDOFF_FILE
Codex exited with error." 2>/dev/null || true

    echo "Handoff failed." >&2
    exit 1
fi

# --- FIX P2: Check if Codex committed anyway (violating the no-commit rule) ---
if [ "$(git rev-parse HEAD)" != "$HEAD_BEFORE_RUN" ]; then
    echo "WARNING: Codex committed despite being told not to. Checking those commits too." >&2
    # We still validate — the commits are already there, so check them
    CODEX_COMMITTED=true
else
    CODEX_COMMITTED=false
fi

# --- Pre-commit validation (BEFORE we commit) ---
echo "Validating..."
VALIDATION_ERRORS=()

# Extract forbidden paths from handoff file
FORBIDDEN_PATHS=$(awk '/^### What NOT to touch/,/^###/{print}' "$HANDOFF_FILE" | grep '^\- ' | sed 's/^- //' | tr -d '`' || true)

# Check worktree changes (unstaged/staged but not committed)
WORKTREE_CHANGES=$(git status --porcelain --untracked-files=normal | grep -v '^\?' | awk '{print $2}' || true)
# Also check any commits Codex made despite being told not to
if [ "$CODEX_COMMITTED" = "true" ]; then
    COMMITTED_CHANGES=$(git diff --name-only "$HEAD_BEFORE_RUN"..HEAD 2>/dev/null || true)
    ALL_CHANGES=$(printf '%s\n%s' "$WORKTREE_CHANGES" "$COMMITTED_CHANGES" | sort -u)
else
    ALL_CHANGES="$WORKTREE_CHANGES"
fi

# Check forbidden paths
if [ -n "$FORBIDDEN_PATHS" ] && [ -n "$ALL_CHANGES" ]; then
    while IFS= read -r forbidden; do
        [ -n "$forbidden" ] || continue
        while IFS= read -r changed; do
            [ -n "$changed" ] || continue
            case "$changed" in
                "$forbidden"|"$forbidden"/*)
                    VALIDATION_ERRORS+=("Forbidden path modified: $changed")
                    ;;
            esac
        done <<< "$ALL_CHANGES"
    done <<< "$FORBIDDEN_PATHS"
fi

# Check for unexpected deletions in protected dirs
DELETED_WORKTREE=$(git diff --name-only --diff-filter=D 2>/dev/null || true)
DELETED_COMMITTED=""
if [ "$CODEX_COMMITTED" = "true" ]; then
    DELETED_COMMITTED=$(git diff --name-only --diff-filter=D "$HEAD_BEFORE_RUN"..HEAD 2>/dev/null || true)
fi
ALL_DELETED=$(printf '%s\n%s' "$DELETED_WORKTREE" "$DELETED_COMMITTED" | sort -u)

if [ -n "$ALL_DELETED" ]; then
    while IFS= read -r del; do
        [ -n "$del" ] || continue
        case "$del" in
            Thinking/Research/*|Canon/*|Meta/AI-Reflections/*)
                VALIDATION_ERRORS+=("Unexpected deletion: $del")
                ;;
        esac
    done <<< "$ALL_DELETED"
fi

# --- FIX P2 (done criteria): Extract and run done-criteria checks ---
DONE_CRITERIA=$(awk '/^### Done criteria/,/^###/{print}' "$HANDOFF_FILE" | grep '^\- ' | sed 's/^- //' || true)

if [ -n "$DONE_CRITERIA" ]; then
    echo "Running done-criteria checks..."
    while IFS= read -r criterion; do
        [ -n "$criterion" ] || continue
        # Each criterion can be:
        # - A file existence check: "File exists: path/to/file.md"
        # - A content check: "Contains: path/to/file.md has 'some text'"
        # - A grep check: "Grep: pattern in path/to/file.md"
        # - Plain text (informational, skip)
        case "$criterion" in
            "File exists: "*)
                CHECK_PATH="${criterion#File exists: }"
                if [ ! -f "$CHECK_PATH" ]; then
                    VALIDATION_ERRORS+=("Done criterion failed: $criterion")
                fi
                ;;
            "Grep: "*)
                # Format: "Grep: pattern in path"
                GREP_PATTERN=$(echo "$criterion" | sed 's/^Grep: //' | sed 's/ in .*//')
                GREP_PATH=$(echo "$criterion" | sed 's/.* in //')
                if ! grep -q "$GREP_PATTERN" "$GREP_PATH" 2>/dev/null; then
                    VALIDATION_ERRORS+=("Done criterion failed: $criterion")
                fi
                ;;
            "No changes in: "*)
                CHECK_DIR="${criterion#No changes in: }"
                # Check worktree changes
                if git status --porcelain -- "$CHECK_DIR" 2>/dev/null | grep -q .; then
                    VALIDATION_ERRORS+=("Done criterion failed (worktree): $criterion")
                fi
                # Also check committed changes (if Codex committed despite instructions)
                if [ "$CODEX_COMMITTED" = "true" ]; then
                    if git diff --name-only "$HEAD_BEFORE_RUN"..HEAD -- "$CHECK_DIR" 2>/dev/null | grep -q .; then
                        VALIDATION_ERRORS+=("Done criterion failed (committed): $criterion")
                    fi
                fi
                ;;
            *)
                # Informational criterion — log but don't check
                echo "  (manual check needed): $criterion"
                ;;
        esac
    done <<< "$DONE_CRITERIA"
fi

# --- Report ---
if [ "${#VALIDATION_ERRORS[@]}" -gt 0 ]; then
    # If Codex committed bad changes, revert them
    if [ "$CODEX_COMMITTED" = "true" ]; then
        echo "Reverting Codex commits due to validation failure..." >&2
        git reset --soft "$HEAD_BEFORE_RUN"
    fi

    # Reset any staged/unstaged changes
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true

    sed -i '' "s/status: picked-up/status: failed/" "$HANDOFF_FILE" 2>/dev/null || \
        sed -i "s/status: picked-up/status: failed/" "$HANDOFF_FILE" 2>/dev/null || true

    ERROR_MSG=$(printf '• %s\n' "${VALIDATION_ERRORS[@]}")
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Handoff VALIDATION FAILED*
Task: $TASK_NAME
Issues:
$ERROR_MSG
Changes were reverted. Review: $HANDOFF_FILE" 2>/dev/null || true

    echo "Validation failed — changes reverted:" >&2
    printf '  %s\n' "${VALIDATION_ERRORS[@]}" >&2
    exit 1
fi

# --- All checks passed — now commit ---
echo "Validation passed. Committing..."

# Update handoff status BEFORE committing so it's included in the commit
sed -i '' "s/status: picked-up/status: completed/" "$HANDOFF_FILE" 2>/dev/null || \
    sed -i "s/status: picked-up/status: completed/" "$HANDOFF_FILE" 2>/dev/null || true

# Stage and commit content + handoff status (audit trail)
agent_stage_and_commit "[Handoff] $TASK_NAME [$TIMESTAMP]" \
    Inbox/ Canon/ Thinking/ Meta/review-queue/ Meta/changelog.md Meta/handoffs/

"$SCRIPT_DIR/send-telegram.sh" "✅ *Handoff COMPLETED*
Task: $TASK_NAME
Codex finished successfully. Validated and committed." 2>/dev/null || true

"$SCRIPT_DIR/log-agent-feedback.sh" "Handoff" "handoff_completed" "Handoff completed: $TASK_NAME" "" "" "false" 2>/dev/null || true

echo "[$TIMESTAMP] Handoff complete: $TASK_NAME"
