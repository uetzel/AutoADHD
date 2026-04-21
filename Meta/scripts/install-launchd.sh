#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
UID_VALUE="$(id -u)"

PLISTS=(
    "com.vault.voice-watcher.plist"
    "com.vault.daily-briefing.plist"
    "com.vault.daily-retro.plist"
    "com.vault.weekly-thinker.plist"
    "com.vault.telegram-bot.plist"
    "com.vault.sprint-worker.plist"
)

mkdir -p "$LAUNCH_AGENTS_DIR"

reload_launch_agent() {
    local label="$1"
    local plist_path="$2"

    launchctl bootout "gui/$UID_VALUE/$label" 2>/dev/null || true

    if launchctl bootstrap "gui/$UID_VALUE" "$plist_path" 2>/dev/null; then
        return 0
    fi

    echo "bootstrap failed for $label; falling back to unload/load" >&2
    launchctl unload "$plist_path" 2>/dev/null || true
    launchctl load "$plist_path"
}

for plist in "${PLISTS[@]}"; do
    src="$SCRIPT_DIR/$plist"
    dest="$LAUNCH_AGENTS_DIR/$plist"
    label="${plist%.plist}"

    cp "$src" "$dest"
    reload_launch_agent "$label" "$dest"
done

echo "Installed and reloaded vault launch agents from $SCRIPT_DIR"
