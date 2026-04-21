#!/bin/bash
# pre-commit-guard.sh — git pre-commit hook for the vault
# Blocks dangerous operations: deletions in protected dirs, forbidden path edits by agents
#
# Install: ln -sf ../../Meta/scripts/pre-commit-guard.sh .git/hooks/pre-commit

set -euo pipefail

# Protected directories — deletions here require VAULT_ALLOW_DELETE=1
PROTECTED_DIRS=(
    "Thinking/Research"
    "Canon/People"
    "Canon/Actions"
    "Canon/Events"
    "Canon/Decisions"
    "Canon/Beliefs"
    "Canon/Reflections"
    "Canon/Projects"
    "Meta/AI-Reflections"
)

# Control files — only editable when VAULT_ALLOW_CONTROL_EDIT=1
CONTROL_PATHS=(
    "CLAUDE.md"
    "HOME.md"
    "Meta/Architecture.md"
    "Meta/agent-runtimes.conf"
    "Meta/Agents/"
    "Meta/scripts/"
)

ERRORS=()

# --- Check 1: Blocked deletions in protected dirs ---
DELETED_FILES=$(git diff --cached --diff-filter=D --name-only 2>/dev/null || true)
if [ -n "$DELETED_FILES" ]; then
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        for dir in "${PROTECTED_DIRS[@]}"; do
            case "$file" in
                "$dir"/*)
                    if [ "${VAULT_ALLOW_DELETE:-0}" != "1" ]; then
                        ERRORS+=("BLOCKED DELETE: $file (set VAULT_ALLOW_DELETE=1 to override)")
                    fi
                    ;;
            esac
        done
    done <<< "$DELETED_FILES"
fi

# --- Check 2: Control file edits by agents (not humans) ---
# Only enforced when running inside an agent context
if [ "${VAULT_AGENT_CONTEXT:-}" != "" ]; then
    CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
    if [ -n "$CHANGED_FILES" ]; then
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            for ctrl in "${CONTROL_PATHS[@]}"; do
                case "$file" in
                    "$ctrl"|"$ctrl"*)
                        if [ "${VAULT_ALLOW_CONTROL_EDIT:-0}" != "1" ]; then
                            ERRORS+=("AGENT BLOCKED: $file (control file, agent=$VAULT_AGENT_CONTEXT)")
                        fi
                        ;;
                esac
            done
        done <<< "$CHANGED_FILES"
    fi
fi

# --- Check 3: Warn on large commits (> 50 files) ---
FILE_COUNT=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
if [ "$FILE_COUNT" -gt 50 ] && [ "${VAULT_ALLOW_BULK:-0}" != "1" ]; then
    echo "⚠️  Large commit: $FILE_COUNT files staged. Set VAULT_ALLOW_BULK=1 to proceed." >&2
    # Warning only, don't block
fi

# --- Report ---
if [ "${#ERRORS[@]}" -gt 0 ]; then
    echo "" >&2
    echo "🛑 PRE-COMMIT GUARD — blocked this commit:" >&2
    echo "" >&2
    for err in "${ERRORS[@]}"; do
        echo "  $err" >&2
    done
    echo "" >&2
    echo "If this is intentional, set the appropriate env var and retry." >&2
    echo "" >&2
    exit 1
fi

exit 0
