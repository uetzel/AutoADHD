#!/bin/bash
# process-voice-memo.sh
# Takes an audio file, transcribes it, creates an Inbox note,
# then calls Claude CLI to process the vault and commit.
#
# Usage: ./process-voice-memo.sh /path/to/audio.m4a
# Optional: ./process-voice-memo.sh /path/to/audio.m4a --meeting (for multi-speaker)

set -Eeuo pipefail

# --- launchd safety: set a known working directory FIRST ---
# launchd may spawn us with an invalid cwd (getcwd fails), so we must
# cd to an absolute path before doing anything — including dirname "$0".
VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
unset PWD OLDPWD 2>/dev/null || true
cd "$VAULT_DIR" || { echo "FATAL: cannot cd to $VAULT_DIR" >&2; exit 1; }


# --- Config ---
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
SCRIPT_DIR="$VAULT_DIR/Meta/scripts"
source "$SCRIPT_DIR/lib-agent.sh"
DROP_DIR="$VAULT_DIR/Inbox/Voice/_drop"
PROCESSING_DIR="$VAULT_DIR/Inbox/Voice/_processing"
PROCESSED_DIR="$VAULT_DIR/Inbox/Voice/_processed"
WHISPER_MODEL="${WHISPER_MODEL:-medium}"
WHISPER_LANG="${WHISPER_LANG:-de}"

# --- Input ---
AUDIO_FILE="$1"
IS_MEETING="${2:-}"

if [ ! -f "$AUDIO_FILE" ]; then
    echo "Error: File not found: $AUDIO_FILE"
    exit 1
fi

FILENAME=$(basename "$AUDIO_FILE" | sed 's/\.[^.]*$//')
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NOTE_PATH=""
PROGRESS_DIR="$VAULT_DIR/Meta/.voice-progress"

echo "[$TIMESTAMP] Processing: $AUDIO_FILE"

# Helper: update voice progress (bot polls this to update the status message)
update_progress() {
    local stage="$1"
    local details="${2:-{}}"
    "$SCRIPT_DIR/update-voice-progress.sh" "$FILENAME" "$stage" "$details" 2>/dev/null || true
}

# --- Trap: write "failed" to progress on any crash ---
PIPELINE_STEP="init"
_pipeline_cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -n "${FILENAME:-}" ]; then
        update_progress "failed" "{\"error\": \"Pipeline crashed at: ${PIPELINE_STEP:-unknown}\"}" 2>/dev/null || true
    fi
}
trap _pipeline_cleanup EXIT

# --- Check for existing note (retry scenario) ---
# If this audio was already transcribed but extraction failed, reuse the existing note
# instead of creating a duplicate.
EXISTING_NOTE=$(grep -rl "audio_file: ${FILENAME}" "$VAULT_DIR/Inbox/Voice/" 2>/dev/null | head -1 || true)
if [ -n "$EXISTING_NOTE" ]; then
    EXISTING_STATUS=$(grep -oP '^status:\s*\K\S+' "$EXISTING_NOTE" 2>/dev/null || echo "")
    if [ "$EXISTING_STATUS" = "failed" ] || [ "$EXISTING_STATUS" = "transcribed" ]; then
        echo "[$TIMESTAMP] Found existing note for this audio: $(basename "$EXISTING_NOTE") (status: $EXISTING_STATUS)"
        echo "[$TIMESTAMP] Skipping transcription, retrying extraction..."
        NOTE_PATH="$EXISTING_NOTE"
        # Move audio to processed (it was already transcribed)
        mkdir -p "$PROCESSED_DIR"
        mv "$AUDIO_FILE" "$PROCESSED_DIR/" 2>/dev/null || true
        # Jump straight to extraction
        trap handle_pipeline_error ERR
        echo "--- Agent 1: Extractor (retry) ---"
        "$SCRIPT_DIR/send-telegram.sh" "🔄 Retrying extraction: $(basename "$NOTE_PATH" .md)" 2>/dev/null || true
        agent_note_set_status "$NOTE_PATH" "extracting"
        VAULT_AGENT_ALLOW_DIRTY=1 VAULT_AGENT_CONTEXT=voice-pipeline /bin/bash "$SCRIPT_DIR/run-extractor.sh" "Inbox/Voice/$(basename "$NOTE_PATH")"
        echo "--- Agent 2: Reviewer ---"
        VAULT_AGENT_ALLOW_DIRTY=1 VAULT_AGENT_CONTEXT=voice-pipeline /bin/bash "$SCRIPT_DIR/run-reviewer.sh" "$NOTE_PATH"
        echo "--- Rebuilding manifest ---"
        VAULT_AGENT_ALLOW_DIRTY=1 /bin/bash "$SCRIPT_DIR/build-manifest.sh"
        agent_assert_no_forbidden_worktree_paths "Voice pipeline" \
            Meta/research Thinking/Research Meta/Agents Meta/scripts \
            CLAUDE.md HOME.md AGENTS.md Meta/Architecture.md Meta/agent-runtimes.conf
        agent_stage_and_commit "[Pipeline] process: retry extraction for $(basename "$NOTE_PATH")" \
            "Inbox/Voice/$(basename "$NOTE_PATH")" Canon/ Thinking/ \
            Meta/MANIFEST.md Meta/AI-Reflections/ Meta/review-queue/ Meta/changelog.md
        "$SCRIPT_DIR/send-telegram.sh" "✅ Retry succeeded: $(basename "$NOTE_PATH" .md)" 2>/dev/null || true
        # Archive extracted note to _extracted/
        if [ -f "$NOTE_PATH" ] && grep -q "^status: extracted" "$NOTE_PATH" 2>/dev/null; then
            mkdir -p "$VAULT_DIR/Inbox/Voice/_extracted"
            mv "$NOTE_PATH" "$VAULT_DIR/Inbox/Voice/_extracted/" 2>/dev/null || true
            agent_stage_and_commit "[Pipeline] archive: move extracted note to _extracted/" \
                "Inbox/Voice/$(basename "$NOTE_PATH")" \
                "Inbox/Voice/_extracted/$(basename "$NOTE_PATH")"
        fi
        echo "[$TIMESTAMP] Retry extraction complete: $(basename "$NOTE_PATH")"
        exit 0
    elif [ "$EXISTING_STATUS" = "extracted" ]; then
        echo "[$TIMESTAMP] Note already extracted: $(basename "$EXISTING_NOTE"). Moving audio and skipping."
        mkdir -p "$PROCESSED_DIR"
        mv "$AUDIO_FILE" "$PROCESSED_DIR/" 2>/dev/null || true
        exit 0
    fi
fi

notify_pipeline_failure() {
    local reason="${1:-unknown failure}"
    # Write failure to progress file (bot will update the status message)
    update_progress "failed" "{\"reason\": \"$reason\"}" 2>/dev/null || true
    # Also send direct message as fallback (in case bot isn't polling)
    if [ -f "$HOME/.vault-bot-token" ] && [ -f "$HOME/.vault-bot-chat-id" ] && [ -n "${NOTE_PATH:-}" ]; then
        "$SCRIPT_DIR/send-telegram.sh" "❌ Pipeline failed: $(basename "${NOTE_PATH:-unknown}")
Reason: $reason" 2>/dev/null || true
    fi
}

mark_note_failed_if_needed() {
    local reason="${1:-unknown failure}"
    if [ -n "${NOTE_PATH:-}" ] && [ -f "$NOTE_PATH" ]; then
        local current_status
        current_status="$(agent_note_get_status "$NOTE_PATH" 2>/dev/null || true)"
        if [ "$current_status" != "extracted" ] && [ "$current_status" != "failed" ]; then
            agent_note_set_status "$NOTE_PATH" "failed" || true
        fi
        notify_pipeline_failure "$reason"
    fi
}

handle_pipeline_error() {
    local exit_code=$?
    local step="${PIPELINE_STEP:-unknown step}"
    mark_note_failed_if_needed "$step failed (exit $exit_code)"
    exit "$exit_code"
}

# Track which pipeline step is running — included in error messages
PIPELINE_STEP="init"

agent_require_commands git whisper python3
agent_clear_stale_git_locks >/dev/null 2>&1 || true
# Voice memos are real-time user input — retry if another agent holds the lock
export AGENT_LOCK_RETRY=true
export AGENT_LOCK_RETRY_MAX=3
export AGENT_LOCK_RETRY_DELAY=30
agent_acquire_lock "vault-agent-pipeline"

PIPELINE_STEP="metadata extraction"
# --- Extract metadata ---
echo "Extracting file metadata..."

# Get recording date from file (macOS mdls reads Spotlight metadata)
RECORD_DATE=$(mdls -name kMDItemRecordingDate -raw "$AUDIO_FILE" 2>/dev/null || echo "")
if [ -z "$RECORD_DATE" ] || [ "$RECORD_DATE" = "(null)" ]; then
    # Fallback: file creation date
    RECORD_DATE=$(mdls -name kMDItemContentCreationDate -raw "$AUDIO_FILE" 2>/dev/null || echo "")
fi
if [ -z "$RECORD_DATE" ] || [ "$RECORD_DATE" = "(null)" ]; then
    RECORD_DATE="${DATE} ${TIME}"
fi

# Get duration
DURATION=$(mdls -name kMDItemDurationSeconds -raw "$AUDIO_FILE" 2>/dev/null || echo "")
if [ "$DURATION" = "(null)" ]; then DURATION=""; fi
DURATION_FMT=""
if [ -n "$DURATION" ]; then
    # Round to integer seconds, format as MM:SS
    DURATION_INT=$(printf "%.0f" "$DURATION")
    DURATION_FMT="$((DURATION_INT / 60)):$(printf '%02d' $((DURATION_INT % 60)))"
fi

# Get GPS coordinates
# First: check if filename encodes location (from iPhone Shortcut: loc_LAT_LON_date.m4a)
LATITUDE=""
LONGITUDE=""
if echo "$FILENAME" | grep -q "^loc_"; then
    LATITUDE=$(echo "$FILENAME" | cut -d'_' -f2)
    LONGITUDE=$(echo "$FILENAME" | cut -d'_' -f3)
    echo "  GPS from filename: $LATITUDE, $LONGITUDE"
fi
# Fallback: check file metadata (works for files with embedded GPS)
if [ -z "$LATITUDE" ]; then
    LATITUDE=$(mdls -name kMDItemLatitude -raw "$AUDIO_FILE" 2>/dev/null || echo "")
    LONGITUDE=$(mdls -name kMDItemLongitude -raw "$AUDIO_FILE" 2>/dev/null || echo "")
    if [ "$LATITUDE" = "(null)" ]; then LATITUDE=""; fi
    if [ "$LONGITUDE" = "(null)" ]; then LONGITUDE=""; fi
fi

# Reverse geocode if we have coordinates (uses macOS CoreLocation via Python)
LOCATION_NAME=""
if [ -n "$LATITUDE" ] && [ -n "$LONGITUDE" ]; then
    LOCATION_NAME=$(python3 -c "
import json, urllib.request
try:
    url = f'https://nominatim.openstreetmap.org/reverse?lat=${LATITUDE}&lon=${LONGITUDE}&format=json&zoom=14'
    req = urllib.request.Request(url, headers={'User-Agent': 'VaultPipeline/1.0'})
    resp = urllib.request.urlopen(req, timeout=5)
    data = json.loads(resp.read())
    addr = data.get('address', {})
    city = addr.get('city', addr.get('town', addr.get('village', '')))
    country = addr.get('country', '')
    if city and country:
        print(f'{city}, {country}')
    elif country:
        print(country)
    else:
        print(data.get('display_name', '')[:60])
except:
    print('')
" 2>/dev/null || echo "")
fi

echo "  Date: $RECORD_DATE"
[ -n "$DURATION_FMT" ] && echo "  Duration: $DURATION_FMT"
[ -n "$LOCATION_NAME" ] && echo "  Location: $LOCATION_NAME"
[ -n "$LATITUDE" ] && echo "  GPS: $LATITUDE, $LONGITUDE"

PIPELINE_STEP="Whisper transcription"
# --- Transcribe ---
TMP_DIR=$(mktemp -d)

# Ensure ffmpeg is available (Whisper needs it for audio decoding)
if ! command -v ffmpeg &>/dev/null; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

WHISPER_DEVICE="${WHISPER_DEVICE:-mps}"
echo "Transcribing with Whisper (model: $WHISPER_MODEL, lang: $WHISPER_LANG, device: $WHISPER_DEVICE)..."
# 30-min timeout prevents infinite hangs (macOS has no `timeout` — use perl alarm)
# MPS = Apple Silicon GPU via Metal Performance Shaders (1.5-3x faster than CPU)
WHISPER_LOG=$(mktemp /tmp/whisper-err.XXXXXX)
perl -e 'alarm 1800; exec @ARGV' whisper "$AUDIO_FILE" \
    --model "$WHISPER_MODEL" \
    --language "$WHISPER_LANG" \
    --device "$WHISPER_DEVICE" \
    --output_format txt \
    --output_dir "$TMP_DIR" \
    2>"$WHISPER_LOG" || {
    echo "Whisper failed (device=$WHISPER_DEVICE). Stderr:" >&2
    cat "$WHISPER_LOG" >&2
    # MPS->CPU fallback: if GPU failed, retry on CPU
    if [ "$WHISPER_DEVICE" = "mps" ]; then
        echo "Retrying with CPU (this may be slower)..." >&2
        perl -e 'alarm 1800; exec @ARGV' whisper "$AUDIO_FILE" \
            --model "$WHISPER_MODEL" \
            --language "$WHISPER_LANG" \
            --device cpu \
            --output_format txt \
            --output_dir "$TMP_DIR" \
            2>"$WHISPER_LOG" || true
    fi
}
rm -f "$WHISPER_LOG"

TRANSCRIPT=$(cat "$TMP_DIR"/*.txt 2>/dev/null || echo "[Transcription failed]")
rm -rf "$TMP_DIR"

if [ "$TRANSCRIPT" = "[Transcription failed]" ]; then
    update_progress "failed" "{\"error\": \"Whisper transcription failed\"}"
    echo "Error: Transcription failed for $AUDIO_FILE"
    exit 1
fi

WORD_COUNT=$(echo "$TRANSCRIPT" | wc -w | tr -d ' ')
echo "Transcription complete ($WORD_COUNT words)"

# Notify: transcription done (stage 2 — bot will update progress message)
update_progress "transcribed" "{\"word_count\": $WORD_COUNT}"

# --- Create Inbox Note ---
# Generate a slug from filename, fallback to timestamp
SLUG=$(echo "$FILENAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
[ -z "$SLUG" ] && SLUG="voice-$TIMESTAMP"

if [ "$IS_MEETING" = "--meeting" ]; then
    SOURCE_TYPE="meeting"
    NOTE_NAME="${DATE} - Meeting - ${SLUG}"
else
    SOURCE_TYPE="voice"
    NOTE_NAME="${DATE} - Voice - ${SLUG}"
fi

NOTE_PATH="$VAULT_DIR/Inbox/Voice/${NOTE_NAME}.md"

# Avoid overwriting existing notes
COUNTER=1
while [ -f "$NOTE_PATH" ]; do
    NOTE_PATH="$VAULT_DIR/Inbox/Voice/${NOTE_NAME}-${COUNTER}.md"
    COUNTER=$((COUNTER + 1))
done

# Build frontmatter dynamically
{
    echo "---"
    echo "status: transcribed"
    echo "source: ${SOURCE_TYPE}"
    echo "recorded: ${RECORD_DATE}"
    [ -n "$DURATION_FMT" ] && echo "duration: ${DURATION_FMT}"
    [ -n "$LOCATION_NAME" ] && echo "location: \"${LOCATION_NAME}\""
    [ -n "$LATITUDE" ] && echo "gps: [${LATITUDE}, ${LONGITUDE}]"
    echo "audio_file: ${FILENAME}"
    echo "---"
    echo ""
    echo "# Raw"
    echo "${TRANSCRIPT}"
} > "$NOTE_PATH"

echo "Created inbox note: $(basename "$NOTE_PATH")"
trap handle_pipeline_error ERR

# --- Move audio to processed ---
mkdir -p "$PROCESSING_DIR"
mkdir -p "$PROCESSED_DIR"
mv "$AUDIO_FILE" "$PROCESSED_DIR/"
echo "Moved audio to _processed/"

# --- Run Agent Pipeline ---

PIPELINE_STEP="extractor"
# Agent 1: Extractor — deep extraction of people, events, concepts, actions
echo "--- Agent 1: Extractor ---"
agent_note_set_status "$NOTE_PATH" "extracting"
update_progress "extracting"
VAULT_AGENT_ALLOW_DIRTY=1 VAULT_AGENT_CONTEXT=voice-pipeline /bin/bash "$SCRIPT_DIR/run-extractor.sh" "Inbox/Voice/$(basename "$NOTE_PATH")"
update_progress "extracted"

# Agent 2: Reviewer — only if the Extractor actually created/modified Canon entries.
# If extraction found nothing (trivial memo, test, etc.), skip the full Claude QA call.
CANON_CHANGES=$(agent_git diff --name-only HEAD~1 HEAD -- Canon/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$CANON_CHANGES" -gt 0 ]; then
    PIPELINE_STEP="reviewer"
    echo "--- Agent 2: Reviewer ($CANON_CHANGES Canon files changed) ---"
    update_progress "reviewing"
    # Reviewer is QA, not critical path. If it fails or times out (5 min), continue.
    # Extraction already succeeded and committed — don't lose that work.
    REVIEWER_EXIT=0
    VAULT_AGENT_ALLOW_DIRTY=1 VAULT_AGENT_LOCK_HELD=1 VAULT_AGENT_CONTEXT=voice-pipeline \
        perl -e 'alarm 300; exec @ARGV' /bin/bash "$SCRIPT_DIR/run-reviewer.sh" "$NOTE_PATH" \
        2>&1 || REVIEWER_EXIT=$?
    if [ "$REVIEWER_EXIT" -ne 0 ]; then
        echo "WARN: Reviewer failed (exit $REVIEWER_EXIT), continuing pipeline"
        update_progress "reviewed" '{"reviewer": "skipped (failed)"}'
    fi
else
    echo "--- Skipping Reviewer (no Canon changes to QA) ---"
fi

PIPELINE_STEP="manifest rebuild"
# Rebuild manifest after extraction
echo "--- Rebuilding manifest ---"
VAULT_AGENT_ALLOW_DIRTY=1 /bin/bash "$SCRIPT_DIR/build-manifest.sh"

PIPELINE_STEP="commit and archive"
agent_assert_no_forbidden_worktree_paths "Voice pipeline" \
    Meta/research \
    Thinking/Research \
    Meta/Agents \
    Meta/scripts \
    CLAUDE.md \
    HOME.md \
    AGENTS.md \
    Meta/Architecture.md \
    Meta/agent-runtimes.conf

# Fallback: commit only pipeline-owned paths if something remains.
agent_stage_and_commit "[Pipeline] process: fallback commit for $(basename "$NOTE_PATH")" \
    "Inbox/Voice/$(basename "$NOTE_PATH")" \
    Canon/ \
    Thinking/ \
    Meta/MANIFEST.md \
    Meta/AI-Reflections/ \
    Meta/review-queue/ \
    Meta/changelog.md

# --- Build extraction summary for progress message ---
EXTRACTED_SECTION=""
if [ -f "$NOTE_PATH" ]; then
    EXTRACTED_SECTION=$(sed -n '/^## Extracted/,/^## /p' "$NOTE_PATH" | head -30)
fi

SUMMARY=""
if [ -n "$EXTRACTED_SECTION" ]; then
    SUMMARY=$(echo "$EXTRACTED_SECTION" | grep -E '^\s*-' | head -10 | sed 's/^[[:space:]]*//')
fi

if [ -z "$SUMMARY" ]; then
    # Fallback: count changed files from the last commit
    CHANGED=$(cd "$VAULT_DIR" && agent_git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -v "^Inbox/Voice/" | head -10)
    CHANGE_COUNT=$(echo "$CHANGED" | grep -c . 2>/dev/null || echo "0")
    SUMMARY="${CHANGE_COUNT} files created/updated"
fi

# Write completion to progress file — bot will build the final message
ESCAPED_SUMMARY=$(echo "$SUMMARY" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')
update_progress "complete" "{\"summary\": $ESCAPED_SUMMARY}"

# Log to agent feedback queue
"$SCRIPT_DIR/log-agent-feedback.sh" \
    "VoicePipeline" \
    "voice_processed" \
    "Voice memo transcribed and processed: $(basename "$NOTE_PATH" .md 2>/dev/null)" \
    "$NOTE_PATH" \
    "" \
    "true" 2>/dev/null || true

# --- Archive extracted note to keep Inbox/Voice/ clean ---
# Only active (transcribed/failed) notes stay at the root level.
# Extracted notes move to _extracted/ so the Inbox is human-scannable.
EXTRACTED_DIR="$VAULT_DIR/Inbox/Voice/_extracted"
if [ -f "$NOTE_PATH" ]; then
    NOTE_STATUS=$(grep -oP '^status:\s*\K\S+' "$NOTE_PATH" 2>/dev/null || echo "")
    if [ "$NOTE_STATUS" = "extracted" ]; then
        mkdir -p "$EXTRACTED_DIR"
        mv "$NOTE_PATH" "$EXTRACTED_DIR/" 2>/dev/null || true
        agent_stage_and_commit "[Pipeline] archive: move extracted note to _extracted/" \
            "Inbox/Voice/$(basename "$NOTE_PATH")" \
            "Inbox/Voice/_extracted/$(basename "$NOTE_PATH")"
    fi
fi

echo "[$TIMESTAMP] Done processing: $(basename "$NOTE_PATH")"
