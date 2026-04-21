#!/bin/bash
# queue-review.sh — Add an item to the review queue
# Usage: ./queue-review.sh "Canon/People/Alex Chen.md" "born" "1992" "Extracted from voice memo — verify birthyear"
#
# Items get pushed to Telegram by the bot after pipeline runs.

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
QUEUE="$VAULT_DIR/Meta/review-queue.md"

FILE="${1:?Usage: queue-review.sh FILE FIELD VALUE REASON}"
FIELD="${2:?Usage: queue-review.sh FILE FIELD VALUE REASON}"
VALUE="${3:?Usage: queue-review.sh FILE FIELD VALUE REASON}"
REASON="${4:-AI-extracted, needs verification}"

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)

cat >> "$QUEUE" << EOF

---
status: pending
date: $DATE
file: $FILE
field: $FIELD
value: $VALUE
reason: $REASON
---
EOF
