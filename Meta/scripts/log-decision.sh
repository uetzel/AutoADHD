#!/bin/bash
# log-decision.sh
# Appends a decision entry to Meta/decisions-log.md
# Usage: ./log-decision.sh "Title" "Decided" "Why" "Rejected" "Check later" "Source"
#
# Example:
#   ./log-decision.sh \
#     "Use Codex for extraction" \
#     "Route Extractor agent to Codex CLI instead of Claude" \
#     "Codex is faster and cheaper for structured extraction tasks" \
#     "Keep on Claude (slower, more expensive for this use case)" \
#     "If extraction quality drops, switch back" \
#     "Session 14"

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LOG="$VAULT_DIR/Meta/decisions-log.md"

TITLE="${1:?Usage: log-decision.sh TITLE DECIDED WHY REJECTED CHECK_LATER SOURCE}"
DECIDED="${2:?}"
WHY="${3:?}"
REJECTED="${4:-None considered}"
CHECK_LATER="${5:-N/A}"
SOURCE="${6:-unknown}"

DATETIME=$(date '+%Y-%m-%d %H:%M')

# Insert after the --- separator (line 9-ish), before existing entries
# Find the first --- after the header and insert after it
python3 - "$LOG" "$DATETIME" "$TITLE" "$DECIDED" "$WHY" "$REJECTED" "$CHECK_LATER" "$SOURCE" << 'PYEOF'
import sys

log_path = sys.argv[1]
datetime_str, title, decided, why, rejected, check_later, source = sys.argv[2:9]

entry = f"""
## {datetime_str} — {title}
- **Decided:** {decided}
- **Why:** {why}
- **Rejected:** {rejected}
- **Check later:** {check_later}
- **Source:** {source}
- **Status:** active
"""

with open(log_path, "r") as f:
    content = f.read()

# Insert after the first "---" separator (end of header)
marker = "\n---\n"
idx = content.find(marker)
if idx >= 0:
    insert_point = idx + len(marker)
    content = content[:insert_point] + entry + content[insert_point:]
else:
    content += entry

with open(log_path, "w") as f:
    f.write(content)

print(f"Decision logged: {title}")
PYEOF
