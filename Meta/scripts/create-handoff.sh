#!/bin/bash
# create-handoff.sh — Create a handoff file and notify via Telegram
# Called by Claude (Cowork/CLI) when handing work to Codex.
#
# Usage: ./create-handoff.sh "task name" <<'EOF'
# [handoff body in markdown]
# EOF
#
# Or: ./create-handoff.sh "task name" "path/to/handoff-body.md"

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOFF_DIR="$VAULT_DIR/Meta/handoffs"

TASK_NAME="${1:?Usage: create-handoff.sh 'task name' [body-file or stdin]}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATE_TODAY=$(date +%Y-%m-%d)
SAFE_NAME=$(printf '%s' "$TASK_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-')

mkdir -p "$HANDOFF_DIR"
FILENAME="$HANDOFF_DIR/$TIMESTAMP-$SAFE_NAME.md"

# Read body from file arg or stdin
if [ -n "${2:-}" ] && [ -f "$2" ]; then
    BODY=$(cat "$2")
elif [ ! -t 0 ]; then
    BODY=$(cat)
else
    echo "Provide handoff body via stdin or as second argument." >&2
    exit 1
fi

# Write handoff file
cat > "$FILENAME" << HEREDOC
---
type: handoff
from: claude
to: codex
created: $DATE_TODAY $(date +%H:%M)
status: pending
priority: high
notify_human: true
---

## Task: $TASK_NAME

$BODY
HEREDOC

echo "Handoff created: $FILENAME"

# Notify via Telegram
"$SCRIPT_DIR/send-telegram.sh" "🔄 *Handoff: Claude → Codex*
Task: $TASK_NAME
Reason: Token limit or task better suited for Codex

⚡ Run:
\`\`\`
cd ~/VaultSandbox
./Meta/scripts/run-handoff.sh $FILENAME
\`\`\`" 2>/dev/null || true

echo "Telegram notification sent."
echo "$FILENAME"
