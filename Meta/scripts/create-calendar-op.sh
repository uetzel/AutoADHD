#!/bin/bash
# create-calendar-op.sh — Create a calendar operation file in Meta/operations/pending/
#
# Usage: ./create-calendar-op.sh "Event Title" "2026-04-05T20:00" "60" "attendee" "Description" "source-action.md"
#
# Args:
#   $1 = Event title / subject
#   $2 = When (ISO datetime, e.g. 2026-04-05T20:00)
#   $3 = Duration in minutes
#   $4 = Attendee (email, phone, or name)
#   $5 = Description (optional)
#   $6 = Source action filename (optional)
#
# Flow:
#   1. Generate op_id: op-cal-YYYYMMDD-HHMMSS
#   2. Create .md file in Meta/operations/pending/ with YAML frontmatter
#   3. Telegram notification fires automatically (vault-bot.py watches pending/)
#
# Exit codes:
#   0 = operation file created in pending/
#   1 = missing required arguments

set -euo pipefail
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/lib-agent.sh" 2>/dev/null || true

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATE=$(date +%Y-%m-%d)

# --- Args ---
SUBJECT="${1:-}"
WHEN="${2:-}"
DURATION="${3:-60}"
ATTENDEES="${4:-}"
DESCRIPTION="${5:-}"
SOURCE_ACTION="${6:-}"

if [ -z "$SUBJECT" ] || [ -z "$WHEN" ]; then
    echo "Usage: $0 <title> <when> [duration] [attendee] [description] [source-action]"
    echo "Example: $0 'Call with Waqas Malik' '2026-04-05T20:00' '60' '+4917682107312' 'Catch-up call' 'Call Waqas Malik.md'"
    exit 1
fi

# --- Generate op_id ---
OP_ID="op-cal-${TIMESTAMP}"

# --- Format human-readable date ---
# Try to parse the datetime for a friendly display
if command -v python3 &>/dev/null; then
    HUMAN_DATE=$(python3 -c "
from datetime import datetime
try:
    dt = datetime.fromisoformat('${WHEN}')
    print(dt.strftime('%A %B %-d, %Y, %H:%M') + ' CEST')
except:
    print('${WHEN}')
" 2>/dev/null) || HUMAN_DATE="$WHEN"
else
    HUMAN_DATE="$WHEN"
fi

# --- Paths ---
PENDING_DIR="$VAULT_DIR/Meta/operations/pending"
mkdir -p "$PENDING_DIR"
OP_FILE="$PENDING_DIR/${OP_ID}.md"

# --- Write operation file ---
cat > "$OP_FILE" << EOF
---
op_id: ${OP_ID}
type: calendar
status: pending
notify: true
source_action: "${SOURCE_ACTION}"
subject: "${SUBJECT}"
when: "${WHEN}"
duration: ${DURATION}
attendees: "${ATTENDEES}"
created: ${DATE}
execution_command: "calendar-create.sh '${OP_FILE}'"
---

## Event Details
Title: ${SUBJECT}
When: ${HUMAN_DATE}
Duration: ${DURATION} minutes
Attendees: ${ATTENDEES}
Description: ${DESCRIPTION}

---

*Calendar event created by calendar workflow. Approve via Telegram or /approve ${OP_ID}*
EOF

echo "[$TIMESTAMP] Calendar operation created: $OP_ID"
echo "  Subject: $SUBJECT"
echo "  When: $HUMAN_DATE"
echo "  Duration: ${DURATION} minutes"
echo "  Attendees: $ATTENDEES"
echo "  File: $OP_FILE"
