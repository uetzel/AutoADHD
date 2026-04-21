#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SAFE_CWD="/tmp"
DROP_DIR="$VAULT_DIR/Inbox/Voice/_drop"
CHANGELOG="$VAULT_DIR/Meta/changelog.md"
UID_VALUE="$(id -u)"
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}"

unset PWD OLDPWD
mkdir -p "$SAFE_CWD"
cd "$SAFE_CWD"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

source "$SCRIPT_DIR/lib-agent.sh"

FAILURES=0

print_ok() {
    printf '[OK] %s\n' "$1"
}

print_fail() {
    printf '[FAIL] %s\n' "$1"
    FAILURES=$((FAILURES + 1))
}

check_telegram_bot() {
    if launchctl print "gui/$UID_VALUE/com.vault.telegram-bot" 2>/dev/null | grep -q "state = running"; then
        print_ok "Telegram bot process alive"
    else
        print_fail "Telegram bot process not running"
    fi
}

check_voice_watcher() {
    if launchctl print "gui/$UID_VALUE/com.vault.voice-watcher" >/dev/null 2>&1; then
        print_ok "Voice watcher launchd job loaded"
    else
        print_fail "Voice watcher launchd job not loaded"
    fi
}

check_drop_backlog() {
    local count=0
    if [ -d "$DROP_DIR" ]; then
        count=$(find "$DROP_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
    fi

    if [ "$count" -eq 0 ]; then
        print_ok "_drop backlog clear (0 files)"
    else
        print_fail "_drop backlog has $count file(s)"
    fi
}

check_git_state() {
    local filtered_status
    local git_dir
    local lock_found=0
    local lock_file

    filtered_status="$(agent_filtered_worktree_status)"
    if [ -z "$filtered_status" ]; then
        print_ok "Git worktree clean"
    else
        print_fail "Git worktree has non-operational changes"
    fi

    git_dir="$(git -C "$VAULT_DIR" rev-parse --git-dir 2>/dev/null || true)"
    if [ -n "$git_dir" ]; then
        for lock_file in "$VAULT_DIR/$git_dir/index.lock" "$VAULT_DIR/$git_dir/HEAD.lock"; do
            if [ -e "$lock_file" ]; then
                lock_found=1
            fi
        done
    fi

    if [ "$lock_found" -eq 0 ]; then
        print_ok "No stuck git lock files"
    else
        print_fail "Git lock file present"
    fi
}

check_codex() {
    local version_output

    if [ -z "$CODEX_BIN" ]; then
        print_fail "Codex CLI not found"
        return
    fi

    if version_output="$("$CODEX_BIN" --version 2>/dev/null)"; then
        print_ok "Codex CLI reachable (${version_output})"
    else
        print_fail "Codex CLI not reachable"
    fi
}

check_last_pipeline_run() {
    local age_minutes
    age_minutes="$(CHANGELOG_PATH="$CHANGELOG" python3 <<'PYEOF'
import os
import re
from datetime import datetime

path = os.environ["CHANGELOG_PATH"]
if not os.path.exists(path):
    print("MISSING")
    raise SystemExit

current_date = None
last_dt = None
date_re = re.compile(r"^## (\d{4}-\d{2}-\d{2})$")
time_re = re.compile(r"`(\d{2}):(\d{2})`")

with open(path, "r") as fh:
    for raw_line in fh:
        line = raw_line.rstrip("\n")
        m = date_re.match(line)
        if m:
            current_date = m.group(1)
            continue
        if current_date:
            t = time_re.search(line)
            if t:
                dt = datetime.strptime(
                    f"{current_date} {t.group(1)}:{t.group(2)}",
                    "%Y-%m-%d %H:%M",
                )
                last_dt = dt

if last_dt is None:
    print("MISSING")
    raise SystemExit

now = datetime.now()
delta = now - last_dt
print(int(delta.total_seconds() // 60))
PYEOF
)"

    if [ "$age_minutes" = "MISSING" ]; then
        print_fail "No changelog pipeline timestamp found"
        return
    fi

    if [ "$age_minutes" -le 1440 ]; then
        print_ok "Last changelog entry is ${age_minutes} minute(s) old"
    else
        print_fail "Last changelog entry is ${age_minutes} minute(s) old"
    fi
}

check_telegram_bot
check_voice_watcher
check_drop_backlog
check_git_state
check_codex
check_last_pipeline_run

exit "$FAILURES"
