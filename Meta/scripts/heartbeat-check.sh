#!/bin/bash
# heartbeat-check.sh — Are the agents alive?
#
# Checks whether each scheduled agent actually ran in its expected window.
# Outputs compact status lines. Used by daily-briefing.sh.
#
# COMPATIBLE with macOS bash 3.2 (no associative arrays).
# Exit 0 always (informational only). Failures are reported, not fatal.

set -uo pipefail
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
NOW=$(date +%s)

# --- Helper: check a single log file or directory for freshness ---
check_agent() {
    local agent="$1"
    local max_hours="$2"
    local evidence="$3"
    local full_path="$VAULT_DIR/$evidence"
    local max_seconds=$((max_hours * 3600))

    if [ -f "$full_path" ]; then
        local mtime
        mtime=$(stat -f %m "$full_path" 2>/dev/null || stat -c %Y "$full_path" 2>/dev/null || echo 0)
        local age=$(( NOW - mtime ))
        if [ "$age" -gt "$max_seconds" ]; then
            local hours_ago=$(( age / 3600 ))
            echo "❌ ${agent}: last ran ${hours_ago}h ago (expected within ${max_hours}h)"
        else
            echo "✅ ${agent}: healthy"
        fi
    elif [ -d "$full_path" ]; then
        # Find most recent .md file in directory
        local newest_mtime=0
        for f in "$full_path"/*.md; do
            [ -f "$f" ] || continue
            local mt
            mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
            if [ "$mt" -gt "$newest_mtime" ]; then
                newest_mtime=$mt
            fi
        done
        if [ "$newest_mtime" -eq 0 ]; then
            echo "❌ ${agent}: no evidence found ($evidence empty)"
            return
        fi
        local age=$(( NOW - newest_mtime ))
        if [ "$age" -gt "$max_seconds" ]; then
            local hours_ago=$(( age / 3600 ))
            echo "❌ ${agent}: last ran ${hours_ago}h ago (expected within ${max_hours}h)"
        else
            echo "✅ ${agent}: healthy"
        fi
    else
        echo "❌ ${agent}: no evidence found ($evidence missing)"
    fi
}

check_heartbeat_file() {
    local agent="$1"
    local max_hours="$2"
    local heartbeat_name="$3"
    local heartbeat_path="$HOME/.vault/heartbeats/$heartbeat_name"
    local max_seconds=$((max_hours * 3600))

    if [ ! -f "$heartbeat_path" ]; then
        echo "❌ ${agent}: no heartbeat found ($heartbeat_name missing)"
        return
    fi

    local last_ts
    last_ts=$(tr -dc '0-9' < "$heartbeat_path" 2>/dev/null || true)
    if [ -z "$last_ts" ]; then
        echo "❌ ${agent}: invalid heartbeat ($heartbeat_name unreadable)"
        return
    fi

    local age=$(( NOW - last_ts ))
    if [ "$age" -gt "$max_seconds" ]; then
        local hours_ago=$(( age / 3600 ))
        echo "❌ ${agent}: last ran ${hours_ago}h ago (expected within ${max_hours}h)"
    else
        echo "✅ ${agent}: healthy"
    fi
}

# Sprint task health
check_sprint_stalls() {
    local active_dir="$VAULT_DIR/Meta/sprint/active"
    [ -d "$active_dir" ] || return

    for f in "$active_dir"/*.md; do
        [ -f "$f" ] || continue
        local name
        name=$(grep -m1 '^name:' "$f" | sed 's/name:[[:space:]]*//' | tr -d '"' || basename "$f" .md)
        local assignee
        assignee=$(grep -m1 '^assignee:' "$f" | sed 's/assignee:[[:space:]]*//' || echo "?")
        local status
        status=$(grep -m1 '^status:' "$f" | sed 's/status:[[:space:]]*//' || echo "?")

        local mtime
        mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
        local age=$(( NOW - mtime ))
        local stale_seconds=$((72 * 3600))

        if [ "$age" -gt "$stale_seconds" ]; then
            local days_ago=$(( age / 86400 ))
            echo "🟡 STALLED: ${name} (${assignee}) — no movement in ${days_ago}d"
        else
            echo "✅ ACTIVE: ${name} (${assignee}) — ${status}"
        fi
    done
}

# Voice pipeline health
check_voice_pipeline() {
    local drop_dir="$VAULT_DIR/Inbox/Voice/_drop"
    local stuck=0
    if [ -d "$drop_dir" ]; then
        stuck=$(find "$drop_dir" \( -name "*.ogg" -o -name "*.oga" -o -name "*.m4a" -o -name "*.mp3" \) 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ "$stuck" -gt 0 ]; then
        echo "❌ Voice pipeline: ${stuck} file(s) stuck in _drop"
    else
        echo "✅ Voice pipeline: clear"
    fi

    # Check for failed extraction notes
    local failed=0
    failed=$(grep -rl '^status: failed' "$VAULT_DIR/Inbox/Voice/" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$failed" -gt 0 ]; then
        echo "❌ Extraction: ${failed} failed note(s) in Inbox/Voice/"
    fi
}

# Implementer health (new — was it ever run?)
check_implementer() {
    local log="$VAULT_DIR/Meta/AI-Reflections/implementer-log.md"
    if [ ! -f "$log" ]; then
        echo "❌ Implementer: log file missing — never ran"
        return
    fi
    local entries
    entries=$(grep -c '^## Implementer Run:' "$log" 2>/dev/null || true)
    entries=$(printf '%s\n' "$entries" | tail -n 1 | tr -dc '0-9')
    [ -z "$entries" ] && entries=0
    if [ "$entries" -eq 0 ]; then
        echo "❌ Implementer: log exists but has 0 entries — never successfully ran"
    else
        local mtime
        mtime=$(stat -f %m "$log" 2>/dev/null || stat -c %Y "$log" 2>/dev/null || echo 0)
        local age=$(( NOW - mtime ))
        local hours_ago=$(( age / 3600 ))
        echo "✅ Implementer: ${entries} runs, last ${hours_ago}h ago"
    fi
}

# Stale lock detection
check_stale_locks() {
    local lock_root="$VAULT_DIR/.agent-locks"
    [ -d "$lock_root" ] || return
    local max_age=900  # 15 minutes

    for lock_dir in "$lock_root"/*.lock; do
        [ -d "$lock_dir" ] || continue
        local lock_name
        lock_name=$(basename "$lock_dir" .lock)

        local is_stale=0
        local reason=""

        # Check PID
        if [ -f "$lock_dir/pid" ]; then
            local pid
            pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                is_stale=1
                reason="PID $pid is dead"
            fi
        else
            is_stale=1
            reason="no PID file"
        fi

        # Check age
        if [ "$is_stale" -eq 0 ] && [ -f "$lock_dir/started_at" ]; then
            local mtime
            mtime=$(stat -f %m "$lock_dir/started_at" 2>/dev/null || stat -c %Y "$lock_dir/started_at" 2>/dev/null || echo 0)
            local age=$(( NOW - mtime ))
            if [ "$age" -gt "$max_age" ]; then
                local mins=$(( age / 60 ))
                is_stale=1
                reason="${mins}m old"
            fi
        fi

        if [ "$is_stale" -eq 1 ]; then
            echo "🔒 STALE LOCK: ${lock_name} ($reason) — auto-clearing"
            rm -f "$lock_dir/pid" "$lock_dir/started_at"
            rmdir "$lock_dir" 2>/dev/null || true
        fi
    done
}

echo "=== Agent Heartbeat ==="
# Agent checks: name, max_hours, evidence_path
check_agent "Extractor"      48   "Meta/AI-Reflections/review-log.md"
check_agent "Retrospective"  26   "Meta/AI-Reflections/retro-log.md"
check_agent "Briefing"       26   "Inbox"
check_agent "Thinker"       170   "Meta/AI-Reflections"
check_heartbeat_file "Advisor"        48  "advisor"
check_heartbeat_file "Task-Enricher"  48  "task-enricher"
check_heartbeat_file "Mirror"        170  "mirror"
check_implementer

echo ""
echo "=== Sprint Tasks ==="
check_sprint_stalls

echo ""
echo "=== Locks ==="
check_stale_locks

echo ""
echo "=== Voice Pipeline ==="
check_voice_pipeline
