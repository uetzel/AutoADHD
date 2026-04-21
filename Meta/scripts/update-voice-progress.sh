#!/bin/bash
# update-voice-progress.sh — Write pipeline progress for the bot to pick up.
#
# Usage: ./update-voice-progress.sh <slug> <stage> [details]
#
# Stages: received, transcribed, extracting, extracted, reviewing, complete, failed
# The bot polls Meta/.voice-progress/<slug>.json and edits the Telegram message.
#
# Example:
#   ./update-voice-progress.sh tg_2026-04-02_190833 transcribed '{"word_count": 1496}'
#   ./update-voice-progress.sh tg_2026-04-02_190833 complete '{"summary": "Created: ..."}'

VAULT_DIR="${VAULT_DIR:-${VAULT_DIR:-$HOME/VaultSandbox}}"
PROGRESS_DIR="$VAULT_DIR/Meta/.voice-progress"

SLUG="${1:?Usage: update-voice-progress.sh SLUG STAGE [DETAILS_JSON]}"
STAGE="${2:?Usage: update-voice-progress.sh SLUG STAGE [DETAILS_JSON]}"
DETAILS="${3:-{}}"

PROGRESS_FILE="$PROGRESS_DIR/${SLUG}.json"

if [ ! -f "$PROGRESS_FILE" ]; then
    echo "WARN: No progress file for $SLUG — bot hasn't saved message_id yet?" >&2
    exit 0  # Don't fail the pipeline over missing progress tracking
fi

# Use Python for the entire read-modify-write cycle to avoid bash string embedding issues.
# Pass arguments via sys.argv, not shell variable interpolation.
python3 - "$PROGRESS_FILE" "$STAGE" "$DETAILS" <<'PYEOF'
import json, sys, datetime

progress_file = sys.argv[1]
new_stage = sys.argv[2]
details_json = sys.argv[3]

try:
    with open(progress_file, "r") as f:
        existing = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, OSError):
    existing = {}

try:
    details = json.loads(details_json)
except json.JSONDecodeError:
    details = {}

# Preserve critical fields (message_id, chat_id) through all updates
existing["stage"] = new_stage
existing["stage_ts"] = datetime.datetime.now().isoformat()
existing.update(details)

# Track stage history
history = existing.get("stages", [])
history.append({"stage": new_stage, "ts": datetime.datetime.now().isoformat()})
existing["stages"] = history

# Remove _last_displayed_stage so the bot picks up the change on next poll
existing.pop("_last_displayed_stage", None)

with open(progress_file, "w") as f:
    json.dump(existing, f)
PYEOF

if [ $? -ne 0 ]; then
    # If Python fails entirely, DON'T overwrite the file (preserves message_id)
    echo "WARN: Python progress update failed for $SLUG — leaving file intact" >&2
fi
