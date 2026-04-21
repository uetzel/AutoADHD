#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DROP_DIR="$VAULT_DIR/Inbox/Voice/_drop"
PROCESSED_DIR="$VAULT_DIR/Inbox/Voice/_processed"
VOICE_LOG="/tmp/vault-voice-pipeline.log"
BOT_LOG="/tmp/vault-telegram-bot.log"
UID_VALUE="$(id -u)"

source "$SCRIPT_DIR/lib-agent.sh"

print_section() {
    printf '\n== %s ==\n' "$1"
}

print_launch_agent_status() {
    local label="$1"

    if launchctl print "gui/$UID_VALUE/$label" >/dev/null 2>&1; then
        echo "$label: loaded"
    else
        echo "$label: not loaded"
    fi
}

print_log_tail() {
    local path="$1"
    local lines="${2:-10}"

    if [ -f "$path" ]; then
        tail -n "$lines" "$path"
    else
        echo "Log not found: $path"
    fi
}

cd "$VAULT_DIR"

print_section "Runtime Routing"
if [ -f "$VAULT_DIR/Meta/agent-runtimes.conf" ]; then
    sed -n '1,120p' "$VAULT_DIR/Meta/agent-runtimes.conf"
else
    echo "Missing Meta/agent-runtimes.conf"
fi

print_section "Launch Agents"
print_launch_agent_status "com.vault.voice-watcher"
print_launch_agent_status "com.vault.telegram-bot"
print_launch_agent_status "com.vault.daily-briefing"
print_launch_agent_status "com.vault.daily-retro"
print_launch_agent_status "com.vault.weekly-thinker"

print_section "Voice Queue"
drop_count=0
processed_count=0
if [ -d "$DROP_DIR" ]; then
    drop_count=$(find "$DROP_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
fi
if [ -d "$PROCESSED_DIR" ]; then
    processed_count=$(find "$PROCESSED_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
fi
echo "_drop files: $drop_count"
echo "_processed files: $processed_count"
if [ -d "$DROP_DIR" ]; then
    find "$DROP_DIR" -maxdepth 1 -type f | sed "s|$VAULT_DIR/||" | sort
fi

print_section "Worktree"
filtered_status="$(agent_filtered_worktree_status)"
if [ -n "$filtered_status" ]; then
    echo "Non-operational changes detected:"
    printf '%s\n' "$filtered_status"
else
    echo "Clean (ignoring operational noise)"
fi

print_section "Recent Voice Log"
print_log_tail "$VOICE_LOG" 20

print_section "Recent Telegram Bot Log"
print_log_tail "$BOT_LOG" 20
