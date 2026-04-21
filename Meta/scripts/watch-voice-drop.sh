#!/bin/bash
# watch-voice-drop.sh
# Watches the _drop folder and processes any new audio files.
# Triggered by launchd when files appear in the folder.

# --- launchd safety: set a known working directory FIRST ---
# launchd may spawn us with an invalid cwd (getcwd fails), so we must
# cd to an absolute path before doing anything — including dirname "$0".
VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
unset PWD OLDPWD 2>/dev/null || true
cd "$VAULT_DIR" || { echo "[$(date)] FATAL: cannot cd to $VAULT_DIR" >> /tmp/vault-voice-pipeline.log; exit 1; }


DROP_DIR="$VAULT_DIR/Inbox/Voice/_drop"
PROCESSING_DIR="$VAULT_DIR/Inbox/Voice/_processing"
SCRIPT_DIR="$VAULT_DIR/Meta/scripts"
LOG_FILE="/tmp/vault-voice-pipeline.log"

source "$SCRIPT_DIR/lib-agent.sh"
mkdir -p "$PROCESSING_DIR"

# No agent lock needed: mv is atomic — if two watchers race, only one wins the mv.
# The old lock was the #1 cause of stuck voice pipelines (crash → stale lock → silence).

echo "[$(date)] Watcher triggered, checking $DROP_DIR" >> "$LOG_FILE"

while true; do
    FOUND_AUDIO=0

    for AUDIO in "$DROP_DIR"/*.{m4a,mp3,wav,mp4,ogg,webm} ; do
        [ -f "$AUDIO" ] || continue
        FOUND_AUDIO=1
        echo "[$(date)] Found: $(basename "$AUDIO")" >> "$LOG_FILE"
        CLAIMED_AUDIO="$PROCESSING_DIR/$(basename "$AUDIO")"

        if ! mv "$AUDIO" "$CLAIMED_AUDIO" 2>/dev/null; then
            echo "[$(date)] Skipped (already claimed): $(basename "$AUDIO")" >> "$LOG_FILE"
            continue
        fi

        if "$SCRIPT_DIR/process-voice-memo.sh" "$CLAIMED_AUDIO" >> "$LOG_FILE" 2>&1; then
            echo "[$(date)] Processed successfully: $(basename "$CLAIMED_AUDIO")" >> "$LOG_FILE"
        else
            # Don't re-queue — the note already exists with status: failed.
            # Retry logic is in process-voice-memo.sh now. Re-queuing causes duplicates.
            echo "[$(date)] Processing failed: $(basename "$CLAIMED_AUDIO")" >> "$LOG_FILE"
            # Move to processed anyway (transcript exists, extraction will be retried)
            mv "$CLAIMED_AUDIO" "$VAULT_DIR/Inbox/Voice/_processed/" 2>/dev/null || true
        fi

        # Cooldown between memos — prevent Codex rate limit crashes
        sleep 5
    done

    if [ "$FOUND_AUDIO" -eq 0 ]; then
        break
    fi
done

echo "[$(date)] Watcher run complete" >> "$LOG_FILE"
