#!/bin/bash
# daily-briefing.sh
# The vault comes to YOU — as a daily newspaper.
#
# Three attention tiers:
#   🔴 Needs You — pending operations, review queue, sprint proposals
#   ✨ What's New — notes created in last 24h
#   🟢 Just Happened — no-brainers, completed tasks
#
# Then: open actions, stale actions, questions.
# Target: < 80 lines total (ADHD-scannable).
#
# Usage: ./daily-briefing.sh

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"

DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BRIEFING_PATH="$VAULT_DIR/Inbox/${DATE} - Daily Briefing.md"

echo "[$TIMESTAMP] Building daily briefing..."

HEALTH_STATUS="$("$SCRIPT_DIR/vault-health.sh" 2>&1 || true)"
HEARTBEAT="$("$SCRIPT_DIR/heartbeat-check.sh" 2>&1 || true)"

# Collect data with Python
VAULT_DIR="$VAULT_DIR" DATE="$DATE" DAY_NAME="$DAY_NAME" BRIEFING_PATH="$BRIEFING_PATH" HEALTH_STATUS="$HEALTH_STATUS" HEARTBEAT="$HEARTBEAT" python3 << 'PYEOF'
import os
import re
from datetime import datetime, timedelta

vault = os.environ.get("VAULT_DIR", ".")
date = os.environ.get("DATE", datetime.now().strftime("%Y-%m-%d"))
day_name = os.environ.get("DAY_NAME", "Today")
briefing_path = os.environ.get("BRIEFING_PATH", f"{vault}/Inbox/{date} - Daily Briefing.md")
health_status = os.environ.get("HEALTH_STATUS", "").strip()
heartbeat = os.environ.get("HEARTBEAT", "").strip()

EMOJI = {
    "person": "👤", "action": "🎯", "event": "📅", "reflection": "💭",
    "belief": "🪨", "research": "🔬", "decision": "⚖️", "ai-reflection": "🤖",
    "place": "📍", "organization": "🏢", "concept": "💡", "emerging": "🌱",
    "sprint-task": "🏗️", "sprint-proposal": "💡", "project": "📁",
}

def read_frontmatter(filepath):
    """Extract YAML frontmatter from a markdown file."""
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        if content.startswith('---'):
            end = content.index('---', 3)
            fm_text = content[3:end].strip()
            fm = {}
            for line in fm_text.split('\n'):
                if ':' in line and not line.strip().startswith('-'):
                    key, val = line.split(':', 1)
                    fm[key.strip()] = val.strip().strip('"').strip("'")
                elif line.strip().startswith('-') and fm:
                    last_key = list(fm.keys())[-1]
                    if isinstance(fm[last_key], str):
                        fm[last_key] = [fm[last_key]] if fm[last_key] else []
                    fm[last_key].append(line.strip().lstrip('- '))
            return fm
    except:
        pass
    return {}


def read_note(filepath):
    try:
        with open(filepath, 'r') as f:
            return f.read()
    except:
        return ""


def moyo_resolution_logged(vault_root):
    exit_call_path = os.path.join(vault_root, 'Canon', 'Events', '2026-03-31 - Moyo Co-Founder Exit Call.md')
    if os.path.exists(exit_call_path):
        return True

    decision_path = os.path.join(vault_root, 'Canon', 'Decisions', 'Solo Founder or Find New Co-Founder.md')
    if os.path.exists(decision_path):
        decision_text = read_note(decision_path)
        decision_fm = read_frontmatter(decision_path)
        if re.search(r'^##\s+Resolution\b', decision_text, re.MULTILINE):
            return True
        if decision_fm.get('status') in ('decided', 'done', 'resolved'):
            return True

    for action_rel in (
        os.path.join('Canon', 'Actions', '_done', 'Find New Co-Founder or Go Solo.md'),
        os.path.join('Canon', 'Actions', 'Find New Co-Founder or Go Solo.md'),
    ):
        action_path = os.path.join(vault_root, action_rel)
        if os.path.exists(action_path):
            action_fm = read_frontmatter(action_path)
            if action_fm.get('status') == 'done':
                return True

    return False


def summarize_system_lines(raw_status, limit=5):
    accepted = []
    discarded = 0

    for raw_line in raw_status.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith(("[OK]", "[FAIL]")):
            accepted.append(line)
        else:
            discarded += 1

    if discarded:
        accepted.append("Warning: one system check emitted raw command noise; see logs if it repeats.")

    return accepted[:limit]

cutoff_24h = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
cutoff_7d = (datetime.now() - timedelta(days=7)).strftime("%Y-%m-%d")

# --- TIER 1: 🔴 Needs You ---
pending_ops = []
ops_dir = os.path.join(vault, 'Meta', 'operations', 'pending')
if os.path.exists(ops_dir):
    for f in sorted(os.listdir(ops_dir)):
        if f.endswith('.md'):
            fm = read_frontmatter(os.path.join(ops_dir, f))
            subject = fm.get('subject', fm.get('name', f[:-3]))
            op_type = fm.get('type', '')
            icon = {"email": "📧", "calendar": "📅", "document": "📄"}.get(op_type, "🔧")
            op_id = fm.get('op_id', f.replace('.md', ''))
            pending_ops.append(f"{icon} {subject} → /approve {op_id}")

review_items = []
rq_dir = os.path.join(vault, 'Meta', 'review-queue')
if os.path.exists(rq_dir):
    for f in sorted(os.listdir(rq_dir)):
        if f.endswith('.md'):
            fm = read_frontmatter(os.path.join(rq_dir, f))
            status = fm.get('status', '')
            if status == 'pending' or not status:
                name = fm.get('name', f[:-3])
                review_items.append(f"📋 {name}")

proposals = []
prop_dir = os.path.join(vault, 'Meta', 'sprint', 'proposals')
if os.path.exists(prop_dir):
    for f in sorted(os.listdir(prop_dir)):
        if f.endswith('.md'):
            fm = read_frontmatter(os.path.join(prop_dir, f))
            if fm.get('status', 'proposed') == 'proposed':
                name = fm.get('name', f[:-3])
                by = fm.get('proposed_by', '?')
                created = fm.get('created', '')
                # Flag stale proposals (> 7 days)
                flag = " ⚠️ stale" if created and created < cutoff_7d else ""
                proposals.append(f"💡 {name} (from {by}){flag}")

standing_priority_lines = []
standing_priority_count = 0
moyo_event_path = os.path.join(vault, 'Canon', 'Events', '2026-03-24 - Moyo Startup Direction Meeting.md')
if os.path.exists(moyo_event_path):
    moyo_event = read_frontmatter(moyo_event_path)
    if moyo_event.get('status') == 'occurred-outcome-unknown' and not moyo_resolution_logged(vault):
        standing_priority_count = 1
        standing_priority_lines = [
            "🔴 STILL MISSING: What happened at the Moyo meeting on Monday?",
            'Drop a voice memo with one sentence: "Moyo said..." or "Moyo is in/out because..."',
            "The vault is blind on your biggest decision until you do.",
        ]

# --- TIER 2: ✨ What's New (last 24h) ---
new_notes = []
for search_dir in ['Canon', 'Thinking', os.path.join('Meta', 'AI-Reflections')]:
    full_dir = os.path.join(vault, search_dir)
    if not os.path.exists(full_dir):
        continue
    for root, dirs, files in os.walk(full_dir):
        for f in files:
            if not f.endswith('.md'):
                continue
            fm = read_frontmatter(os.path.join(root, f))
            created = fm.get('created', fm.get('first_mentioned', ''))
            if created and created >= cutoff_24h:
                note_type = fm.get('type', 'unknown')
                name = fm.get('name', f[:-3])
                source = fm.get('source', '')
                emoji = EMOJI.get(note_type, "📝")
                new_notes.append((created, f"{emoji} [[{name}]] ({source})"))
new_notes.sort(key=lambda x: x[0], reverse=True)

# --- TIER 3: 🟢 Just Happened ---
completed_items = []
comp_dir = os.path.join(vault, 'Meta', 'operations', 'completed')
if os.path.exists(comp_dir):
    for f in sorted(os.listdir(comp_dir), reverse=True)[:5]:
        if f.endswith('.md'):
            fm = read_frontmatter(os.path.join(comp_dir, f))
            exec_date = fm.get('executed_date', fm.get('approved_date', ''))
            if exec_date and exec_date >= cutoff_24h:
                subject = fm.get('subject', fm.get('name', f[:-3]))
                status = fm.get('status', '')
                icon = "✅" if status in ('approved', 'executed') else "❌"
                completed_items.append(f"{icon} {subject}")

done_tasks = []
done_dir = os.path.join(vault, 'Meta', 'sprint', 'done')
if os.path.exists(done_dir):
    for f in sorted(os.listdir(done_dir), reverse=True)[:5]:
        if f.endswith('.md'):
            fm = read_frontmatter(os.path.join(done_dir, f))
            completed = fm.get('completed', '')
            if completed and completed >= cutoff_24h:
                name = fm.get('name', f[:-3])
                done_tasks.append(f"🏗️ {name}")

# --- AI STANDUP: sprint task status ---
active_tasks = []
active_dir = os.path.join(vault, 'Meta', 'sprint', 'active')
if os.path.exists(active_dir):
    for f in sorted(os.listdir(active_dir)):
        if not f.endswith('.md'):
            continue
        fm = read_frontmatter(os.path.join(active_dir, f))
        name = fm.get('name', f[:-3])
        assignee = fm.get('assignee', '?')
        status = fm.get('status', '?')
        active_tasks.append({'name': name, 'assignee': assignee, 'status': status})

done_sprint_24h = []
done_sprint_dir = os.path.join(vault, 'Meta', 'sprint', 'done')
if os.path.exists(done_sprint_dir):
    for f in sorted(os.listdir(done_sprint_dir), reverse=True):
        if not f.endswith('.md'):
            continue
        fm = read_frontmatter(os.path.join(done_sprint_dir, f))
        completed = fm.get('completed', '')
        if completed and completed >= cutoff_24h:
            name = fm.get('name', f[:-3])
            assignee = fm.get('assignee', '?')
            done_sprint_24h.append({'name': name, 'assignee': assignee})

# Parse heartbeat output
heartbeat_failures = []
heartbeat_ok = []
for line in heartbeat.splitlines():
    line = line.strip()
    if not line or line.startswith('==='):
        continue
    if line.startswith(('❌', '🟡')):
        heartbeat_failures.append(line)
    elif line.startswith('✅'):
        heartbeat_ok.append(line)

# --- ACTIONS ---
actions_dir = os.path.join(vault, 'Canon', 'Actions')
open_actions = []
incomplete_actions = []
stale_actions = []

if os.path.exists(actions_dir):
    for f in sorted(os.listdir(actions_dir)):
        if not f.endswith('.md'):
            continue
        fm = read_frontmatter(os.path.join(actions_dir, f))
        if fm.get('type') != 'action':
            continue
        name = f[:-3]
        status = fm.get('status', '')
        if status not in ('open', 'in-progress'):
            continue
        priority = fm.get('priority', 'medium')
        due = fm.get('due', '')
        first_mentioned = fm.get('first_mentioned', '')

        open_actions.append({
            'name': name, 'status': status, 'due': due,
            'priority': priority, 'first_mentioned': first_mentioned,
            'output': fm.get('output', ''),
            'owner': fm.get('owner', ''),
        })

        missing = []
        if not due: missing.append('due')
        if not fm.get('owner', ''): missing.append('owner')
        if not fm.get('output', ''): missing.append('output')
        if missing:
            incomplete_actions.append((name, missing))

        mentions = fm.get('mentions', '')
        if isinstance(mentions, list) and len(mentions) > 1:
            stale_actions.append((name, len(mentions)))

# Sort: high priority first, then by due date
prio_order = {'high': 0, 'medium': 1, 'low': 2}
open_actions.sort(key=lambda a: (prio_order.get(a['priority'], 1), a['due'] or 'zzzz'))

# --- BUILD BRIEFING ---
lines = []
lines.append("---")
lines.append("type: briefing")
lines.append(f"date: {date}")
lines.append("source: ai-generated")
lines.append("---")
lines.append("")
lines.append(f"# ☀️ Daily Briefing — {day_name}, {date}")
lines.append("")

# 🔴 Needs You
needs_you = pending_ops + review_items + proposals
if standing_priority_lines or needs_you:
    lines.append("## 🔴 Needs You")
    lines.append("")
    for item in standing_priority_lines:
        lines.append(item)
    if standing_priority_lines and needs_you:
        lines.append("")
    for item in needs_you:
        lines.append(f"- {item}")
    lines.append("")

# ✨ What's New
if new_notes:
    lines.append("## ✨ What's New (last 24h)")
    lines.append("")
    for _, item in new_notes[:10]:
        lines.append(f"- {item}")
    lines.append("")

# 🟢 Just Happened
just_happened = completed_items + done_tasks
if just_happened:
    lines.append("## 🟢 Just Happened")
    lines.append("")
    for item in just_happened:
        lines.append(f"- {item}")
    lines.append("")

# 🤖 AI Standup
if active_tasks or done_sprint_24h or heartbeat_failures:
    lines.append("## 🤖 AI Standup")
    lines.append("")
    if done_sprint_24h:
        lines.append("**Shipped:**")
        for t in done_sprint_24h:
            lines.append(f"- ✅ {t['name']} ({t['assignee']})")
        lines.append("")
    if active_tasks:
        lines.append("**In progress:**")
        for t in active_tasks:
            lines.append(f"- 🏗️ {t['name']} → {t['assignee']} ({t['status']})")
        lines.append("")
    if heartbeat_failures:
        lines.append("**Needs attention:**")
        for line in heartbeat_failures:
            lines.append(f"- {line}")
        lines.append("")
    if not heartbeat_failures:
        lines.append("All agents healthy. ✅")
        lines.append("")

# Divider before action sections
lines.append("---")
lines.append("")

# Open Actions (compact)
lines.append(f"## 🎯 Open Actions ({len(open_actions)})")
lines.append("")
if open_actions:
    for a in open_actions[:10]:
        prio_icon = {"high": "🔴", "medium": "🟡", "low": "⚪"}.get(a['priority'], "🟡")
        due_str = f" — due {a['due']}" if a['due'] else ""
        lines.append(f"- {prio_icon} [[{a['name']}]]{due_str}")
else:
    lines.append("Nothing open. Enjoy the calm.")
lines.append("")

# Stale (only show if any)
if stale_actions:
    lines.append("## ⚠️ Keeps Coming Up")
    lines.append("")
    for name, count in sorted(stale_actions, key=lambda x: -x[1]):
        lines.append(f"- [[{name}]] — mentioned {count}x, still not done")
    lines.append("")

# Incomplete (only top 3)
if incomplete_actions[:3]:
    lines.append("## ❓ Missing Details")
    lines.append("")
    for name, missing in incomplete_actions[:3]:
        lines.append(f"- [[{name}]] — needs: {', '.join(missing)}")
    lines.append("")

# Health (compact)
if health_status:
    lines.append("## 🏥 System")
    lines.append("")
    health_lines = summarize_system_lines(health_status)
    for line in health_lines:
        lines.append(f"- {line}")
    lines.append("")

# Footer
lines.append("---")
lines.append("*Reply by voice or text. The system handles the rest.*")

# Write the file
with open(briefing_path, 'w') as f:
    f.write('\n'.join(lines))

total_lines = len(lines)
needs_you_count = standing_priority_count + len(pending_ops) + len(review_items) + len(proposals)

print(f"Briefing written: {os.path.basename(briefing_path)} ({total_lines} lines)")
print(f"  🔴 Needs You: {needs_you_count}")
print(f"  ✨ What's New: {len(new_notes)}")
print(f"  🟢 Just Happened: {len(completed_items) + len(done_tasks)}")
print(f"  🎯 Open actions: {len(open_actions)}")
print(f"  ⚠️ Stale: {len(stale_actions)}")
PYEOF

# Count open actions for notification
OPEN_COUNT=$(VAULT_DIR="$VAULT_DIR" python3 << 'COUNTEOF'
import os


def read_frontmatter(path):
    try:
        with open(path) as fh:
            content = fh.read()
        if content.startswith('---'):
            end = content.index('---', 3)
            fm = {}
            for line in content[3:end].strip().split('\n'):
                if ':' in line and not line.strip().startswith('-'):
                    key, val = line.split(':', 1)
                    fm[key.strip()] = val.strip().strip('"').strip("'")
            return fm
    except Exception:
        pass
    return {}


actions_dir = os.path.join(os.environ["VAULT_DIR"], 'Canon', 'Actions')
count = 0
if os.path.exists(actions_dir):
    for f in os.listdir(actions_dir):
        if f.endswith('.md'):
            fm = read_frontmatter(os.path.join(actions_dir, f))
            if fm.get('type') == 'action' and fm.get('status') in ('open', 'in-progress'):
                count += 1
print(count)
COUNTEOF
) || OPEN_COUNT="?"

# Count 🔴 items for notification
NEEDS_YOU=$(VAULT_DIR="$VAULT_DIR" python3 << 'NYEOF'
import os
import re


def read_frontmatter(path):
    try:
        with open(path) as fh:
            content = fh.read()
        if content.startswith('---'):
            end = content.index('---', 3)
            fm = {}
            for line in content[3:end].strip().split('\n'):
                if ':' in line and not line.strip().startswith('-'):
                    key, val = line.split(':', 1)
                    fm[key.strip()] = val.strip().strip('"').strip("'")
            return fm
    except Exception:
        pass
    return {}


def read_note(path):
    try:
        with open(path) as fh:
            return fh.read()
    except Exception:
        return ""


def moyo_resolution_logged(vault_root):
    exit_call_path = os.path.join(vault_root, 'Canon', 'Events', '2026-03-31 - Moyo Co-Founder Exit Call.md')
    if os.path.exists(exit_call_path):
        return True

    decision_path = os.path.join(vault_root, 'Canon', 'Decisions', 'Solo Founder or Find New Co-Founder.md')
    if os.path.exists(decision_path):
        decision_text = read_note(decision_path)
        decision_fm = read_frontmatter(decision_path)
        if re.search(r'^##\s+Resolution\b', decision_text, re.MULTILINE):
            return True
        if decision_fm.get('status') in ('decided', 'done', 'resolved'):
            return True

    for action_rel in (
        os.path.join('Canon', 'Actions', '_done', 'Find New Co-Founder or Go Solo.md'),
        os.path.join('Canon', 'Actions', 'Find New Co-Founder or Go Solo.md'),
    ):
        action_path = os.path.join(vault_root, action_rel)
        if os.path.exists(action_path):
            action_fm = read_frontmatter(action_path)
            if action_fm.get('status') == 'done':
                return True

    return False


count = 0
vault = os.environ["VAULT_DIR"]
ops_dir = os.path.join(vault, 'Meta', 'operations', 'pending')
rq_dir = os.path.join(vault, 'Meta', 'review-queue')
if os.path.exists(ops_dir):
    count += len([f for f in os.listdir(ops_dir) if f.endswith('.md')])
if os.path.exists(rq_dir):
    for f in os.listdir(rq_dir):
        if not f.endswith('.md'):
            continue
        fm = read_frontmatter(os.path.join(rq_dir, f))
        if fm.get('status', '') in ('', 'pending'):
            count += 1
moyo_path = os.path.join(vault, 'Canon', 'Events', '2026-03-24 - Moyo Startup Direction Meeting.md')
if os.path.exists(moyo_path):
    with open(moyo_path) as fh:
        if 'status: occurred-outcome-unknown' in fh.read() and not moyo_resolution_logged(vault):
            count += 1
print(count)
NYEOF
) || NEEDS_YOU="0"

# macOS notification
osascript -e "display notification \"${NEEDS_YOU} items need you. ${OPEN_COUNT} open actions.\" with title \"☀️ Vault Briefing\" subtitle \"$DAY_NAME, $DATE\"" 2>/dev/null || true

# Open in Obsidian (if running)
osascript -e "tell application \"System Events\" to set obsidianRunning to (name of processes) contains \"Obsidian\"" -e "if obsidianRunning then" -e "open location \"obsidian://open?vault=VaultSandbox&file=Inbox/$DATE - Daily Briefing\"" -e "end if" 2>/dev/null || true

# --- Vault Health Check ---
# Detect stuck voice memos and stale agents so silent failures don't go unnoticed.
STUCK_MEMOS=0
PROGRESS_DIR="$VAULT_DIR/Meta/.voice-progress"
if [ -d "$PROGRESS_DIR" ]; then
    for pf in "$PROGRESS_DIR"/*.json; do
        [ -f "$pf" ] || continue
        pf_stage=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('stage',''))" "$pf" 2>/dev/null || echo "")
        if [ "$pf_stage" = "received" ] || [ "$pf_stage" = "transcribing" ]; then
            STUCK_MEMOS=$((STUCK_MEMOS + 1))
        fi
    done
fi
LAST_VOICE_AGE=""
LAST_PROCESSED=$(find "$VAULT_DIR/Inbox/Voice/_processed" -name "*.ogg" -o -name "*.m4a" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
if [ -n "$LAST_PROCESSED" ]; then
    LAST_VOICE_SECS=$(( $(date +%s) - $(stat -f %m "$LAST_PROCESSED" 2>/dev/null || echo "0") ))
    if [ "$LAST_VOICE_SECS" -lt 3600 ]; then
        LAST_VOICE_AGE="<1h ago"
    elif [ "$LAST_VOICE_SECS" -lt 86400 ]; then
        LAST_VOICE_AGE="$((LAST_VOICE_SECS / 3600))h ago"
    else
        LAST_VOICE_AGE="$((LAST_VOICE_SECS / 86400))d ago"
    fi
fi
HEALTH_LINE=""
if [ "$STUCK_MEMOS" -gt 0 ]; then
    HEALTH_LINE="⚠️ Voice: $STUCK_MEMOS stuck memo(s)"
elif [ -n "$LAST_VOICE_AGE" ]; then
    HEALTH_LINE="✅ Vault OK — last voice $LAST_VOICE_AGE"
else
    HEALTH_LINE="✅ Vault OK"
fi

# Push to Telegram (if bot is set up)
if [ -f "$HOME/.vault-bot-token" ] && [ -f "$HOME/.vault-bot-chat-id" ]; then
    if [ "$NEEDS_YOU" -gt 0 ] 2>/dev/null; then
        TG_MSG="☀️ *Briefing — $DAY_NAME*

$HEALTH_LINE
🔴 $NEEDS_YOU items need you
🎯 $OPEN_COUNT open actions

/ops — see pending operations
/briefing — full breakdown
/actions — action list"
    else
        TG_MSG="☀️ *Briefing — $DAY_NAME*

$HEALTH_LINE
🎯 $OPEN_COUNT open actions. Nothing blocking.

/briefing for the full picture."
    fi
    "$SCRIPT_DIR/send-telegram.sh" "$TG_MSG" 2>/dev/null || true
fi

# ── Monday morning Advisor digest (weekly health check) ───────────────
# On Mondays, the Advisor reads last night's retro and sends a personal summary.
if [ "$DAY_NAME" = "Monday" ]; then
    echo "[$TIMESTAMP] Monday: generating Advisor weekly digest..."

    # Gather weekly stats
    WEEK_COMMITS=$(git log --since="7 days ago" --oneline 2>/dev/null | wc -l | tr -d ' ')
    WEEK_VOICE=$(find "$VAULT_DIR/Inbox/Voice" -name "*.md" -mtime -7 2>/dev/null | wc -l | tr -d ' ')
    WEEK_SESSIONS=$(find "$VAULT_DIR/Meta/advisor-sessions" -name "*.md" -mtime -7 2>/dev/null | wc -l | tr -d ' ')
    WEEK_DECISIONS=$(grep -c "^## " "$VAULT_DIR/Meta/decisions-log.md" 2>/dev/null || echo 0)

    # Overdue actions
    OVERDUE_LIST=$(VAULT_DIR="$VAULT_DIR" DATE_TODAY="$DATE" python3 <<'PYEOF'
import os, pathlib, re
vault = pathlib.Path(os.environ["VAULT_DIR"]) / "Canon" / "Actions"
today = os.environ["DATE_TODAY"]
overdue = []
for path in vault.glob("*.md"):
    text = path.read_text(encoding="utf-8")
    status_m = re.search(r'^status:\s*(.+)$', text, re.MULTILINE)
    due_m = re.search(r'^due:\s*(.+)$', text, re.MULTILINE)
    name_m = re.search(r'^name:\s*(.+)$', text, re.MULTILINE)
    if status_m and status_m.group(1).strip() == "open" and due_m:
        d = due_m.group(1).strip().strip('"')
        if d and d < today and d != "none":
            n = name_m.group(1).strip().strip('"') if name_m else path.stem
            overdue.append(f"- {n} (due {d})")
if overdue:
    print("\n".join(overdue[:5]))
    if len(overdue) > 5:
        print(f"...and {len(overdue) - 5} more")
else:
    print("None overdue")
PYEOF
    )

    # Agent health
    AGENT_HEALTH_SUMMARY=""
    NOW_TS=$(date +%s)
    DEAD_AGENTS=""
    for hb in "$HOME/.vault/heartbeats"/*; do
        [ -f "$hb" ] || continue
        agent_name=$(basename "$hb")
        last_ts=$(cat "$hb" 2>/dev/null || echo 0)
        age_hours=$(( (NOW_TS - last_ts) / 3600 ))
        if [ "$age_hours" -gt 48 ]; then
            DEAD_AGENTS="$DEAD_AGENTS $agent_name(${age_hours}h)"
        fi
    done

    # Stale reviews
    STALE_REVIEWS=$(find "$VAULT_DIR/Meta/review-queue" -name "*.md" -mtime +3 2>/dev/null | while read f; do
        grep -l "status: sent\|status: pending" "$f" 2>/dev/null
    done | wc -l | tr -d ' ')

    # Build digest query for Advisor
    DIGEST_QUERY="MONDAY WEEKLY DIGEST — summarize this week for Usman in 4-6 sentences.

Stats: $WEEK_COMMITS commits, $WEEK_VOICE voice memos, $WEEK_SESSIONS advisor sessions, $OPEN_COUNT open actions.
Overdue actions:
$OVERDUE_LIST
Dead agents (>48h no heartbeat): ${DEAD_AGENTS:-none}
Stale review items (>3 days): $STALE_REVIEWS
Unprocessed inbox notes: $UNPROCESSED

End with ONE question about the week ahead. Start with 🧠📊."

    DIGEST_RESPONSE=$(/bin/bash "$SCRIPT_DIR/run-advisor.sh" feedback "$DIGEST_QUERY" 2>/dev/null || echo "")
    if [ -n "$DIGEST_RESPONSE" ]; then
        "$SCRIPT_DIR/send-telegram.sh" "$DIGEST_RESPONSE" 2>/dev/null || true
        echo "[$TIMESTAMP] Monday digest sent."
    else
        echo "[$TIMESTAMP] Monday digest: Advisor had nothing to say."
    fi
fi

# Run researcher on any actions flagged needs-research
if [ -f "$SCRIPT_DIR/run-researcher.sh" ]; then
    echo "[$TIMESTAMP] Scanning for research requests..."
    /bin/bash "$SCRIPT_DIR/run-researcher.sh" --scan 2>&1 || echo "[$TIMESTAMP] Researcher scan failed (non-fatal)"
fi

# Send daily email digest (TLDR-style, with deep links)
if [ -f "$SCRIPT_DIR/daily-approval-email.sh" ]; then
    echo "[$TIMESTAMP] Sending daily email digest..."
    "$SCRIPT_DIR/daily-approval-email.sh" 2>&1 || echo "[$TIMESTAMP] Email digest failed (non-fatal)"
fi

# Log to changelog
"$SCRIPT_DIR/log-change.sh" "Briefing" "Generated daily briefing: ${NEEDS_YOU} needs-you, ${OPEN_COUNT} open actions"
agent_commit_changelog_if_needed "[Briefing] log: changelog update [$TIMESTAMP]"

"$SCRIPT_DIR/log-agent-feedback.sh" "Briefing" "briefing_sent" "Daily briefing: ${NEEDS_YOU} needs-you, ${OPEN_COUNT} open actions" "" "" "false" 2>/dev/null || true

echo "[$TIMESTAMP] Daily briefing complete."
