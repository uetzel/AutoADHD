#!/bin/bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"

notify_retry_failure() {
    local note_path="${1:?note path required}"
    local reason="${2:-unknown failure}"
    if [ -f "$HOME/.vault-bot-token" ] && [ -f "$HOME/.vault-bot-chat-id" ]; then
        "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Retry failed*
Note: $(basename "$note_path")
Reason: $reason" 2>/dev/null || true
    fi
}

FAILED_NOTES="$(grep -rl '^status: failed$' Inbox/ 2>/dev/null | sort || true)"

if [ -z "$FAILED_NOTES" ]; then
    echo "No failed notes found."
    exit 0
fi

agent_assert_clean_worktree "Retry failed notes"

# Skip duplicates — only retry originals, not -1/-2 copies
echo "$FAILED_NOTES" | grep -v '\-[0-9]\.md$' | while IFS= read -r note_path; do
    [ -n "$note_path" ] || continue
    echo "Retrying: $note_path"
    agent_note_set_status "$note_path" "extracting"
    if ! /bin/bash "$SCRIPT_DIR/run-extractor.sh" "$note_path"; then
        agent_note_set_status "$note_path" "failed" || true
        notify_retry_failure "$note_path" "extractor rerun failed"
    fi
    # Cooldown between retries to avoid rate limits
    sleep 10
done
