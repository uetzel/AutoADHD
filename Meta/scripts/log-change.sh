#!/bin/bash
# log-change.sh
# Appends a single line to Meta/changelog.md
# Usage: ./log-change.sh "Extractor" "Processed 2026-03-16 - Voice - mercado.md: created [[Mercado Lagos]], 2 actions"
#
# Each agent calls this after finishing work. The changelog is browsable in Obsidian.

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CHANGELOG="$VAULT_DIR/Meta/changelog.md"

AGENT="${1:?Usage: log-change.sh AGENT_NAME DESCRIPTION}"
DESCRIPTION="${2:?Usage: log-change.sh AGENT_NAME DESCRIPTION}"

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)

# Create changelog if it doesn't exist
if [ ! -f "$CHANGELOG" ]; then
    cat > "$CHANGELOG" << 'EOF'
---
type: meta
name: Vault Changelog
source: ai-generated
---

# Vault Changelog

Every change made by an agent, logged in plain text. Scroll like a timeline.

EOF
fi

# Check if today's date header already exists
if ! grep -q "^## $DATE" "$CHANGELOG"; then
    echo "" >> "$CHANGELOG"
    echo "## $DATE" >> "$CHANGELOG"
    echo "" >> "$CHANGELOG"
fi

# Append the entry
echo "- **$AGENT** — $DESCRIPTION — \`$TIME\`" >> "$CHANGELOG"
