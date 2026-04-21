#!/bin/bash
# log-agent-feedback.sh — Append a structured entry to the agent feedback queue.
# Usage: ./log-agent-feedback.sh <agent> <event> <summary> [source] [files_changed] [notify]
#
# Examples:
#   ./log-agent-feedback.sh "VoicePipeline" "voice_processed" "Transcribed and extracted 3 people" "Inbox/Voice/memo.md" "" "true"
#   ./log-agent-feedback.sh "Retro" "retro_complete" "Vault health: 295 commits" "" "" "true"
#
# Best-effort: failures are silently ignored so calling agents are never blocked.

set -uo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FEEDBACK_FILE="$VAULT_DIR/Meta/agent-feedback.jsonl"

AGENT="${1:-unknown}"
EVENT="${2:-unknown}"
SUMMARY="${3:-}"
SOURCE="${4:-}"
FILES_CHANGED="${5:-}"
NOTIFY="${6:-true}"

# Build JSON entry using python3 for safe escaping
python3 -c "
import json, datetime, sys

entry = {
    'ts': datetime.datetime.now().isoformat(),
    'agent': sys.argv[1],
    'event': sys.argv[2],
    'summary': sys.argv[3],
    'source': sys.argv[4] if sys.argv[4] else None,
    'files_changed': [f.strip() for f in sys.argv[5].split(',') if f.strip()] if sys.argv[5] else [],
    'notify': sys.argv[6].lower() == 'true'
}

with open(sys.argv[7], 'a') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + '\n')
" "$AGENT" "$EVENT" "$SUMMARY" "$SOURCE" "$FILES_CHANGED" "$NOTIFY" "$FEEDBACK_FILE" 2>/dev/null || true
