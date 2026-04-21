#!/bin/bash
# daily-approval-email.sh
# Your daily vault digest — ADHD-optimized, TLDR-style.
#
# Design philosophy:
#   - ONE clear ask at the top. Not a list. THE thing.
#   - Every item has enough context to act WITHOUT opening anything else
#   - Every item has preset buttons: the smart default is always clear
#   - Numbers are friendly, not scary (no "40 open actions")
#   - Quiet days are celebrated, not filler
#
# Deep links:
#   - Telegram: https://t.me/<bot>?start=<action>_<id>
#   - Obsidian: obsidian://open?vault=VaultSandbox&file=<path>
#
# Called by: daily-briefing.sh (after Telegram push)
# Standalone: ./daily-approval-email.sh

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"

DATE=$(date +%Y-%m-%d)
DAY_NAME=$(date +%A)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Bot username for deep links
BOT_USERNAME="${VAULT_BOT_USERNAME:-}"
if [ -z "$BOT_USERNAME" ]; then
    bot_user_file="$HOME/.vault-bot-username"
    [ -f "$bot_user_file" ] && BOT_USERNAME=$(cat "$bot_user_file")
fi

# Owner email
OWNER_EMAIL="${VAULT_OWNER_EMAIL:-}"
if [ -z "$OWNER_EMAIL" ]; then
    email_file="$HOME/.vault-owner-email"
    [ -f "$email_file" ] && OWNER_EMAIL=$(cat "$email_file")
fi

if [ -z "$OWNER_EMAIL" ]; then
    echo "[$TIMESTAMP] No owner email configured. Set VAULT_OWNER_EMAIL or create ~/.vault-owner-email"
    exit 1
fi

echo "[$TIMESTAMP] Building daily digest email..."

# Generate HTML email with Python
# Note: heredoc inside $() breaks on macOS bash 3.2, so we write to temp file
EMAIL_TMP="/tmp/vault-email-gen-$$.html"
VAULT_DIR="$VAULT_DIR" DATE="$DATE" DAY_NAME="$DAY_NAME" BOT_USERNAME="$BOT_USERNAME" python3 > "$EMAIL_TMP" << 'PYEOF'
import os, urllib.parse, re
from datetime import datetime, timedelta
from pathlib import Path

vault = os.environ.get("VAULT_DIR", ".")
date = os.environ.get("DATE", datetime.now().strftime("%Y-%m-%d"))
day_name = os.environ.get("DAY_NAME", "Today")
bot_username = os.environ.get("BOT_USERNAME", "vault_bot")

cutoff_24h = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
vault_name = "VaultSandbox"

# --- Helpers ---

def obsidian_link(relative_path):
    clean = relative_path.replace('.md', '')
    encoded = urllib.parse.quote(clean, safe='/')
    return f"obsidian://open?vault={vault_name}&file={encoded}"

def tg_link(action, item_id):
    if not bot_username: return ""
    return f"https://t.me/{bot_username}?start={action}_{item_id}"

def tg_command(cmd):
    """Deep link that sends a command to the bot."""
    if not bot_username: return ""
    return f"https://t.me/{bot_username}?start={cmd}"

def read_frontmatter(filepath):
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        if content.startswith('---'):
            end = content.index('---', 3)
            fm = {}
            for line in content[3:end].strip().split('\n'):
                if ':' in line and not line.strip().startswith('-'):
                    key, val = line.split(':', 1)
                    fm[key.strip()] = val.strip().strip('"').strip("'")
            return fm, content
    except:
        pass
    return {}, ""

def strip_md(text):
    """Strip markdown formatting for email HTML."""
    text = re.sub(r'\[\[([^\]]+)\]\]', r'\1', text)   # wikilinks
    text = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', text)  # bold → HTML bold
    text = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<em>\1</em>', text)  # italic → HTML italic
    # Remove markdown headings, horizontal rules, comments
    lines = []
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped.startswith('#'):
            continue  # Drop headings
        if stripped == '---' or stripped == '***':
            continue  # Drop horizontal rules
        if stripped.startswith('<!--'):
            continue  # Drop HTML comments
        # Inline code → plain text (anywhere in line)
        stripped = re.sub(r'`([^`]+)`', r'\1', stripped)
        lines.append(stripped)
    return '<br>'.join(l for l in lines if l).strip()

def get_body(content):
    """Get everything after frontmatter."""
    try:
        if content.startswith('---'):
            end = content.index('---', 3) + 3
            return content[end:].strip()
        return content.strip()
    except:
        return ""

def read_linked_action(action_ref):
    """Read the linked action file and return rich context."""
    if not action_ref:
        return {}
    # Normalize: remove .md, try Canon/Actions/
    name = action_ref.replace('.md', '').strip()
    candidates = [
        os.path.join(vault, 'Canon', 'Actions', f'{name}.md'),
        os.path.join(vault, 'Canon', 'Actions', name),
    ]
    for path in candidates:
        if os.path.exists(path):
            fm, content = read_frontmatter(path)
            body = get_body(content)
            return {
                'name': fm.get('name', name),
                'status': fm.get('status', ''),
                'due': fm.get('due', ''),
                'output': fm.get('output', ''),
                'priority': fm.get('priority', ''),
                'owner': fm.get('owner', ''),
                'linked': fm.get('linked', ''),
                'body_snippet': strip_md(body[:400]),
            }
    return {}

def find_people_emails(people_refs):
    """Look up email addresses for linked people from Canon/People/."""
    results = []
    people_dir = os.path.join(vault, 'Canon', 'People')
    if not os.path.exists(people_dir):
        return results

    # Build a lookup of all people with emails
    for f in os.listdir(people_dir):
        if not f.endswith('.md'):
            continue
        fm, _ = read_frontmatter(os.path.join(people_dir, f))
        email = fm.get('email', '')
        if email:
            name = fm.get('name', f[:-3])
            results.append({'name': name, 'email': email, 'file': f})
    return results

def generate_recommendation(op_fm, action_ctx, is_blocked):
    """Generate a strategy-consultant-style recommendation."""
    if is_blocked:
        return ""

    rec_parts = []
    action_name = action_ctx.get('name', op_fm.get('name', ''))
    due = action_ctx.get('due', '')
    status = action_ctx.get('status', '')
    output_goal = action_ctx.get('output', '')

    # Timeliness
    if due:
        from datetime import datetime
        try:
            due_date = datetime.strptime(due, '%Y-%m-%d')
            today = datetime.now()
            days = (due_date - today).days
            if days < 0:
                rec_parts.append(f'This was due {abs(days)} days ago — sending now is better than not sending.')
            elif days == 0:
                rec_parts.append('Due today. Send it now.')
            elif days <= 3:
                rec_parts.append(f'Due in {days} days. Good time to send.')
        except:
            pass

    # Don't include goal here — it's shown separately in the card body
    return ' '.join(rec_parts) if rec_parts else ''

def parse_operation(filepath):
    """Deep-read an operation file with linked context."""
    fm, content = read_frontmatter(filepath)
    body = get_body(content)

    is_blocked = fm.get('status') == 'blocked' or 'blocked' in fm.get('name', '').lower()
    needs_input = fm.get('needs_human_input') == 'true'

    # Read linked action for context
    action_ref = fm.get('source_action', '')
    action_ctx = read_linked_action(action_ref)

    # Parse sections
    current_section = ''
    section_lines = {}
    for line in body.split('\n'):
        stripped = line.strip()
        if stripped.startswith('## '):
            current_section = stripped[3:].lower().strip()
            section_lines[current_section] = []
        elif current_section:
            section_lines.setdefault(current_section, []).append(line)
        else:
            section_lines.setdefault('_preamble', []).append(line)

    preamble = '\n'.join(section_lines.get('_preamble', [])).strip()
    deliverable = '\n'.join(section_lines.get('deliverable', [])).strip()
    what_section = '\n'.join(section_lines.get('what', [])).strip()
    context_section = '\n'.join(section_lines.get('context', [])).strip()

    # For blocked items: find candidate emails
    candidate_emails = []
    if is_blocked and 'email' in body.lower():
        all_emails = find_people_emails([])
        # Try to match against linked people in the action
        action_linked = action_ctx.get('linked', '')
        if action_linked:
            for person in all_emails:
                if person['name'].lower() in action_linked.lower() or person['name'].lower() in body.lower():
                    candidate_emails.append(person)
        # If no matches, suggest all people with emails (top 5)
        if not candidate_emails:
            candidate_emails = all_emails[:5]

    # Build blocking reason
    blocking_reason = ''
    needs_input_text = ''
    if is_blocked:
        blocking_reason = strip_md(preamble) if preamble else 'No details provided.'
        for line in body.split('\n'):
            if 'to unblock' in line.lower():
                needs_input_text = strip_md(line.strip().lstrip('*').strip())
                break

    # Build deliverable preview
    deliverable_html = ''
    if deliverable:
        deliverable_html = strip_md(deliverable[:500])
    elif 'DRY RUN' in preamble:
        deliverable_html = strip_md(preamble[:400])
    elif preamble and not is_blocked:
        deliverable_html = strip_md(preamble[:400])

    # Generate recommendation
    recommendation = generate_recommendation(fm, action_ctx, is_blocked)

    # Smart options based on context
    smart_options = []
    if not is_blocked:
        smart_options.append({
            'label': '✅ Send as-is',
            'action': 'approve',
            'style': 'btn-green',
            'default': True,
        })
        if action_ctx.get('body_snippet'):
            smart_options.append({
                'label': '✏️ Edit draft first',
                'action': 'edit',
                'style': 'btn-ghost',
            })
        smart_options.append({
            'label': '❌ Don\'t send',
            'action': 'reject',
            'style': 'btn-ghost btn-sm',
        })
    else:
        # Blocked: offer candidate emails as options
        for person in candidate_emails[:3]:
            smart_options.append({
                'label': f'📧 Send to {person["name"]} ({person["email"]})',
                'action': f'unblock_email_{person["email"]}',
                'style': 'btn-ghost',
                'full_width': True,
            })
        smart_options.append({
            'label': '💬 Type a different address',
            'action': 'reply',
            'style': 'btn-blue btn-sm',
        })
        smart_options.append({
            'label': '❌ Skip this one',
            'action': 'reject',
            'style': 'btn-ghost btn-sm',
        })

    return {
        'fm': fm,
        'is_blocked': is_blocked,
        'needs_input': needs_input,
        'action_ctx': action_ctx,
        'blocking_reason': blocking_reason,
        'needs_input_text': needs_input_text,
        'deliverable_html': deliverable_html,
        'recommendation': recommendation,
        'smart_options': smart_options,
        'candidate_emails': candidate_emails,
        'what': strip_md(what_section) if what_section else '',
        'context': strip_md(context_section) if context_section else '',
    }

def parse_review_item(filepath):
    """Deep-read a review queue item."""
    fm, content = read_frontmatter(filepath)
    body = get_body(content)

    result = {
        'fm': fm,
        'body_html': strip_md(body[:600]),
        'ask': '',       # What specifically is being asked
        'options': [],   # Preset options if detectable
    }

    # Detect the ask
    body_lower = body.lower()
    for line in body.split('\n'):
        ll = line.lower().strip()
        if any(w in ll for w in ['please', 'need you to', 'can you', 'verify', 'confirm', 'is this', 'what is']):
            result['ask'] = strip_md(line.strip().lstrip('*-').strip())
            break

    # Detect preset options (lines starting with - or * that look like choices)
    for line in body.split('\n'):
        stripped = line.strip()
        if stripped.startswith(('- ', '* ', '1.', '2.', '3.')) and len(stripped) > 5:
            option = re.sub(r'^[-*\d.]+\s*', '', stripped).strip()
            if len(option) > 3 and len(option) < 100:
                result['options'].append(strip_md(option))

    return result

def friendly_count(n, noun):
    """ADHD-friendly count: never scary big numbers."""
    if n == 0: return f"No {noun}s"
    if n == 1: return f"1 {noun}"
    if n <= 5: return f"{n} {noun}s"
    return f"{n} {noun}s"  # Still show, but framing matters more

EMOJI = {
    "person": "👤", "action": "🎯", "event": "📅",
    "reflection": "💭", "belief": "🪨", "research": "🔬",
    "decision": "⚖️", "place": "📍", "organization": "🏢",
    "concept": "💡", "emerging": "🌱", "project": "📁",
    "ai-reflection": "🤖",
}

# --- Collect data ---

# Operations needing approval (DEEP READ)
ops_items = []
ops_dir = os.path.join(vault, 'Meta', 'operations', 'pending')
if os.path.exists(ops_dir):
    for f in sorted(os.listdir(ops_dir)):
        if not f.endswith('.md'): continue
        filepath = os.path.join(ops_dir, f)
        parsed = parse_operation(filepath)
        fm = parsed['fm']
        op_id = fm.get('op_id', f.replace('.md', ''))
        op_type = fm.get('type', '')
        to = fm.get('to', '')
        subject = fm.get('subject', fm.get('name', f[:-3]))
        is_blocked = fm.get('status') == 'blocked' or 'blocked' in fm.get('name', '').lower()
        needs_input = fm.get('needs_human_input') == 'true'
        icon = {"email": "📧", "calendar": "📅", "document": "📄"}.get(op_type, "⚡")

        ops_items.append({
            'icon': icon, 'subject': subject, 'to': to,
            'op_type': op_type, 'op_id': op_id,
            'is_blocked': is_blocked, 'needs_input': needs_input,
            'what': parsed['what'],
            'deliverable_html': parsed['deliverable_html'],
            'context': parsed['context'],
            'blocking_reason': parsed['blocking_reason'],
            'needs_input_text': parsed['needs_input_text'],
            'recommendation': parsed['recommendation'],
            'smart_options': parsed['smart_options'],
            'action_ctx': parsed['action_ctx'],
            'candidate_emails': parsed['candidate_emails'],
            'tg_approve': tg_link('approve', op_id),
            'tg_reject': tg_link('reject', op_id),
            'tg_reply': tg_link('reply', op_id),
            'obs_link': obsidian_link(f'Meta/operations/pending/{f}'),
        })

# Review queue items (DEEP READ)
review_items = []
rq_dir = os.path.join(vault, 'Meta', 'review-queue')
if os.path.exists(rq_dir):
    for f in sorted(os.listdir(rq_dir)):
        if not f.endswith('.md'): continue
        filepath = os.path.join(rq_dir, f)
        parsed = parse_review_item(filepath)
        fm = parsed['fm']
        status = fm.get('status', '')
        if status not in ('pending', ''): continue
        name = fm.get('name', f[:-3])
        item_id = f.replace('.md', '').replace(' ', '-')

        # Classify
        body_lower = parsed['body_html'].lower()
        if any(w in body_lower for w in ['verify', 'correct', 'check if', 'is this right', 'confirm']):
            rtype = 'fact-check'
        elif any(w in body_lower for w in ['only you', 'need your', 'what is', 'who is', 'address', 'phone', 'input needed']):
            rtype = 'human-input'
        elif any(w in body_lower for w in ['approve', 'permission', 'allow', 'proceed']):
            rtype = 'approval'
        else:
            rtype = 'generic'

        review_items.append({
            'name': name, 'rtype': rtype,
            'body_html': parsed['body_html'],
            'ask': parsed['ask'],
            'options': parsed['options'],
            'tg_link': tg_link('review', item_id),
            'obs_link': obsidian_link(f'Meta/review-queue/{f}'),
        })

# Top action (THE #1 thing)
top_action = None
actions_dir = os.path.join(vault, 'Canon', 'Actions')
open_action_count = 0
if os.path.exists(actions_dir):
    priority_order = {'high': 0, 'medium': 1, 'low': 2, '': 3}
    raw = []
    for f in os.listdir(actions_dir):
        if not f.endswith('.md'): continue
        fm, content = read_frontmatter(os.path.join(actions_dir, f))
        status = fm.get('status', 'open')
        if status not in ('open', 'in-progress'): continue
        open_action_count += 1
        priority = fm.get('priority', '')
        name = fm.get('name', f[:-3])
        due = fm.get('due', '')
        output = fm.get('output', '')
        raw.append((priority_order.get(priority, 3), due or 'zzz', name, priority, due, output, f))
    raw.sort()
    if raw:
        _, _, name, priority, due, output, f = raw[0]
        top_action = {
            'name': name, 'priority': priority, 'due': due, 'output': output,
            'obs_link': obsidian_link(f'Canon/Actions/{f}'),
            'tg_done': tg_command(f'done_{name.replace(" ", "_")[:30]}'),
        }

# What's new (last 24h)
new_notes = []
for search_dir in ['Canon', 'Thinking', os.path.join('Meta', 'AI-Reflections')]:
    full_dir = os.path.join(vault, search_dir)
    if not os.path.exists(full_dir): continue
    for root, dirs, files in os.walk(full_dir):
        for f in files:
            if not f.endswith('.md'): continue
            rel_path = os.path.relpath(os.path.join(root, f), vault)
            fm, _ = read_frontmatter(os.path.join(root, f))
            created = fm.get('created', fm.get('first_mentioned', ''))
            if created and created >= cutoff_24h:
                note_type = fm.get('type', 'unknown')
                name = fm.get('name', f[:-3])
                emoji = EMOJI.get(note_type, "📝")
                new_notes.append((created, emoji, name, note_type, obsidian_link(rel_path)))
new_notes.sort(key=lambda x: x[0], reverse=True)

# Decomposed actions with progress (sub-steps)
decomposed_progress = []
if os.path.exists(actions_dir):
    # Find actions that have sub-actions (parent_action field links them)
    sub_actions = {}  # parent_name -> list of sub-action info
    for f in os.listdir(actions_dir):
        if not f.endswith('.md'): continue
        fm, _ = read_frontmatter(os.path.join(actions_dir, f))
        parent = fm.get('parent_action', '')
        if parent:
            parent_name = parent.replace('.md', '').strip()
            if parent_name not in sub_actions:
                sub_actions[parent_name] = {'done': 0, 'total': 0, 'pending_input': [], 'name': parent_name}
            sub_actions[parent_name]['total'] += 1
            status = fm.get('status', 'open')
            if status == 'done':
                sub_actions[parent_name]['done'] += 1
            exec_type = fm.get('execution_type', '')
            if exec_type == 'input' and status in ('open', 'in-progress'):
                sub_actions[parent_name]['pending_input'].append(fm.get('name', f[:-3]))

    for parent_name, info in sub_actions.items():
        if info['total'] > 0:
            pct = int(100 * info['done'] / info['total'])
            decomposed_progress.append({
                'name': parent_name,
                'done': info['done'],
                'total': info['total'],
                'pct': pct,
                'pending_input': info['pending_input'][:2],  # Max 2 to show
                'obs_link': obsidian_link(f'Canon/Actions/{parent_name}'),
                'tg_steps': tg_command(f'steps_{parent_name.replace(" ", "_")[:30]}'),
            })

# Recent advisor decisions (from decisions-log.md, last 24h)
recent_decisions = []
decisions_path = os.path.join(vault, 'Meta', 'decisions-log.md')
if os.path.exists(decisions_path):
    try:
        with open(decisions_path) as f:
            content = f.read()
        # Parse decision entries — format: ## YYYY-MM-DD HH:MM — Title
        # Parse decision entries — format: ## YYYY-MM-DD HH:MM — Title
        for line_raw in content.split('\n'):
            if not line_raw.startswith('## 20'): continue
            parts = line_raw[3:].split(' — ', 1)
            if len(parts) < 2: continue
            d_datetime = parts[0].strip()
            d_title = parts[1].strip()
            d_date = d_datetime[:10]
            if d_date >= cutoff_24h:
                # Get the "Decided:" line from the block after this heading
                block_start = content.find(line_raw) + len(line_raw)
                block_end = content.find('\n## ', block_start)
                block = content[block_start:block_end] if block_end != -1 else content[block_start:]
                decided = ''
                for bline in block.split('\n'):
                    if bline.strip().startswith('- **Decided:**'):
                        decided = bline.strip().replace('- **Decided:**', '').strip()
                        break
                recent_decisions.append({
                    'title': d_title,
                    'decided': decided[:200],
                })
    except Exception:
        pass

# Done recently
done_actions = []
if os.path.exists(actions_dir):
    for f in os.listdir(actions_dir):
        if not f.endswith('.md'): continue
        fm, _ = read_frontmatter(os.path.join(actions_dir, f))
        if fm.get('status') == 'done':
            updated = fm.get('updated', '')
            if updated and updated >= cutoff_24h:
                done_actions.append(fm.get('name', f[:-3]))

green_items = []
comp_dir = os.path.join(vault, 'Meta', 'operations', 'completed')
if os.path.exists(comp_dir):
    for f in sorted(os.listdir(comp_dir), reverse=True)[:5]:
        if not f.endswith('.md'): continue
        fm, _ = read_frontmatter(os.path.join(comp_dir, f))
        exec_date = fm.get('executed_date', fm.get('approved_date', ''))
        if exec_date and exec_date >= cutoff_24h:
            green_items.append(fm.get('subject', fm.get('name', f[:-3])))

pending_inputs = sum(len(dp['pending_input']) for dp in decomposed_progress)
needs_you_count = len(ops_items) + len(review_items) + pending_inputs
all_good = needs_you_count == 0

# --- Build HTML ---
html = []
html.append("""<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 540px; margin: 0 auto; padding: 20px 16px; color: #1a1a1a; background: #ffffff; line-height: 1.55; font-size: 15px; }

  /* Header */
  .header { padding-bottom: 12px; margin-bottom: 20px; border-bottom: 2px solid #111; }
  .header h1 { font-size: 18px; margin: 0 0 2px 0; font-weight: 700; }
  .header .sub { font-size: 12px; color: #9ca3af; }

  /* Hero card: THE one thing */
  .hero { background: #fef3c7; border: 1px solid #fcd34d; border-radius: 10px; padding: 16px 18px; margin-bottom: 20px; }
  .hero-quiet { background: #f0fdf4; border: 1px solid #86efac; }
  .hero .label { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; color: #92400e; margin-bottom: 6px; }
  .hero-quiet .label { color: #166534; }
  .hero .title { font-size: 17px; font-weight: 700; margin-bottom: 4px; }
  .hero .context { font-size: 13px; color: #6b7280; margin-bottom: 10px; }

  /* Decision cards */
  .card { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 14px 16px; margin-bottom: 12px; }
  .card-red { border-left: 4px solid #dc2626; }
  .card-blue { border-left: 4px solid #2563eb; }
  .card .card-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.3px; color: #9ca3af; margin-bottom: 4px; }
  .card .card-title { font-size: 15px; font-weight: 700; margin-bottom: 4px; }
  .card .card-body { font-size: 13px; color: #4b5563; margin-bottom: 10px; line-height: 1.5; }
  .card .card-ask { font-size: 13px; color: #1a1a1a; font-weight: 600; margin-bottom: 10px; }

  /* Buttons */
  .btns { display: flex; gap: 8px; flex-wrap: wrap; }
  .btn { display: inline-block; padding: 8px 18px; border-radius: 6px; font-size: 13px; font-weight: 600; text-decoration: none; text-align: center; min-width: 100px; }
  .btn-green { background: #16a34a; color: #fff; }
  .btn-red { background: #dc2626; color: #fff; }
  .btn-blue { background: #2563eb; color: #fff; }
  .btn-ghost { background: #f9fafb; color: #374151; border: 1px solid #d1d5db; }
  .btn-sm { padding: 5px 12px; min-width: 70px; font-size: 12px; }
  .btn-fw { width: 100%; text-align: left; min-width: auto; }

  /* Section */
  .section { margin: 24px 0 12px 0; }
  .section-title { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px; color: #9ca3af; margin-bottom: 10px; }
  .row { padding: 6px 0; border-bottom: 1px solid #f3f4f6; font-size: 14px; }
  .row:last-child { border-bottom: none; }
  .row a { color: #1a1a1a; text-decoration: none; }
  .row .meta { color: #9ca3af; font-size: 12px; }

  /* Footer */
  .footer { margin-top: 28px; padding-top: 12px; border-top: 1px solid #e5e7eb; font-size: 11px; color: #9ca3af; text-align: center; }
  .footer a { color: #6b7280; text-decoration: none; }
</style></head><body>""")

# --- HEADER ---
html.append(f'''<div class="header">
  <h1>☀️ {day_name}</h1>
  <div class="sub">{date} · Your vault processed {len(new_notes)} new note{"s" if len(new_notes) != 1 else ""} yesterday</div>
</div>''')

# --- HERO: THE #1 thing ---
def render_op_card(item, is_hero=False):
    """Render an operation as a strategy-consultant proposal card.
    Every card answers: What is this? Why now? What do I do? — with one-tap options."""
    lines = []
    ctx = item.get('action_ctx', {})
    rec = item.get('recommendation', '')
    opts = item.get('smart_options', [])

    wrapper = 'hero' if is_hero else ('card card-red' if item['is_blocked'] else 'card')
    label_cls = 'label' if is_hero else 'card-label'

    lines.append(f'<div class="{wrapper}">')
    if is_hero:
        lines.append(f'  <div class="{label_cls}">👆 Your #1 thing today</div>')
    else:
        lines.append(f'  <div class="{label_cls}">{item["op_type"] or "operation"}</div>')

    lines.append(f'  <div class="card-title">{item["icon"]} {item["subject"]}</div>')
    lines.append('  <div class="card-body">')

    if item['is_blocked']:
        # --- BLOCKED CARD: explain the blocker + offer presets ---
        lines.append(f'    <div style="color:#dc2626;font-weight:600;margin-bottom:6px">⚠️ Blocked — needs your input</div>')
        if item['blocking_reason']:
            lines.append(f'    <div style="margin-bottom:8px">{item["blocking_reason"]}</div>')

        # Show the action goal for context ("what is this even about?")
        if ctx.get('output'):
            lines.append(f'    <div style="font-size:12px;color:#6b7280;margin-bottom:6px"><strong>Goal:</strong> {ctx["output"][:200]}</div>')

        # Show the action body so user knows WHAT would be emailed
        if ctx.get('body_snippet'):
            lines.append(f'    <div style="background:#f9fafb;border-radius:6px;padding:10px 12px;margin:8px 0;font-size:13px;color:#374151;border-left:3px solid #d1d5db"><strong>What this is about:</strong><br>{ctx["body_snippet"]}</div>')

        # Show candidate emails as the actual proposal
        candidates = item.get('candidate_emails', [])
        if candidates:
            lines.append(f'    <div style="margin-top:8px;font-size:13px;font-weight:600;color:#1a1a1a">People with email addresses in your vault:</div>')
            for p in candidates[:3]:
                lines.append(f'    <div style="font-size:13px;margin:2px 0">• {p["name"]} — {p["email"]}</div>')

    else:
        # --- NORMAL CARD: full proposal with context ---
        if item['to']:
            lines.append(f'    <div style="margin-bottom:4px"><strong>To:</strong> {item["to"]}</div>')

        # Action goal — the WHY behind this operation
        if ctx.get('output'):
            lines.append(f'    <div style="margin-bottom:6px"><strong>Goal:</strong> {ctx["output"][:200]}</div>')

        # Due date / priority context
        meta_bits = []
        if ctx.get('due'):
            meta_bits.append(f'Due: {ctx["due"]}')
        if ctx.get('priority'):
            meta_bits.append(f'Priority: {ctx["priority"]}')
        if meta_bits:
            lines.append(f'    <div style="font-size:12px;color:#6b7280;margin-bottom:6px">{" · ".join(meta_bits)}</div>')

        # Recommendation — the consultant's advice
        if rec:
            lines.append(f'    <div style="background:#eff6ff;border-radius:6px;padding:8px 12px;margin:8px 0;font-size:13px;color:#1e40af;font-weight:500">{rec}</div>')

        # Deliverable preview (what will actually be sent)
        if item['deliverable_html']:
            lines.append(f'    <div style="background:#f9fafb;border-radius:6px;padding:10px 12px;margin:8px 0;font-size:13px;color:#374151;border-left:3px solid #d1d5db">{item["deliverable_html"][:400]}</div>')

        # Linked context
        if item['context']:
            lines.append(f'    <div style="font-size:12px;color:#6b7280;margin-top:6px">{item["context"]}</div>')

    lines.append('  </div>')

    # --- SMART BUTTONS: context-dependent, pre-filled ---
    if opts:
        # The ask: concise, based on card type
        if item['is_blocked']:
            lines.append('  <div class="card-ask">Pick one to unblock, or type your own:</div>')
        else:
            lines.append('  <div class="card-ask">Your call:</div>')

        lines.append('  <div class="btns" style="flex-direction:column;gap:6px">')
        for opt in opts:
            style = opt.get('style', 'btn-ghost')
            full_w = 'width:100%;text-align:left;min-width:auto;' if opt.get('full_width') else ''

            # Map action to deep link
            action = opt.get('action', '')
            if action == 'approve':
                href = item['tg_approve']
            elif action == 'reject':
                href = item['tg_reject']
            elif action == 'edit':
                href = item['obs_link']
            elif action == 'reply':
                href = item['tg_reply']
            elif action.startswith('unblock_email_'):
                email_addr = action.replace('unblock_email_', '')
                href = tg_link('unblock', f'{item["op_id"]}_{email_addr}')
            else:
                href = item.get('tg_reply', '')

            lines.append(f'    <a class="btn {style}" style="{full_w}" href="{href}">{opt["label"]}</a>')

        lines.append('  </div>')
    else:
        # Fallback: minimal buttons
        lines.append('  <div class="btns">')
        lines.append(f'    <a class="btn btn-blue" href="{item["tg_reply"]}">💬 Reply</a>')
        lines.append(f'    <a class="btn btn-ghost btn-sm" href="{item["obs_link"]}">Open note</a>')
        lines.append('  </div>')

    lines.append('</div>')
    return '\n'.join(lines)


def render_review_card(item, is_hero=False):
    """Render a review item as a smart proposal card.
    Each card has: context, a single clear ask, and preset option buttons."""
    lines = []
    wrapper = 'hero' if is_hero else 'card card-blue'
    label_cls = 'label' if is_hero else 'card-label'

    ask_labels = {
        'fact-check': "❓ Quick check",
        'human-input': "🎤 Only you know this",
        'approval': "⚡ Green light needed",
        'generic': "📋 Review",
    }

    lines.append(f'<div class="{wrapper}">')
    if is_hero:
        lines.append(f'  <div class="{label_cls}">👆 Your #1 thing today</div>')
    else:
        lines.append(f'  <div class="{label_cls}">{ask_labels.get(item["rtype"], "Review")}</div>')

    lines.append(f'  <div class="card-title">{item["name"]}</div>')

    # Full context so user never needs to open the note
    lines.append('  <div class="card-body">')
    if item['body_html']:
        lines.append(f'    <div>{item["body_html"][:600]}</div>')
    lines.append('  </div>')

    # Single clear ask
    if item['ask']:
        lines.append(f'  <div class="card-ask">{item["ask"]}</div>')
    else:
        default_asks = {
            'fact-check': "Is this correct?",
            'human-input': "I need info only you have:",
            'approval': "Should I go ahead?",
            'generic': "Take a look:",
        }
        lines.append(f'  <div class="card-ask">{default_asks.get(item["rtype"], "Your call:")}</div>')

    # Preset options as full-width clickable proposals
    if item['options']:
        lines.append('  <div class="btns" style="flex-direction:column;gap:6px">')
        for i, option in enumerate(item['options'][:4]):
            item_slug = item.get('name', 'item').replace(' ', '_')[:20]
            option_cmd = tg_link('answer', f'{item_slug}_{i}')
            lines.append(f'    <a class="btn btn-ghost" style="text-align:left;width:100%;min-width:auto" href="{option_cmd}">{option}</a>')
        lines.append(f'    <a class="btn btn-blue btn-sm" href="{item["tg_link"]}" style="width:auto">💬 Something else</a>')
        lines.append('  </div>')
    else:
        # Smart defaults based on type
        lines.append('  <div class="btns">')
        if item['rtype'] == 'fact-check':
            lines.append(f'    <a class="btn btn-green" href="{item["tg_link"]}">✅ Correct</a>')
            lines.append(f'    <a class="btn btn-blue btn-sm" href="{item["tg_link"]}">✏️ Fix it</a>')
        elif item['rtype'] == 'human-input':
            lines.append(f'    <a class="btn btn-blue" href="{item["tg_link"]}">💬 Reply</a>')
            lines.append(f'    <a class="btn btn-ghost btn-sm" href="{item["tg_link"]}">🎤 Voice</a>')
        elif item['rtype'] == 'approval':
            lines.append(f'    <a class="btn btn-green" href="{item["tg_link"]}">✅ Go ahead</a>')
            lines.append(f'    <a class="btn btn-ghost btn-sm" href="{item["tg_link"]}">✗ No</a>')
        else:
            lines.append(f'    <a class="btn btn-blue" href="{item["tg_link"]}">💬 Reply</a>')
        lines.append(f'    <a class="btn btn-ghost btn-sm" href="{item["obs_link"]}">Open note</a>')
        lines.append('  </div>')

    lines.append('</div>')
    return '\n'.join(lines)


# --- RENDER HERO ---
all_items = ops_items + review_items
if all_items:
    hero = all_items[0]
    if 'subject' in hero:
        html.append(render_op_card(hero, is_hero=True))
    else:
        html.append(render_review_card(hero, is_hero=True))
else:
    html.append(f'''<div class="hero hero-quiet">
  <div class="label">✅ All clear</div>
  <div class="title">Nothing needs your decision today</div>
  <div class="context">Your vault is running smoothly. {"You completed " + str(len(done_actions)) + " thing" + ("s" if len(done_actions) != 1 else "") + " yesterday — nice." if done_actions else "Enjoy the calm."}</div>
</div>''')

# --- MORE DECISIONS ---
remaining = all_items[1:]
if remaining:
    html.append('<div class="section"><div class="section-title">Also needs you</div>')
    for item in remaining[:4]:
        if 'subject' in item:
            html.append(render_op_card(item, is_hero=False))
        else:
            html.append(render_review_card(item, is_hero=False))
    html.append('</div>')

# --- YOUR #1 ACTION (not decisions, just the top thing to DO) ---
if top_action:
    due_text = f" · Due {top_action['due']}" if top_action['due'] else ""
    output_text = f"<br><span class='meta'>Goal: {top_action['output']}</span>" if top_action['output'] else ""
    html.append(f'''<div class="section"><div class="section-title">🎯 Your next move</div>
<div class="card">
  <div class="card-title">{top_action["name"]}</div>
  <div class="card-body">Priority: {top_action["priority"] or "medium"}{due_text}{output_text}</div>
  <div class="btns">
    <a class="btn btn-green btn-sm" href="{top_action["tg_done"]}">✅ Done</a>
    <a class="btn btn-ghost btn-sm" href="{top_action["obs_link"]}">Open</a>
    <a class="btn btn-ghost btn-sm" href="{tg_command('next')}">Skip → next</a>
  </div>
</div></div>''')

# --- DECOMPOSER PROGRESS ---
if decomposed_progress:
    html.append('<div class="section"><div class="section-title">📋 Plans in progress</div>')
    for dp in decomposed_progress:
        bar_width = dp['pct']
        bar_color = '#16a34a' if dp['pct'] >= 80 else '#2563eb' if dp['pct'] >= 40 else '#9ca3af'
        html.append(f'''<div class="card">
  <div class="card-title">{dp["name"]}</div>
  <div class="card-body">
    <div style="background:#f3f4f6;border-radius:4px;height:8px;margin:6px 0">
      <div style="background:{bar_color};width:{bar_width}%;height:8px;border-radius:4px"></div>
    </div>
    <div style="font-size:12px;color:#6b7280">{dp["done"]}/{dp["total"]} steps done ({dp["pct"]}%)</div>''')
        if dp['pending_input']:
            html.append(f'    <div style="margin-top:6px;font-size:13px;color:#1e40af;font-weight:500">❓ Needs your input: {dp["pending_input"][0]}</div>')
        html.append(f'''  </div>
  <div class="btns">
    <a class="btn btn-ghost btn-sm" href="{dp["tg_steps"]}">📊 See steps</a>
    <a class="btn btn-ghost btn-sm" href="{dp["obs_link"]}">Open</a>
  </div>
</div>''')
    html.append('</div>')

# --- RECENT DECISIONS ---
if recent_decisions:
    html.append('<div class="section"><div class="section-title">⚖️ Decisions logged</div>')
    for rd in recent_decisions[:3]:
        html.append(f'<div class="row"><strong>{rd["title"]}</strong>')
        if rd['decided']:
            html.append(f'<br><span class="meta">{rd["decided"]}</span>')
        html.append('</div>')
    html.append('</div>')

# --- WHAT HAPPENED (compact) ---
activity = done_actions + green_items
if activity or new_notes:
    html.append('<div class="section"><div class="section-title">✨ Yesterday</div>')
    for item in activity:
        html.append(f'<div class="row">✅ {item}</div>')
    for _, emoji, name, note_type, obs_link in new_notes[:6]:
        html.append(f'<div class="row"><a href="{obs_link}">{emoji} {name}</a> <span class="meta">{note_type}</span></div>')
    if len(new_notes) > 6:
        html.append(f'<div class="row meta">+ {len(new_notes) - 6} more</div>')
    html.append('</div>')

# --- FOOTER ---
tg_open = f'https://t.me/{bot_username}' if bot_username else ''
html.append(f'''<div class="footer">
  <a href="{tg_open}">💬 Telegram</a> &nbsp;·&nbsp; <a href="obsidian://open?vault={vault_name}">📓 Obsidian</a> &nbsp;·&nbsp; <a href="{tg_command("actions")}">🎯 All actions</a>
  <br><br>Sent by your vault. Just reply by voice — the system handles the rest.
</div>''')

html.append("</body></html>")
print('\n'.join(html))
PYEOF

EMAIL_HTML=$(cat "$EMAIL_TMP" 2>/dev/null)
rm -f "$EMAIL_TMP"

if [ -z "$EMAIL_HTML" ]; then
    echo "[$TIMESTAMP] Failed to generate email HTML"
    exit 1
fi

# Save HTML for sending
EMAIL_FILE="/tmp/vault-briefing-${DATE}.html"
echo "$EMAIL_HTML" > "$EMAIL_FILE"

# Count for subject line
NEEDS_YOU_TMP="/tmp/vault-needs-you-$$.txt"
VAULT_DIR="$VAULT_DIR" python3 > "$NEEDS_YOU_TMP" << 'NYEOF'
import os
count = 0
vault = os.environ["VAULT_DIR"]
for d in ['Meta/operations/pending', 'Meta/review-queue']:
    full = os.path.join(vault, d)
    if os.path.exists(full):
        count += len([f for f in os.listdir(full) if f.endswith('.md')])
print(count)
NYEOF
NEEDS_YOU=$(cat "$NEEDS_YOU_TMP" 2>/dev/null)
rm -f "$NEEDS_YOU_TMP"
NEEDS_YOU="${NEEDS_YOU:-0}"

# Subject line: clear, specific, not scary
if [ "$NEEDS_YOU" -gt 0 ] 2>/dev/null; then
    if [ "$NEEDS_YOU" -eq 1 ]; then
        SUBJECT="☀️ 1 thing needs you — $DAY_NAME"
    else
        SUBJECT="☀️ ${NEEDS_YOU} things need you — $DAY_NAME"
    fi
else
    SUBJECT="☀️ All clear — $DAY_NAME"
fi

# Send via Gmail SMTP
if [ -f "$SCRIPT_DIR/send-email.sh" ]; then
    if "$SCRIPT_DIR/send-email.sh" "$OWNER_EMAIL" "$SUBJECT" "$EMAIL_FILE" 2>/dev/null; then
        echo "[$TIMESTAMP] Email sent to $OWNER_EMAIL"
    else
        echo "[$TIMESTAMP] Email send failed. Check ~/.vault-gmail-app-password"
        "$SCRIPT_DIR/send-telegram.sh" "⚠️ Daily email failed to send. Check Gmail credentials." 2>/dev/null || true
    fi
else
    echo "[$TIMESTAMP] No send-email.sh found. HTML saved to $EMAIL_FILE"
fi

# Also save an HTML preview in the vault for testing
cp "$EMAIL_FILE" "$VAULT_DIR/Meta/scripts/email-preview.html" 2>/dev/null || true

# Log
"$SCRIPT_DIR/log-change.sh" "Briefing" "Daily digest email: ${NEEDS_YOU} items need you"
echo "[$TIMESTAMP] Daily digest email complete."
