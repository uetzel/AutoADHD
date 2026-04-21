#!/bin/bash
# run-sprint-worker.sh — Async sprint task runner
#
# Scans Meta/sprint/active/ for tasks with status: ready and assignee: codex (or claude).
# Picks the highest priority, runs it via invoke-agent.sh, marks validate on success.
# Sends Telegram notification on completion or failure.
#
# Designed to run via launchd every 30 minutes, or manually.
# Uses file locking to prevent concurrent runs.
#
# Usage: ./run-sprint-worker.sh
#   or:  ./run-sprint-worker.sh --dry-run   (show what it would pick up, don't run)

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ACTIVE_DIR="$VAULT_DIR/Meta/sprint/active"
LOCK_FILE="/tmp/sprint-worker.lock"
DRY_RUN="${1:-}"

echo "[$TIMESTAMP] Sprint worker starting..."

# --- Lock: prevent concurrent runs ---
if [ -f "$LOCK_FILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -lt 3600 ]; then
        echo "Another sprint worker is running (lock age: ${LOCK_AGE}s). Exiting."
        exit 0
    fi
    echo "Stale lock found (${LOCK_AGE}s). Removing."
    rm -f "$LOCK_FILE"
fi
echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# --- Find eligible task ---
if [ ! -d "$ACTIVE_DIR" ]; then
    echo "No active sprint directory. Nothing to do."
    exit 0
fi

# Priority order: high=0, medium=1, low=2
BEST_TASK=""
BEST_PRIORITY=99
BEST_NAME=""
BEST_ASSIGNEE=""

for task_file in "$ACTIVE_DIR"/*.md; do
    [ -f "$task_file" ] || continue

    status=$(grep -m1 '^status:' "$task_file" | sed 's/status:[[:space:]]*//' | tr -d '"' | xargs)
    assignee=$(grep -m1 '^assignee:' "$task_file" | sed 's/assignee:[[:space:]]*//' | tr -d '"' | xargs)
    priority=$(grep -m1 '^priority:' "$task_file" | sed 's/priority:[[:space:]]*//' | tr -d '"' | xargs)
    name=$(grep -m1 '^name:' "$task_file" | sed 's/name:[[:space:]]*//' | tr -d '"')

    # Only pick up tasks that are ready and assigned to an AI
    if [ "$status" != "ready" ]; then
        continue
    fi
    if [ "$assignee" != "codex" ] && [ "$assignee" != "claude" ]; then
        continue
    fi

    # Check dependency — skip if upstream task isn't done
    depends_on=$(grep -m1 '^depends_on:' "$task_file" | sed 's/depends_on:[[:space:]]*//' | tr -d '"' | xargs)
    if [ -n "$depends_on" ]; then
        dep_satisfied=false
        for dep_file in "$ACTIVE_DIR"/*.md "$VAULT_DIR/Meta/sprint/done/"*.md; do
            [ -f "$dep_file" ] || continue
            dep_name=$(grep -m1 '^name:' "$dep_file" | sed 's/name:[[:space:]]*//' | tr -d '"')
            dep_status=$(grep -m1 '^status:' "$dep_file" | sed 's/status:[[:space:]]*//' | tr -d '"' | xargs)
            # Match by substring (fuzzy) — "Email Workflow V1" matches "email-workflow-v1"
            if echo "$dep_name" | grep -qi "$(echo "$depends_on" | tr '-' ' ')"; then
                if [ "$dep_status" = "done" ] || [ "$dep_status" = "validate" ]; then
                    dep_satisfied=true
                fi
                break
            fi
        done
        if [ "$dep_satisfied" = false ]; then
            echo "  Skipping '$name' — waiting on dependency: $depends_on"
            continue
        fi
    fi

    # Priority scoring
    case "$priority" in
        high) prio_score=0 ;;
        medium) prio_score=1 ;;
        low) prio_score=2 ;;
        *) prio_score=1 ;;
    esac

    if [ "$prio_score" -lt "$BEST_PRIORITY" ]; then
        BEST_PRIORITY=$prio_score
        BEST_TASK="$task_file"
        BEST_NAME="$name"
        BEST_ASSIGNEE="$assignee"
    fi
done

if [ -z "$BEST_TASK" ]; then
    echo "[$TIMESTAMP] No ready tasks for AI. All clear."
    rm -f "$LOCK_FILE"
    exit 0
fi

echo "[$TIMESTAMP] Picked up: $BEST_NAME (assignee: $BEST_ASSIGNEE, priority: $BEST_PRIORITY)"

if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "[DRY RUN] Would run: $BEST_NAME via $BEST_ASSIGNEE"
    echo "Task file: $BEST_TASK"
    # Show any tasks waiting on dependencies
    echo ""
    echo "Blocked tasks (waiting on dependencies):"
    for bf in "$ACTIVE_DIR"/*.md; do
        [ -f "$bf" ] || continue
        bs=$(grep -m1 '^status:' "$bf" | sed 's/status:[[:space:]]*//' | tr -d '"' | xargs)
        bd=$(grep -m1 '^depends_on:' "$bf" | sed 's/depends_on:[[:space:]]*//' | tr -d '"' | xargs)
        bn=$(grep -m1 '^name:' "$bf" | sed 's/name:[[:space:]]*//' | tr -d '"')
        if [ -n "$bd" ] && { [ "$bs" = "blocked" ] || [ "$bs" = "waiting" ]; }; then
            echo "  - $bn → waiting on: $bd"
        fi
    done
    exit 0
fi

# --- Mark in-progress ---
sed -i.bak "s/^status: ready/status: in-progress/" "$BEST_TASK"
rm -f "${BEST_TASK}.bak"

# --- Build prompt from task file ---
TASK_CONTENT=$(cat "$BEST_TASK")
DONE_CRITERIA=$(grep -m1 '^done_criteria:' "$BEST_TASK" | sed 's/done_criteria:[[:space:]]*//' | tr -d '"')
VALIDATE=$(grep -m1 '^validate:' "$BEST_TASK" | sed 's/validate:[[:space:]]*//' | tr -d '"')

# Read input files listed in the task
INPUT_FILES=$(grep -A 20 '^input:' "$BEST_TASK" | grep '^[[:space:]]*-' | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d '"')
INPUT_CONTEXT=""
while IFS= read -r input_file; do
    [ -z "$input_file" ] && continue
    FULL_PATH="$VAULT_DIR/$input_file"
    if [ -f "$FULL_PATH" ]; then
        INPUT_CONTEXT="${INPUT_CONTEXT}
--- FILE: $input_file ---
$(head -100 "$FULL_PATH")
--- END ---
"
    fi
done <<< "$INPUT_FILES"

PROMPT="You are working on a sprint task for the VaultSandbox Obsidian vault.

## YOUR TASK
$BEST_NAME

## TASK CONTRACT
$TASK_CONTENT

## DONE CRITERIA
$DONE_CRITERIA

## VALIDATION
$VALIDATE

## KEY FILES (read more at runtime if needed)
$INPUT_CONTEXT

## HARD BOUNDARIES
- Do NOT edit: CLAUDE.md, Meta/Architecture.md, Meta/scripts/*.sh (unless listed in output_files)
- Do NOT delete any files
- Read CLAUDE.md and any referenced skill files before starting
- Commit your work with a clear message prefixed with the task name
- If you get stuck, write what you tried and what blocked you to the task file under ## Blocked

## GO
Read the task contract. Build what it asks for. Run the validation if possible. Commit."

echo "[$TIMESTAMP] Running via invoke-agent.sh ($BEST_ASSIGNEE)..."

# Run the agent
OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" "$BEST_ASSIGNEE" "$PROMPT" 2>&1) || {
    EXIT_CODE=$?
    echo "[$TIMESTAMP] Agent failed with exit code $EXIT_CODE"
    echo "$OUTPUT" | tail -20

    # Mark task as failed
    sed -i.bak "s/^status: in-progress/status: ready/" "$BEST_TASK"
    rm -f "${BEST_TASK}.bak"

    # Add changelog entry
    CHANGELOG_ENTRY="  - \"$DATE: Sprint worker attempted via $BEST_ASSIGNEE. Failed (exit $EXIT_CODE). Returned to ready.\""
    sed -i.bak "/^changelog:/a\\
$CHANGELOG_ENTRY" "$BEST_TASK"
    rm -f "${BEST_TASK}.bak"

    # Telegram notification
    "$SCRIPT_DIR/send-telegram.sh" "❌ Sprint worker failed on: $BEST_NAME

Exit code: $EXIT_CODE
Assignee: $BEST_ASSIGNEE

Task returned to ready status." 2>/dev/null || true

    exit 1
}

echo "[$TIMESTAMP] Agent completed. Marking validate."

# --- Mark validate ---
sed -i.bak "s/^status: in-progress/status: validate/" "$BEST_TASK"
rm -f "${BEST_TASK}.bak"

# Add changelog entry
DATE=$(date +%Y-%m-%d)
CHANGELOG_ENTRY="  - \"$DATE: Sprint worker completed via $BEST_ASSIGNEE. Status: validate. Awaiting review.\""
sed -i.bak "/^changelog:/a\\
$CHANGELOG_ENTRY" "$BEST_TASK"
rm -f "${BEST_TASK}.bak"

# Commit results
cd "$VAULT_DIR"
git add -A 2>/dev/null || true
git commit -m "[Sprint Worker] $BEST_NAME — completed by $BEST_ASSIGNEE, awaiting review" 2>/dev/null || true

# Telegram notification
"$SCRIPT_DIR/send-telegram.sh" "✅ Sprint worker completed: $BEST_NAME

Assignee: $BEST_ASSIGNEE
Status: validate (ready for review)

/review to see all pending items" 2>/dev/null || true

# --- Auto-promote: check if any tasks were waiting on this one ---
PROMOTED=0
for waiting_task in "$ACTIVE_DIR"/*.md; do
    [ -f "$waiting_task" ] || continue
    w_status=$(grep -m1 '^status:' "$waiting_task" | sed 's/status:[[:space:]]*//' | tr -d '"' | xargs)
    w_depends=$(grep -m1 '^depends_on:' "$waiting_task" | sed 's/depends_on:[[:space:]]*//' | tr -d '"' | xargs)
    w_name=$(grep -m1 '^name:' "$waiting_task" | sed 's/name:[[:space:]]*//' | tr -d '"')

    # Only promote tasks that are blocked (status: blocked or waiting)
    if [ "$w_status" != "blocked" ] && [ "$w_status" != "waiting" ]; then
        continue
    fi
    if [ -z "$w_depends" ]; then
        continue
    fi

    # Check if this completed task matches the dependency
    if echo "$BEST_NAME" | grep -qi "$(echo "$w_depends" | tr '-' ' ')"; then
        echo "[$TIMESTAMP] Auto-promoting: $w_name (was waiting on $BEST_NAME)"
        sed -i.bak "s/^status: $w_status/status: ready/" "$waiting_task"
        rm -f "${waiting_task}.bak"
        CHANGELOG_ENTRY="  - \"$DATE: Auto-promoted to ready. Dependency '$BEST_NAME' completed.\""
        sed -i.bak "/^changelog:/a\\
$CHANGELOG_ENTRY" "$waiting_task"
        rm -f "${waiting_task}.bak"
        PROMOTED=$((PROMOTED + 1))
    fi
done

if [ "$PROMOTED" -gt 0 ]; then
    "$SCRIPT_DIR/send-telegram.sh" "🔗 $PROMOTED task(s) unblocked by: $BEST_NAME
Sprint worker will pick them up next cycle." 2>/dev/null || true
    # Commit the promotions
    cd "$VAULT_DIR"
    git add Meta/sprint/active/ 2>/dev/null || true
    git commit -m "[Sprint Worker] Auto-promoted $PROMOTED task(s) after $BEST_NAME completed" 2>/dev/null || true
fi

"$SCRIPT_DIR/log-agent-feedback.sh" "SprintWorker" "task_completed" "Completed: $BEST_NAME" "" "" "false" 2>/dev/null || true

echo "[$TIMESTAMP] Sprint worker done. Task: $BEST_NAME → validate."
