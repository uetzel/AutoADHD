#!/bin/bash
# run-task-enricher.sh
# Task enrichment agent — makes open actions actionable
#
# Modes:
#   --morning    Pure shell. Score open actions, send top 3 to Telegram.
#   --scan       AI-powered. Walk open actions, call Codex to write ## Enrichment sections.
#   --nudge      Pure shell. Find stale actions (open > 7 days), send nudges.
#
# Usage: ./run-task-enricher.sh --morning
#        ./run-task-enricher.sh --scan
#        ./run-task-enricher.sh --nudge

set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATE_TODAY=$(date +%Y-%m-%d)
ACTIONS_DIR="$VAULT_DIR/Canon/Actions"
CONFIG_FILE="${AGENT_RUNTIME_CONFIG:-$VAULT_DIR/Meta/agent-runtimes.conf}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Heartbeat: record successful run
write_heartbeat() {
    mkdir -p "$HOME/.vault/heartbeats"
    date +%s > "$HOME/.vault/heartbeats/task-enricher"
}

notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ Task-Enricher Failed
$1" 2>/dev/null || true
}

MODE="${1:---morning}"

# ============================================================
# --morning: Score open actions, surface top 3 via Telegram
# ============================================================
morning_mode() {
    echo "[$TIMESTAMP] Task-Enricher --morning"

    local actions=()
    local scores=()
    local next_steps=()
    local count=0

    for action_file in "$ACTIONS_DIR"/*.md; do
        [ -f "$action_file" ] || continue

        # Parse frontmatter fields
        local status="" priority="" due="" first_mentioned="" name="" mentions_count=0
        local enrichment_status="" next_step="" output=""

        status=$(grep -m1 '^status:' "$action_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
        [ "$status" = "open" ] || continue

        name=$(grep -m1 '^name:' "$action_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
        priority=$(grep -m1 '^priority:' "$action_file" | sed 's/^priority:[[:space:]]*//' | tr -d '"' || true)
        due=$(grep -m1 '^due:' "$action_file" | sed 's/^due:[[:space:]]*//' | tr -d '"' || true)
        first_mentioned=$(grep -m1 '^first_mentioned:' "$action_file" | sed 's/^first_mentioned:[[:space:]]*//' | tr -d '"' || true)
        output=$(grep -m1 '^output:' "$action_file" | sed 's/^output:[[:space:]]*//' | tr -d '"' || true)
        enrichment_status=$(grep -m1 '^enrichment_status:' "$action_file" | sed 's/^enrichment_status:[[:space:]]*//' | tr -d '"' || true)
        next_step=$(grep -m1 '^\*\*Next step\*\*:' "$action_file" | sed 's/^\*\*Next step\*\*:[[:space:]]*//' || true)
        mentions_count=$(grep -c '^[[:space:]]*-.*"20[0-9][0-9]-' "$action_file" 2>/dev/null || echo "0")

        # Score per spec: due urgency + mentions + staleness + priority + unenriched boost
        local score=0

        # Due date urgency
        if [ -n "$due" ] && [ "$due" != "(null)" ]; then
            local due_epoch today_epoch days_until
            due_epoch=$(date -j -f "%Y-%m-%d" "$due" +%s 2>/dev/null || echo "0")
            today_epoch=$(date +%s)
            if [ "$due_epoch" -gt 0 ]; then
                days_until=$(( (due_epoch - today_epoch) / 86400 ))
                if [ "$days_until" -lt 0 ]; then
                    score=$((score + 60))  # overdue
                elif [ "$days_until" -lt 3 ]; then
                    score=$((score + 50))
                fi
            fi
        fi

        # Mention frequency
        score=$((score + mentions_count * 10))

        # Staleness
        if [ -n "$first_mentioned" ] && [ "$first_mentioned" != "(null)" ]; then
            local fm_epoch days_old
            fm_epoch=$(date -j -f "%Y-%m-%d" "$first_mentioned" +%s 2>/dev/null || echo "0")
            if [ "$fm_epoch" -gt 0 ]; then
                days_old=$(( ($(date +%s) - fm_epoch) / 86400 ))
                if [ "$days_old" -gt 7 ]; then
                    score=$((score + 20))
                fi
            fi
        fi

        # Priority
        case "$priority" in
            high) score=$((score + 30)) ;;
            medium) score=$((score + 15)) ;;
        esac

        # Unenriched boost
        if [ -z "$enrichment_status" ] || [ "$enrichment_status" = "needs-enrichment" ]; then
            score=$((score + 25))
        fi

        # Determine display next step
        local display_step="$next_step"
        if [ -z "$display_step" ]; then
            # Truncate output as fallback next step
            display_step=$(echo "$output" | head -c 60)
        fi

        actions+=("$name")
        scores+=("$score")
        next_steps+=("$display_step")
        count=$((count + 1))
    done

    if [ "$count" -eq 0 ]; then
        "$SCRIPT_DIR/send-telegram.sh" "🎯 All clear! No open actions today." 2>/dev/null || true
        write_heartbeat
        return
    fi

    # Sort by score (descending), take top 3
    # Build sortable lines: score|index
    local sorted_indices
    sorted_indices=$(
        for i in $(seq 0 $((count - 1))); do
            echo "${scores[$i]}|$i"
        done | sort -t'|' -k1 -rn | head -3
    )

    # Build Telegram message per design spec
    local msg="🎯 Morning Check-in"$'\n'$'\n'
    local rank=1
    local open_count="$count"
    local stale_count=0

    # Count stale
    for action_file in "$ACTIONS_DIR"/*.md; do
        [ -f "$action_file" ] || continue
        local s fm
        s=$(grep -m1 '^status:' "$action_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
        [ "$s" = "open" ] || continue
        fm=$(grep -m1 '^first_mentioned:' "$action_file" | sed 's/^first_mentioned:[[:space:]]*//' | tr -d '"' || true)
        if [ -n "$fm" ]; then
            local fme days
            fme=$(date -j -f "%Y-%m-%d" "$fm" +%s 2>/dev/null || echo "0")
            [ "$fme" -gt 0 ] && days=$(( ($(date +%s) - fme) / 86400 )) && [ "$days" -gt 7 ] && stale_count=$((stale_count + 1))
        fi
    done

    while IFS='|' read -r _ idx; do
        local action_name="${actions[$idx]}"
        local step="${next_steps[$idx]}"
        # Truncate to design spec limits
        action_name=$(echo "$action_name" | head -c 40)
        step=$(echo "$step" | head -c 60)

        # Use real commands only: /email or /approve
        local cmd=""
        # Check if there's a linked person with email for /email command
        local action_basename
        action_basename=$(echo "${actions[$idx]}" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
        cmd="/email ${actions[$idx]}"

        msg+="${rank}. ${action_name}"
        [ -n "$step" ] && msg+=" — ${step}"
        msg+=$'\n'
        msg+="   → ${cmd}"$'\n'
        rank=$((rank + 1))
    done <<< "$sorted_indices"

    msg+=$'\n'"${open_count} open actions | ${stale_count} stale"

    "$SCRIPT_DIR/send-telegram.sh" "$msg" 2>/dev/null || true
    echo "[$TIMESTAMP] Morning check-in sent (${open_count} open, top 3 surfaced)"

    "$SCRIPT_DIR/log-agent-feedback.sh" \
        "TaskEnricher" \
        "morning_checkin" \
        "Morning check-in: ${open_count} open actions, top 3 surfaced" \
        "" \
        "" \
        "false" 2>/dev/null || true

    write_heartbeat

    # After the morning check-in, trigger AI-powered enrichment scan
    # so the daily 8:30 AM launchd run does real work.
    echo "[$TIMESTAMP] Morning mode: chaining into --scan for AI enrichment..."
    scan_mode || echo "[$TIMESTAMP] Scan failed (non-fatal, morning check-in already sent)"
}

# ============================================================
# --scan: AI-powered enrichment of open actions
# ============================================================
scan_mode() {
    echo "[$TIMESTAMP] Task-Enricher --scan"

    agent_require_commands git
    agent_assert_clean_worktree "Task-Enricher"
    agent_acquire_lock "vault-agent-pipeline"
    HEAD_BEFORE_RUN=$(git rev-parse HEAD)

    # Pre-scan: auto-flag "Research *" actions as needs-research
    # These are inherently research tasks and should be routed to the
    # Researcher agent, not enriched by the Task-Enricher.
    local auto_flagged
    auto_flagged=$(python3 - "$ACTIONS_DIR" <<'AUTOFLAG'
import sys, os, re

actions_dir = sys.argv[1]
flagged = 0
for fname in sorted(os.listdir(actions_dir)):
    if not fname.startswith("Research") or not fname.endswith(".md"):
        continue
    path = os.path.join(actions_dir, fname)
    with open(path, "r") as f:
        content = f.read()
    # Must be open and have no enrichment_status
    if not re.search(r'^status:[[:space:]]*open', content, re.MULTILINE):
        continue
    if re.search(r'^enrichment_status:', content, re.MULTILINE):
        continue
    # Insert enrichment_status before the closing --- of frontmatter
    if content.startswith("---"):
        # Find the second ---
        second = content.index("---", 3)
        content = content[:second] + "enrichment_status: needs-research\n" + content[second:]
        with open(path, "w") as f:
            f.write(content)
        flagged += 1
        print(f"  Auto-flagged for research: {fname}", file=sys.stderr)
print(flagged)
AUTOFLAG
    )

    if [ "$auto_flagged" -gt 0 ]; then
        echo "  Auto-flagged $auto_flagged Research action(s) for researcher"
        agent_stage_and_commit "[Task-Enricher] auto-flag: ${auto_flagged} Research actions for researcher [$TIMESTAMP]" \
            "$ACTIONS_DIR/"
    fi

    local processed=0

    for action_file in "$ACTIONS_DIR"/*.md; do
        [ -f "$action_file" ] || continue

        local status enrichment_status
        status=$(grep -m1 '^status:' "$action_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' | tr -d ' ' || true)
        [ "$status" = "open" ] || continue

        enrichment_status=$(grep -m1 '^enrichment_status:' "$action_file" | sed 's/^enrichment_status:[[:space:]]*//' | tr -d '"' | tr -d ' ' || true)
        # Skip already enriched, researched, or flagged for research
        [ "$enrichment_status" = "enriched" ] && continue
        [ "$enrichment_status" = "researched" ] && continue
        [ "$enrichment_status" = "snoozed" ] && continue
        [ "$enrichment_status" = "needs-research" ] && continue

        # Check if already has ## Enrichment section
        grep -q '^## Enrichment' "$action_file" && continue

        echo "  Enriching: $(basename "$action_file")"

        local action_content
        action_content=$(cat "$action_file")
        local action_basename
        action_basename=$(basename "$action_file")

        PROMPT="You are the TASK ENRICHER agent for this Obsidian vault.

## Your Job
Read the action below and add an ## Enrichment section to make it immediately actionable.

## Rules
1. Read Meta/Agents/Task-Enricher.md for your full spec
2. Read Meta/style-guide.md for Usman's voice
3. Look up linked people in Canon/People/ for real contact info (phone, email)
4. Do NOT invent phone numbers or facts
5. Write ONE concrete next step (under 10 words)
6. If the action needs research you can't do, set enrichment_status: needs-research in frontmatter
7. Add the ## Enrichment section at the end of the file
8. Update frontmatter: enrichment_status: enriched, enriched_date: $DATE_TODAY

## The Action
File: $action_basename
$action_content

## Output
Edit the action file directly. Add ## Enrichment section. Update frontmatter fields.
Do NOT create or edit any other files."

        if ! /bin/bash "$SCRIPT_DIR/invoke-agent.sh" task-enricher "$PROMPT" 2>/dev/null; then
            echo "  WARN: Enrichment failed for $(basename "$action_file")"
            notify_failure "Enrichment failed for $(basename "$action_file")"
            continue
        fi

        # Validate: check that ## Enrichment was actually written
        if ! grep -q '^## Enrichment' "$action_file"; then
            echo "  WARN: No ## Enrichment section produced for $(basename "$action_file")"
            continue
        fi

        processed=$((processed + 1))

        # Commit after each enrichment
        agent_stage_and_commit "[Task-Enricher] enrich: $(basename "$action_file" .md) [$TIMESTAMP]" \
            "$action_file"

        # Cap at 3 per run to avoid token burn
        [ "$processed" -ge 3 ] && break
    done

    echo "[$TIMESTAMP] Scan complete: $processed action(s) enriched"
    "$SCRIPT_DIR/send-telegram.sh" "🎯✅ Enricher done: $processed action(s) enriched" 2>/dev/null || true

    "$SCRIPT_DIR/log-agent-feedback.sh" \
        "TaskEnricher" \
        "enrichment_complete" \
        "Scan complete: $processed action(s) enriched" \
        "" \
        "" \
        "false" 2>/dev/null || true

    write_heartbeat
}

# ============================================================
# --nudge: Find stale actions, send nudges
# ============================================================
nudge_mode() {
    echo "[$TIMESTAMP] Task-Enricher --nudge"

    local nudges=0

    for action_file in "$ACTIONS_DIR"/*.md; do
        [ -f "$action_file" ] || continue

        local status first_mentioned name
        status=$(grep -m1 '^status:' "$action_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
        [ "$status" = "open" ] || continue

        name=$(grep -m1 '^name:' "$action_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
        first_mentioned=$(grep -m1 '^first_mentioned:' "$action_file" | sed 's/^first_mentioned:[[:space:]]*//' | tr -d '"' || true)

        [ -n "$first_mentioned" ] || continue

        local fm_epoch days_old
        fm_epoch=$(date -j -f "%Y-%m-%d" "$first_mentioned" +%s 2>/dev/null || echo "0")
        [ "$fm_epoch" -gt 0 ] || continue

        days_old=$(( ($(date +%s) - fm_epoch) / 86400 ))
        [ "$days_old" -gt 7 ] || continue

        local mentions_count
        mentions_count=$(grep -c '^[[:space:]]*-.*"20[0-9][0-9]-' "$action_file" 2>/dev/null || echo "0")

        "$SCRIPT_DIR/send-telegram.sh" "⚠️ Stale: ${name}
First mentioned: ${first_mentioned} (${days_old} days ago)
Mentioned ${mentions_count} times.

/email ${name} | /approve" 2>/dev/null || true

        nudges=$((nudges + 1))
    done

    echo "[$TIMESTAMP] Nudge complete: $nudges stale action(s) flagged"
    write_heartbeat
}

# ============================================================
# --decompose: Break an action into typed sub-steps (separate files)
# ============================================================
decompose_mode() {
    local action_file="${2:-}"
    if [ -z "$action_file" ]; then
        echo "Usage: $0 --decompose <action-file-path>" >&2
        exit 1
    fi

    # Resolve relative paths
    if [[ "$action_file" != /* ]]; then
        action_file="$VAULT_DIR/$action_file"
    fi

    if [ ! -f "$action_file" ]; then
        echo "Action file not found: $action_file" >&2
        exit 1
    fi

    echo "[$TIMESTAMP] Task-Enricher --decompose: $(basename "$action_file")"

    agent_require_commands git python3
    agent_assert_clean_worktree "Task-Enricher"
    agent_acquire_lock "vault-agent-pipeline"
    HEAD_BEFORE_RUN=$(agent_git rev-parse HEAD)

    local action_content action_name action_output
    action_content=$(cat "$action_file")
    action_name=$(grep -m1 '^name:' "$action_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
    action_output=$(grep -m1 '^output:' "$action_file" | sed 's/^output:[[:space:]]*//' | tr -d '"' || true)

    # Resolve wikilinks (1-hop) for context
    local linked_context=""
    local link
    while IFS= read -r link; do
        [ -n "$link" ] || continue
        # Search Canon for matching files
        local found_file
        found_file=$(find "$VAULT_DIR/Canon/" -name "${link}.md" -type f 2>/dev/null | head -1)
        if [ -n "$found_file" ]; then
            linked_context+="=== $(basename "$found_file") ==="$'\n'
            head -40 "$found_file"
            linked_context+=$'\n'
        fi
    done < <(grep -oP '\[\[([^\]|]+)' "$action_file" | sed 's/\[\[//' | sort -u)

    # Load vault context
    local beliefs_context=""
    if [ -d "$VAULT_DIR/Canon/Beliefs" ]; then
        beliefs_context=$(find "$VAULT_DIR/Canon/Beliefs/" -name "*.md" -type f 2>/dev/null | while read f; do cat "$f"; echo; done)
    fi

    local decisions_summary=""
    [ -f "$VAULT_DIR/Meta/decisions-summary.md" ] && decisions_summary=$(cat "$VAULT_DIR/Meta/decisions-summary.md")

    local style_guide=""
    [ -f "$VAULT_DIR/Meta/style-guide.md" ] && style_guide=$(cat "$VAULT_DIR/Meta/style-guide.md")

    # Load agent spec
    local agent_spec=""
    [ -f "$VAULT_DIR/Meta/Agents/Task-Enricher.md" ] && agent_spec=$(cat "$VAULT_DIR/Meta/Agents/Task-Enricher.md")

    PROMPT="You are the TASK ENRICHER agent running in DECOMPOSE mode.

Read CLAUDE.md for vault rules. Read .claude/skills/vault-writer/SKILL.md for note format.

## YOUR SPEC
$agent_spec

## DESIGN PRINCIPLES FOR DECOMPOSITION
1. Adaptive: Create a target state and current best plan. The plan WILL change when new info arrives.
2. Never block on nice-to-haves: If a step is nice but not required, set blocking: false.
3. One question at a time: Input steps ask ONE thing.
4. Minimum viable path: Fewest steps to reach the target state.

## THE ACTION TO DECOMPOSE
File: $(basename "$action_file")
$action_content

## LINKED CONTEXT (1-hop wikilinks)
$linked_context

## BELIEFS
$beliefs_context

## DECISIONS SUMMARY
$decisions_summary

## STYLE GUIDE
$style_guide

## YOUR JOB
1. Analyze the action and its target state (output field: '$action_output')
2. Create the minimum viable set of sub-steps to reach the target state
3. For each sub-step, create a NEW file in Canon/Actions/ with this frontmatter:

\`\`\`yaml
---
type: action
name: \"[short descriptive name]\"
status: open
created: $DATE_TODAY
parent_action: \"[[$action_name]]\"
sequence: [1, 2, 3... or null for non-blocking]
execution_type: [automated | approval | input | manual]
blocking: [true | false]
depends_on:
  - \"[[step name]]\"
agent_hint: [enricher | researcher | calendar | advisor | none]
input_question: \"[only for type: input — one clear question]\"
target_state: \"$action_output\"
source: ai-generated
---

# [Step Name]

[1-2 sentence description of what this step accomplishes]
\`\`\`

4. Update the PARENT action frontmatter: add decomposed: true, sub_steps_total: N
5. Cap at 10 sub-steps maximum
6. Classify each step:
   - automated: AI can do this (research, draft, gather context)
   - approval: needs human approval (calendar invite, email send)
   - input: needs human input (\"when works for the call?\")
   - manual: human must do physically (\"attend the meeting\")
7. Non-blocking steps (blocking: false) are nice-to-haves that don't gate the parent
8. Git commit all new files: '[Task-Enricher] decompose: $action_name [$TIMESTAMP]'
9. Do NOT edit any existing files except the parent action's frontmatter"

    if ! /bin/bash "$SCRIPT_DIR/invoke-agent.sh" TASK_ENRICHER "$PROMPT"; then
        notify_failure "Decomposition failed for $(basename "$action_file")"
        exit 1
    fi

    # Validate: check that sub-action files were created
    local sub_count
    sub_count=$(grep -rl "parent_action.*$action_name" "$ACTIONS_DIR/" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$sub_count" -eq 0 ]; then
        echo "  WARN: No sub-action files created for $action_name"
        notify_failure "Decomposition produced no sub-actions for $action_name"
        exit 1
    fi

    # Validate: check each sub-action file has required frontmatter
    local valid=0
    for sub_file in $(grep -rl "parent_action.*$action_name" "$ACTIONS_DIR/" 2>/dev/null); do
        local lines
        lines=$(wc -l < "$sub_file" | tr -d ' ')
        if [ "$lines" -lt 5 ]; then
            echo "  WARN: Sub-action too short: $(basename "$sub_file") ($lines lines)"
            rm -f "$sub_file"
            continue
        fi
        if ! grep -q '^execution_type:' "$sub_file"; then
            echo "  WARN: Missing execution_type in $(basename "$sub_file")"
        fi
        valid=$((valid + 1))
    done

    # Cycle detection in depends_on
    python3 - "$ACTIONS_DIR" "$action_name" <<'PYEOF'
import sys, os, re, pathlib

actions_dir = pathlib.Path(sys.argv[1])
parent_name = sys.argv[2]

# Build dependency graph
graph = {}
for path in actions_dir.glob("*.md"):
    text = path.read_text(encoding="utf-8")
    pa = re.search(r'^parent_action:.*' + re.escape(parent_name), text, re.MULTILINE)
    if not pa:
        continue
    name_m = re.search(r'^name:[[:space:]]*"?(.+?)"?[[:space:]]*$', text, re.MULTILINE)
    if not name_m:
        continue
    name = name_m.group(1).strip()
    deps = re.findall(r'^[[:space:]]*-[[:space:]]*"\[\[(.+?)\]\]"', text, re.MULTILINE)
    graph[name] = deps

# DFS cycle detection
def has_cycle(node, visited, stack):
    visited.add(node)
    stack.add(node)
    for dep in graph.get(node, []):
        if dep in stack:
            print(f"CYCLE DETECTED: {node} -> {dep}", file=sys.stderr)
            sys.exit(1)
        if dep not in visited:
            if has_cycle(dep, visited, stack):
                return True
    stack.remove(node)
    return False

visited, stack = set(), set()
for node in graph:
    if node not in visited:
        has_cycle(node, visited, stack)

print(f"No cycles found in {len(graph)} sub-actions")
PYEOF

    if [ $? -ne 0 ]; then
        notify_failure "Cycle detected in decomposition for $action_name"
        "$SCRIPT_DIR/send-telegram.sh" "⚠️ Decomposition cycle detected in $action_name. Aborting." 2>/dev/null || true
        exit 1
    fi

    # Fallback commit
    agent_stage_and_commit "[Task-Enricher] decompose: $action_name [$TIMESTAMP]" \
        "$action_file" \
        "$ACTIONS_DIR/"

    # Telegram notification with decomposition summary
    local summary="📋 Decomposed: $action_name\n🎯 Target: $action_output\n\nSteps:"
    local seq=1
    for sub_file in $(grep -rl "parent_action.*$action_name" "$ACTIONS_DIR/" 2>/dev/null | sort); do
        local sname stype sblocking
        sname=$(grep -m1 '^name:' "$sub_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
        stype=$(grep -m1 '^execution_type:' "$sub_file" | sed 's/^execution_type:[[:space:]]*//' | tr -d '"' || true)
        sblocking=$(grep -m1 '^blocking:' "$sub_file" | sed 's/^blocking:[[:space:]]*//' | tr -d '"' || true)

        local icon="⬜"
        case "$stype" in
            automated) icon="⚡" ;;
            approval) icon="📅" ;;
            input) icon="⏳" ;;
            manual) icon="👤" ;;
        esac

        if [ "$sblocking" = "false" ]; then
            summary+="\n💡 Optional: $sname"
        else
            summary+="\n${seq}. ${icon} $sname"
            seq=$((seq + 1))
        fi
    done
    summary+="\n\nStarting automated steps now."

    "$SCRIPT_DIR/send-telegram.sh" "$(echo -e "$summary")" 2>/dev/null || true

    echo "[$TIMESTAMP] Decomposition complete: $valid sub-actions for $action_name"
    write_heartbeat
}

# ============================================================
# --execute: Walk the DAG, execute next eligible sub-actions
# ============================================================
execute_mode() {
    echo "[$TIMESTAMP] Task-Enricher --execute"

    local executed=0
    local max_per_run=3
    local input_sent=0

    # Find all sub-actions (files with parent_action in frontmatter)
    local sub_files=()
    for f in "$ACTIONS_DIR"/*.md; do
        [ -f "$f" ] || continue
        grep -q '^parent_action:' "$f" && sub_files+=("$f")
    done

    if [ ${#sub_files[@]} -eq 0 ]; then
        echo "  No sub-actions found"
        return
    fi

    # Group by parent and find next eligible
    for sub_file in "${sub_files[@]}"; do
        local status exec_type parent_name sname blocking
        status=$(grep -m1 '^status:' "$sub_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
        [ "$status" = "open" ] || continue

        exec_type=$(grep -m1 '^execution_type:' "$sub_file" | sed 's/^execution_type:[[:space:]]*//' | tr -d '"' || true)
        parent_name=$(grep -m1 '^parent_action:' "$sub_file" | sed 's/^parent_action:[[:space:]]*//' | tr -d '"' | sed 's/\[\[//;s/\]\]//' || true)
        sname=$(grep -m1 '^name:' "$sub_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
        blocking=$(grep -m1 '^blocking:' "$sub_file" | sed 's/^blocking:[[:space:]]*//' | tr -d '"' || true)

        # Check if all dependencies are done
        local deps_met=true
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            dep=$(echo "$dep" | sed 's/.*\[\[//;s/\]\].*//' | tr -d '"' | xargs)
            [ -n "$dep" ] || continue
            # Find the dep file and check its status
            local dep_file
            dep_file=$(grep -rl "^name:.*$dep" "$ACTIONS_DIR/" 2>/dev/null | head -1)
            if [ -n "$dep_file" ]; then
                local dep_status
                dep_status=$(grep -m1 '^status:' "$dep_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
                if [ "$dep_status" != "done" ]; then
                    deps_met=false
                    break
                fi
            fi
        done < <(grep '^[[:space:]]*-.*\[\[' "$sub_file" | grep -v '^depends_on:' || true)

        [ "$deps_met" = "true" ] || continue

        # Execute based on type
        case "$exec_type" in
            automated)
                [ "$executed" -ge "$max_per_run" ] && continue

                echo "  Executing automated step: $sname"
                local agent_hint
                agent_hint=$(grep -m1 '^agent_hint:' "$sub_file" | sed 's/^agent_hint:[[:space:]]*//' | tr -d '"' || true)

                local step_content
                step_content=$(cat "$sub_file")
                local parent_file
                parent_file=$(find "$ACTIONS_DIR/" -name "*.md" -exec grep -l "^name:.*$parent_name" {} \; 2>/dev/null | head -1)
                local parent_context=""
                [ -n "$parent_file" ] && parent_context=$(cat "$parent_file")

                local step_prompt="You are executing a sub-step of the action '$parent_name'.

## Sub-Step to Execute
$step_content

## Parent Action Context
$parent_context

## Your Job
1. Complete this sub-step
2. Write results to the sub-step file (add ## Results section)
3. Update frontmatter: status: done
4. Do NOT edit any other files"

                # 5-minute timeout per step
                if timeout 300 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" task-enricher "$step_prompt" 2>/dev/null; then
                    # Verify step was marked done
                    local new_status
                    new_status=$(grep -m1 '^status:' "$sub_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
                    if [ "$new_status" != "done" ]; then
                        # Force mark done if agent forgot
                        agent_note_set_status "$sub_file" "done"
                    fi
                    agent_stage_and_commit "[Task-Enricher] execute: $sname [$TIMESTAMP]" "$sub_file"
                    executed=$((executed + 1))

                    "$SCRIPT_DIR/send-telegram.sh" "✅ Step done: $sname ($parent_name)" 2>/dev/null || true
                else
                    echo "  WARN: Step failed or timed out: $sname"
                    agent_note_set_status "$sub_file" "failed"
                    agent_stage_and_commit "[Task-Enricher] failed: $sname [$TIMESTAMP]" "$sub_file"
                    "$SCRIPT_DIR/send-telegram.sh" "❌ Step failed: $sname ($parent_name). Skipping to next." 2>/dev/null || true
                fi
                ;;

            input)
                # Only send one input question at a time (per ADHD design)
                [ "$input_sent" -gt 0 ] && continue

                local question
                question=$(grep -m1 '^input_question:' "$sub_file" | sed 's/^input_question:[[:space:]]*//' | tr -d '"' || true)

                # Check if answer already exists
                local slug
                slug=$(basename "$sub_file" .md | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
                if [ -f "$VAULT_DIR/Meta/decomposer/answers/${slug}.md" ]; then
                    # Answer exists, mark step done
                    local answer
                    answer=$(cat "$VAULT_DIR/Meta/decomposer/answers/${slug}.md")
                    echo "  Input answered: $sname"
                    agent_note_set_status "$sub_file" "done"
                    agent_stage_and_commit "[Task-Enricher] input-answered: $sname [$TIMESTAMP]" "$sub_file"
                    continue
                fi

                # Check for stuck input (nudge after 3 days, skip after 7)
                local pending_file="$VAULT_DIR/Meta/decomposer/pending-input/${slug}.md"
                if [ -f "$pending_file" ]; then
                    local created_epoch days_pending
                    created_epoch=$(stat -f %m "$pending_file" 2>/dev/null || stat -c %Y "$pending_file" 2>/dev/null || echo "0")
                    days_pending=$(( ($(date +%s) - created_epoch) / 86400 ))
                    if [ "$days_pending" -ge 7 ]; then
                        echo "  Skipping stuck input (${days_pending} days): $sname"
                        agent_note_set_status "$sub_file" "skipped"
                        agent_stage_and_commit "[Task-Enricher] skip-stale-input: $sname [$TIMESTAMP]" "$sub_file"
                        "$SCRIPT_DIR/send-telegram.sh" "⏭️ Skipped: $sname (no answer for ${days_pending} days). I'll work around it." 2>/dev/null || true
                        continue
                    elif [ "$days_pending" -ge 3 ]; then
                        # Re-nudge
                        "$SCRIPT_DIR/send-telegram.sh" "⏳ Still waiting on: $parent_name

$question

(reply here, or say \"skip\" to move on)" 2>/dev/null || true
                        input_sent=1
                        continue
                    fi
                    # Already pending, don't re-send
                    continue
                fi

                # Send input question
                mkdir -p "$VAULT_DIR/Meta/decomposer/pending-input"
                echo "parent: $parent_name" > "$pending_file"
                echo "step: $sname" >> "$pending_file"
                echo "question: $question" >> "$pending_file"
                echo "created: $DATE_TODAY" >> "$pending_file"

                "$SCRIPT_DIR/send-telegram.sh" "⏳ $parent_name needs your input:

$question

(reply here, or say \"skip\")" 2>/dev/null || true
                input_sent=1
                ;;

            approval)
                # Create operation file for approval
                local agent_hint_val
                agent_hint_val=$(grep -m1 '^agent_hint:' "$sub_file" | sed 's/^agent_hint:[[:space:]]*//' | tr -d '"' || true)
                if [ "$agent_hint_val" = "calendar" ]; then
                    # Use create-calendar-op.sh if it exists
                    if [ -x "$SCRIPT_DIR/create-calendar-op.sh" ]; then
                        "$SCRIPT_DIR/create-calendar-op.sh" "$sname" "" "" "" "Sub-step of $parent_name" "$(basename "$sub_file")"
                    else
                        echo "  WARN: create-calendar-op.sh not found, creating generic op"
                    fi
                fi
                "$SCRIPT_DIR/send-telegram.sh" "📅 Approval needed: $sname ($parent_name)

Use /ops to see pending operations, /approve to approve." 2>/dev/null || true
                ;;

            manual)
                "$SCRIPT_DIR/send-telegram.sh" "👤 Manual step ready: $sname ($parent_name)

When you're done, say: done $sname" 2>/dev/null || true
                agent_note_set_status "$sub_file" "in-progress"
                agent_stage_and_commit "[Task-Enricher] manual-started: $sname [$TIMESTAMP]" "$sub_file"
                ;;
        esac
    done

    # Check if any parent actions are now complete (all blocking steps done)
    for f in "$ACTIONS_DIR"/*.md; do
        [ -f "$f" ] || continue
        grep -q '^decomposed: true' "$f" || continue
        local pname
        pname=$(grep -m1 '^name:' "$f" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)

        local total_blocking=0 done_blocking=0
        for sub in $(grep -rl "parent_action.*$pname" "$ACTIONS_DIR/" 2>/dev/null); do
            local sb ss
            sb=$(grep -m1 '^blocking:' "$sub" | sed 's/^blocking:[[:space:]]*//' | tr -d '"' || true)
            [ "$sb" = "false" ] && continue
            total_blocking=$((total_blocking + 1))
            ss=$(grep -m1 '^status:' "$sub" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
            [ "$ss" = "done" ] && done_blocking=$((done_blocking + 1))
        done

        if [ "$total_blocking" -gt 0 ] && [ "$done_blocking" -ge "$total_blocking" ]; then
            echo "  All blocking steps done for: $pname"
            agent_note_set_status "$f" "done"
            agent_stage_and_commit "[Task-Enricher] parent-complete: $pname [$TIMESTAMP]" "$f"
            "$SCRIPT_DIR/send-telegram.sh" "✅ Action complete: $pname (all ${total_blocking} steps done)" 2>/dev/null || true
        fi
    done

    echo "[$TIMESTAMP] Execute complete: $executed automated, $input_sent input(s) sent"
    write_heartbeat
}

# ============================================================
# --status: Show sub-action progress for a parent action
# ============================================================
status_mode() {
    local action_name="${2:-}"
    if [ -z "$action_name" ]; then
        echo "Usage: $0 --status <action-name>" >&2
        exit 1
    fi

    # Find parent action by name
    local parent_file=""
    for f in "$ACTIONS_DIR"/*.md; do
        [ -f "$f" ] || continue
        local n
        n=$(grep -m1 '^name:' "$f" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
        if echo "$n" | grep -qi "$action_name"; then
            parent_file="$f"
            break
        fi
    done

    if [ -z "$parent_file" ]; then
        echo "Action not found: $action_name"
        exit 1
    fi

    local pname
    pname=$(grep -m1 '^name:' "$parent_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
    local total=0 done_count=0

    local output="📊 $pname\n"

    for sub_file in $(grep -rl "parent_action.*$pname" "$ACTIONS_DIR/" 2>/dev/null | sort); do
        local sname sstatus stype sblocking
        sname=$(grep -m1 '^name:' "$sub_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)
        sstatus=$(grep -m1 '^status:' "$sub_file" | sed 's/^status:[[:space:]]*//' | tr -d '"' || true)
        stype=$(grep -m1 '^execution_type:' "$sub_file" | sed 's/^execution_type:[[:space:]]*//' | tr -d '"' || true)
        sblocking=$(grep -m1 '^blocking:' "$sub_file" | sed 's/^blocking:[[:space:]]*//' | tr -d '"' || true)

        local icon="⬜"
        case "$sstatus" in
            done) icon="✅" ;;
            open)
                case "$stype" in
                    automated) icon="⚡" ;;
                    input) icon="⏳" ;;
                    approval) icon="📅" ;;
                    manual) icon="👤" ;;
                esac
                ;;
            in-progress) icon="🔄" ;;
            failed) icon="❌" ;;
            skipped) icon="⏭️" ;;
        esac

        total=$((total + 1))
        [ "$sstatus" = "done" ] && done_count=$((done_count + 1))

        if [ "$sblocking" = "false" ]; then
            output+="💡 $icon $sname (optional)\n"
        else
            output+="$icon $sname\n"
        fi
    done

    output+="\n📊 ${done_count}/${total} steps done"
    echo -e "$output"
}

# ============================================================
# --redecompose: Re-assess plan with new information
# ============================================================
redecompose_mode() {
    local action_file="${2:-}"
    local new_context="${3:-}"

    if [ -z "$action_file" ]; then
        echo "Usage: $0 --redecompose <action-file-path> [new-context]" >&2
        exit 1
    fi

    if [[ "$action_file" != /* ]]; then
        action_file="$VAULT_DIR/$action_file"
    fi

    if [ ! -f "$action_file" ]; then
        echo "Action file not found: $action_file" >&2
        exit 1
    fi

    echo "[$TIMESTAMP] Task-Enricher --redecompose: $(basename "$action_file")"

    agent_require_commands git python3
    agent_assert_clean_worktree "Task-Enricher"
    agent_acquire_lock "vault-agent-pipeline"

    local action_name
    action_name=$(grep -m1 '^name:' "$action_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' || true)

    # Gather existing sub-actions
    local existing_steps=""
    for sub in $(grep -rl "parent_action.*$action_name" "$ACTIONS_DIR/" 2>/dev/null | sort); do
        existing_steps+="=== $(basename "$sub") ==="$'\n'
        cat "$sub"
        existing_steps+=$'\n'
    done

    # Gather any answers
    local answers=""
    for ans in "$VAULT_DIR/Meta/decomposer/answers/"*.md; do
        [ -f "$ans" ] || continue
        answers+="=== $(basename "$ans") ==="$'\n'
        cat "$ans"
        answers+=$'\n'
    done

    local action_content
    action_content=$(cat "$action_file")
    local action_output
    action_output=$(grep -m1 '^output:' "$action_file" | sed 's/^output:[[:space:]]*//' | tr -d '"' || true)

    PROMPT="You are the TASK ENRICHER agent running in RE-DECOMPOSE mode.

## CURRENT PLAN
$existing_steps

## NEW INFORMATION
$new_context

## ANSWERS RECEIVED
$answers

## PARENT ACTION
$action_content

## TARGET STATE (unchanged): $action_output

## YOUR JOB
1. Re-assess the current plan given the new information
2. For steps that are now OBSOLETE: set status: dropped, add dropped_reason in frontmatter
3. For NEW steps needed: create new files following the same sub-action format
4. Keep completed steps (status: done) as-is — never modify done steps
5. Update the parent's sub_steps_total if it changed
6. Git commit: '[Task-Enricher] redecompose: $action_name [$TIMESTAMP]'

Be specific about what changed and why."

    if ! /bin/bash "$SCRIPT_DIR/invoke-agent.sh" TASK_ENRICHER "$PROMPT"; then
        notify_failure "Re-decomposition failed for $action_name"
        exit 1
    fi

    agent_stage_and_commit "[Task-Enricher] redecompose: $action_name [$TIMESTAMP]" \
        "$action_file" \
        "$ACTIONS_DIR/"

    # Count changes for notification
    local dropped new_steps
    dropped=$(grep -rl "status: dropped" "$ACTIONS_DIR/" 2>/dev/null | while read f; do grep -l "parent_action.*$action_name" "$f" 2>/dev/null; done | wc -l | tr -d ' ')
    new_steps=$(grep -rl "parent_action.*$action_name" "$ACTIONS_DIR/" 2>/dev/null | wc -l | tr -d ' ')

    "$SCRIPT_DIR/send-telegram.sh" "🔄 Plan updated: $action_name
${dropped} step(s) dropped, now ${new_steps} total steps." 2>/dev/null || true

    echo "[$TIMESTAMP] Re-decomposition complete for $action_name"
    write_heartbeat
}

# ============================================================
# Main dispatch
# ============================================================
case "$MODE" in
    --morning)
        morning_mode
        ;;
    --scan)
        scan_mode
        ;;
    --nudge)
        nudge_mode
        ;;
    --decompose)
        decompose_mode "$@"
        ;;
    --execute)
        execute_mode
        ;;
    --status)
        status_mode "$@"
        ;;
    --redecompose)
        redecompose_mode "$@"
        ;;
    *)
        echo "Usage: $0 --morning | --scan | --nudge | --decompose <file> | --execute | --status <name> | --redecompose <file> [context]"
        exit 1
        ;;
esac

echo "[$TIMESTAMP] Task-Enricher ($MODE) complete."
