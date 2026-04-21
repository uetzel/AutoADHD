#!/usr/bin/env python3
"""
vault-bot.py — Telegram interface to the Obsidian vault.

Two-way:
  - Voice messages → saved to _drop → pipeline processes them
  - Text commands → routed to agents or quick updates
  - Outbound → briefing summaries pushed to your chat

Setup:
  1. Talk to @BotFather on Telegram, create a bot, get the token
  2. Set VAULT_BOT_TOKEN env var (or put it in ~/.vault-bot-token)
  3. Set VAULT_BOT_CHAT_ID to your Telegram user ID (the bot tells you on /start)
  4. pip3 install python-telegram-bot --break-system-packages
  5. Run: python3 vault-bot.py

The bot only responds to YOUR chat ID. Everyone else gets ignored.
"""

import os
import sys
import subprocess
import asyncio
import logging
import json
import re
import time
import threading
import importlib.util
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote

# Load vault-lib (shared library with SDK + streaming support)
_vault_lib_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vault-lib.py")
_spec = importlib.util.spec_from_file_location("vault_lib", _vault_lib_path)
vault_lib = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(vault_lib)
    HAS_VAULT_LIB = True
except Exception as e:
    HAS_VAULT_LIB = False
    print(f"WARN: vault-lib.py failed to load: {e}. SDK streaming disabled.")

# Load orchestrator handlers
_orch_handlers_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "orchestrator_handlers.py")
_orch_spec = importlib.util.spec_from_file_location("orch_handlers", _orch_handlers_path)
orch_handlers = importlib.util.module_from_spec(_orch_spec)
try:
    _orch_spec.loader.exec_module(orch_handlers)
    HAS_ORCH = True
except Exception as e:
    HAS_ORCH = False
    print(f"WARN: orchestrator_handlers.py failed to load: {e}. /run disabled.")

# Telegram imports
try:
    from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, ReactionTypeEmoji
    from telegram.constants import ChatAction
    from telegram.ext import (
        Application,
        CommandHandler,
        MessageHandler,
        CallbackQueryHandler,
        filters,
        ContextTypes,
    )
except ImportError:
    print("Missing dependency. Run: pip3 install python-telegram-bot --break-system-packages")
    sys.exit(1)

# --- Config ---
VAULT_DIR = os.environ.get(
    "VAULT_DIR",
    os.path.expanduser("~/VaultSandbox")
)
DROP_DIR = os.path.join(VAULT_DIR, "Inbox", "Voice", "_drop")
SCRIPTS_DIR = os.path.join(VAULT_DIR, "Meta", "scripts")
CHANGELOG = os.path.join(VAULT_DIR, "Meta", "changelog.md")
OPS_PENDING_DIR = os.path.join(VAULT_DIR, "Meta", "operations", "pending")
OPS_EXECUTING_DIR = os.path.join(VAULT_DIR, "Meta", "operations", "executing")
OPS_COMPLETED_DIR = os.path.join(VAULT_DIR, "Meta", "operations", "completed")

# Token: env var > file > fail
TOKEN = os.environ.get("VAULT_BOT_TOKEN", "")
if not TOKEN:
    token_file = os.path.expanduser("~/.vault-bot-token")
    if os.path.exists(token_file):
        TOKEN = open(token_file).read().strip()
if not TOKEN:
    print("No token found. Set VAULT_BOT_TOKEN or create ~/.vault-bot-token")
    sys.exit(1)

# Your Telegram user ID (set after first /start, or set manually)
ALLOWED_CHAT_ID = os.environ.get("VAULT_BOT_CHAT_ID", "")
if not ALLOWED_CHAT_ID:
    chat_id_file = os.path.expanduser("~/.vault-bot-chat-id")
    if os.path.exists(chat_id_file):
        ALLOWED_CHAT_ID = open(chat_id_file).read().strip()

# Logging
logging.basicConfig(
    format="%(asctime)s - vault-bot - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# --- Startup Permission Check ---
# macOS protects ~/Documents/ behind Full Disk Access.
# If the terminal app running this bot doesn't have FDA, every command
# fails with "Operation not permitted" — silently, on every single call.
# Better to catch it once at startup and refuse to run.

def check_vault_permissions():
    """Verify we can read and write the vault directory. Dies loudly if not."""
    errors = []

    # Can we read Canon/Actions?
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    try:
        if os.path.exists(actions_dir):
            os.listdir(actions_dir)
    except PermissionError:
        errors.append(f"Cannot read {actions_dir}")

    # Can we write to Inbox?
    inbox_dir = os.path.join(VAULT_DIR, "Inbox")
    test_file = os.path.join(inbox_dir, ".permission-test")
    try:
        with open(test_file, "w") as f:
            f.write("test")
        os.remove(test_file)
    except PermissionError:
        errors.append(f"Cannot write to {inbox_dir}")
    except Exception:
        pass  # Other errors (dir missing, etc.) are fine to ignore here

    # Can we read scripts?
    try:
        os.listdir(SCRIPTS_DIR)
    except PermissionError:
        errors.append(f"Cannot read {SCRIPTS_DIR}")

    if errors:
        msg = (
            "\n"
            "╔══════════════════════════════════════════════════════════╗\n"
            "║  ⚠️  FULL DISK ACCESS REQUIRED                         ║\n"
            "╠══════════════════════════════════════════════════════════╣\n"
            "║                                                        ║\n"
            "║  The vault bot can't access your vault directory.      ║\n"
            "║  macOS blocks ~/Documents/ without Full Disk Access.   ║\n"
            "║                                                        ║\n"
            "║  Fix:                                                  ║\n"
            "║  1. Open System Settings → Privacy & Security          ║\n"
            "║  2. → Full Disk Access                                 ║\n"
            "║  3. Toggle ON for the runtime you use                  ║\n"
            "║     (Terminal.app, python3, Codex, claude)            ║\n"
            "║  4. Restart the apps, then relaunch launchd jobs       ║\n"
            "║                                                        ║\n"
            "╚══════════════════════════════════════════════════════════╝\n"
        )
        for e in errors:
            msg += f"  ✗ {e}\n"
        print(msg, file=sys.stderr)
        logger.critical("Vault permissions check FAILED. See above.")
        sys.exit(1)

    logger.info("Permissions OK — vault is readable and writable.")


check_vault_permissions()

# Track last shared location (for attaching to next voice message)
last_location = {}


def get_allowed_chat_id() -> str:
    """Re-read chat ID from file each time (in case it was set after boot)."""
    cid = os.environ.get("VAULT_BOT_CHAT_ID", "")
    if not cid:
        chat_id_file = os.path.expanduser("~/.vault-bot-chat-id")
        if os.path.exists(chat_id_file):
            cid = open(chat_id_file).read().strip()
    return cid


def is_authorized(update: Update) -> bool:
    """Only respond to the vault owner."""
    allowed = get_allowed_chat_id()
    if not allowed:
        return True  # No restriction set yet (first run)
    return str(update.effective_chat.id) == str(allowed)


def log_change(agent: str, description: str):
    """Append to vault changelog."""
    try:
        subprocess.run(
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "log-change.sh"), agent, description],
            cwd=VAULT_DIR,
            timeout=5,
        )
    except Exception as e:
        logger.warning(f"Failed to log change: {e}")


# Telegram only allows these emoji for bot reactions (Bot API 7.0+)
ALLOWED_REACTIONS = {
    "👍", "👎", "❤", "🔥", "🥰", "👏", "😁", "🤔", "🤯", "😱",
    "🤬", "😢", "🎉", "🤩", "🤮", "💩", "🙏", "👌", "🕊", "🤡",
    "🥱", "🥴", "😍", "🐳", "❤‍🔥", "🌚", "🌭", "💯", "🤣", "⚡",
    "🍌", "🏆", "💔", "🤨", "😐", "🍓", "🍾", "💋", "🖕", "😈",
    "😴", "😭", "🤓", "👻", "👨‍💻", "👀", "🎃", "🙈", "😇", "😨",
    "🤝", "✍", "🤗", "🫡", "🎅", "🎄", "☃", "💅", "🤪", "🗿",
    "🆒", "💘", "🙉", "🦄", "😘", "💊", "🙊", "😎", "👾", "🤷",
    "🤷‍♂", "🤷‍♀", "😡",
}

# Map unsupported emoji to allowed alternatives
REACTION_MAP = {
    "⏳": "👀",     # processing → eyes
    "✅": "👍",     # success → thumbs up
    "❌": "👎",     # error → thumbs down
    "📧": "👌",     # email → ok
    "⚠️": "🤔",    # warning → thinking
    "📝": "✍",     # noted → writing
    "👂": "👀",     # listening → eyes
    "📥": "👌",     # saved, waiting for agent → ok hand
    "🧠": "🤓",    # advisor/brain → nerd face
}

# --- Feedback Protocol ---
# Every user action MUST show visible progress. No silent saves.
# This is a core ADHD design principle — the brain needs proof it was heard.
#
# Emoji lifecycle for any user input:
#   👀  = "I see your message" (instant, on receipt)
#   👌  = "Saved, waiting for agent" (human input saved, agent hasn't run yet)
#   ⚡  = "Agent is working on it" (agent picked it up)
#   👍  = "Done" (agent finished, result available)
#   👎  = "Failed" (something went wrong)
#
# Text confirmations follow the same pattern:
#   "📥 Saved → agent picks this up next cycle."
#   "⚡ Working..."
#   "✅ Done. Here's what changed: [summary]"
#   "⚠️ Failed: [reason]"


async def react(message, emoji: str, fallback_text: str = ""):
    """React to a message with an emoji. Falls back to short reply if reactions unsupported."""
    mapped = REACTION_MAP.get(emoji, emoji)
    if mapped not in ALLOWED_REACTIONS:
        logger.debug(f"Skipping unsupported reaction emoji: {emoji}")
        if fallback_text:
            try:
                await message.reply_text(fallback_text)
            except Exception:
                pass
        return False
    try:
        await message.set_reaction(reaction=[ReactionTypeEmoji(emoji=mapped)])
        return True
    except Exception as e:
        logger.debug(f"Reaction failed: {e}")
        # Fallback: send a short text reply so the user always gets feedback
        if fallback_text:
            try:
                await message.reply_text(fallback_text)
            except Exception:
                pass
        return False


async def typing(update):
    """Show 'typing...' indicator in chat."""
    try:
        await update.effective_chat.send_action(ChatAction.TYPING)
    except Exception:
        pass


OBSIDIAN_VAULT = "VaultSandbox"

def obsidian_link(vault_relative_path: str, display: str = None) -> str:
    """Create an obsidian:// deep link for a vault-relative file path.

    Args:
        vault_relative_path: e.g. "Meta/review-queue/20260331-moyo.md"
        display: optional display text (defaults to filename without .md)

    Returns:
        Markdown-style link that opens in Obsidian: [display](obsidian://open?...)
    """
    # Remove .md for Obsidian (it handles that)
    file_path = vault_relative_path.rstrip("/")
    if file_path.endswith(".md"):
        file_path = file_path[:-3]
    if display is None:
        display = os.path.basename(file_path)
    encoded = quote(file_path, safe="")
    return f"[{display}](obsidian://open?vault={OBSIDIAN_VAULT}&file={encoded})"


def obsidian_url(vault_relative_path: str) -> str:
    """Return a raw obsidian:// URL for a vault-relative file path."""
    file_path = vault_relative_path.rstrip("/")
    if file_path.endswith(".md"):
        file_path = file_path[:-3]
    encoded = quote(file_path, safe="")
    return f"obsidian://open?vault={OBSIDIAN_VAULT}&file={encoded}"


def convert_wikilinks(text: str) -> str:
    """Convert [[Note Name]] wikilinks to clickable Obsidian deep links for Telegram.

    Searches the vault for matching files to build correct paths.
    Falls back to a search-based Obsidian URL if no file is found.
    """
    import re
    wikilink_pattern = re.compile(r'\[\[([^\]]+)\]\]')

    def _replace_wikilink(match):
        note_name = match.group(1)
        # Search common Canon directories for the file
        for subdir in ["Actions", "People", "Events", "Concepts", "Decisions",
                       "Projects", "Organizations", "Places"]:
            candidate = os.path.join(VAULT_DIR, "Canon", subdir, f"{note_name}.md")
            if os.path.exists(candidate):
                rel_path = f"Canon/{subdir}/{note_name}"
                encoded = quote(rel_path, safe="")
                url = f"obsidian://open?vault={OBSIDIAN_VAULT}&file={encoded}"
                return f"[🔗 {note_name}]({url})"
        # Also check Thinking/ and Inbox/
        for subdir in ["Thinking", "Inbox"]:
            candidate = os.path.join(VAULT_DIR, subdir, f"{note_name}.md")
            if os.path.exists(candidate):
                rel_path = f"{subdir}/{note_name}"
                encoded = quote(rel_path, safe="")
                url = f"obsidian://open?vault={OBSIDIAN_VAULT}&file={encoded}"
                return f"[🔗 {note_name}]({url})"
        # Fallback: search-based URL (Obsidian will find it)
        encoded = quote(note_name, safe="")
        url = f"obsidian://search?vault={OBSIDIAN_VAULT}&query={encoded}"
        return f"[🔗 {note_name}]({url})"

    return wikilink_pattern.sub(_replace_wikilink, text)


def _add_locked_field(content: str, field: str) -> str:
    """Safely add a field to the locked array in YAML frontmatter.

    Handles: no locked array yet, existing locked array, prevents duplicates,
    and avoids the string-replace bugs that caused a prior corruption.
    """
    lines = content.split('\n')
    # Find frontmatter boundaries
    if not lines or lines[0].strip() != '---':
        return content
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == '---':
            end_idx = i
            break
    if end_idx is None:
        return content

    # Check if field is already locked
    fm_text = '\n'.join(lines[:end_idx])
    if re.search(rf'^\s*-\s*{re.escape(field)}\s*$', fm_text, re.MULTILINE):
        return content  # Already locked

    # Find existing locked: line
    locked_idx = None
    for i in range(1, end_idx):
        if lines[i].strip().startswith('locked:'):
            locked_idx = i
            break

    if locked_idx is not None:
        # Insert new item after locked: line (or after last existing item)
        insert_at = locked_idx + 1
        while insert_at < end_idx and lines[insert_at].strip().startswith('- '):
            insert_at += 1
        lines.insert(insert_at, f'  - {field}')
    else:
        # Add locked array just before closing ---
        lines.insert(end_idx, f'locked:\n  - {field}')

    return '\n'.join(lines)


def get_recent_changes():
    """Check what Canon entries were recently created/modified."""
    try:
        # Get files changed in the last commit
        result = subprocess.run(
            ["git", "log", "-1", "--name-only", "--pretty="],
            cwd=VAULT_DIR, capture_output=True, text=True, timeout=10,
        )
        changed = [f for f in result.stdout.strip().split("\n") if f.startswith("Canon/")]
        return changed
    except:
        return []


def get_actions_needing_input():
    """Find open actions missing key fields."""
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    gaps = []
    if not os.path.exists(actions_dir):
        return gaps
    for f in os.listdir(actions_dir):
        if not f.endswith(".md"):
            continue
        path = os.path.join(actions_dir, f)
        try:
            content = open(path).read()
            if "status: open" not in content and "status: in-progress" not in content:
                continue
            name = f[:-3]
            missing = []
            if "due:" not in content or "due: \n" in content or "due: ''" in content:
                missing.append("due date")
            if "priority:" not in content:
                missing.append("priority")
            if "output:" not in content or "output: \n" in content or "output: ''" in content:
                missing.append("expected output")
            if missing:
                gaps.append((name, missing))
        except:
            continue
    return gaps


# --- Operations Watcher ---
# Watches Meta/operations/pending/ for completed drafts from the Operator agent.
# When a file appears with notify: true, sends a Telegram message with deep link.

def _parse_operation_file(filepath):
    """Parse a pending operation YAML-frontmatter file."""
    try:
        content = open(filepath).read()
        data = {}
        if content.startswith("---"):
            fm_end = content.index("---", 3)
            fm = content[3:fm_end].strip()
            for line in fm.split("\n"):
                if ":" in line:
                    key, val = line.split(":", 1)
                    data[key.strip()] = val.strip().strip('"').strip("'")
        # Also grab body content after frontmatter
        if "---" in content[3:]:
            data["_body"] = content[content.index("---", 3) + 3:].strip()
        return data
    except Exception as e:
        logger.error(f"Failed to parse operation file {filepath}: {e}")
        return {}


def get_pending_operations():
    """List all pending operation files."""
    if not os.path.exists(OPS_PENDING_DIR):
        return []
    ops = []
    for f in sorted(os.listdir(OPS_PENDING_DIR)):
        if not f.endswith(".md"):
            continue
        path = os.path.join(OPS_PENDING_DIR, f)
        data = _parse_operation_file(path)
        data["_filename"] = f
        data["_path"] = path
        ops.append(data)
    return ops


def get_completed_operations(limit=5):
    """List recent completed operations."""
    if not os.path.exists(OPS_COMPLETED_DIR):
        return []
    ops = []
    for f in sorted(os.listdir(OPS_COMPLETED_DIR), reverse=True)[:limit]:
        if not f.endswith(".md"):
            continue
        path = os.path.join(OPS_COMPLETED_DIR, f)
        data = _parse_operation_file(path)
        data["_filename"] = f
        ops.append(data)
    return ops


def _move_to_completed(op_path, filename):
    """Move an operation file from pending to completed."""
    os.makedirs(OPS_COMPLETED_DIR, exist_ok=True)
    dest = os.path.join(OPS_COMPLETED_DIR, filename)
    os.rename(op_path, dest)
    return dest


def _move_executing_to_completed(op_path, filename):
    """Move an operation file from executing to completed."""
    os.makedirs(OPS_COMPLETED_DIR, exist_ok=True)
    dest = os.path.join(OPS_COMPLETED_DIR, filename)
    os.rename(op_path, dest)
    return dest


def _move_executing_to_pending(op_path, filename):
    """Move an operation file back from executing to pending (on failure)."""
    os.makedirs(OPS_PENDING_DIR, exist_ok=True)
    dest = os.path.join(OPS_PENDING_DIR, filename)
    try:
        # Revert status back to pending
        content = open(op_path).read()
        content = content.replace("status: executing", "status: pending")
        with open(op_path, "w") as f:
            f.write(content)
    except Exception:
        pass
    os.rename(op_path, dest)
    return dest


def _mark_action_operated(op_data):
    """Update the source action with operated_date after successful execution."""
    source_action = op_data.get("source_action", "")
    if not source_action:
        return
    action_path = os.path.join(VAULT_DIR, "Canon", "Actions", source_action)
    if not os.path.exists(action_path):
        return
    try:
        content = open(action_path).read()
        now = datetime.now().strftime("%Y-%m-%d %H:%M")
        if "operated_date:" not in content:
            # Add operated_date to frontmatter
            content = content.replace("status: open", "status: operated")
            if "---" in content[3:]:
                fm_end = content.index("---", 3)
                content = content[:fm_end] + f"operated_date: {now}\n" + content[fm_end:]
        with open(action_path, "w") as f:
            f.write(content)
    except Exception as e:
        logger.error(f"Failed to mark action operated: {e}")


def _format_op_notification(op):
    """Format a rich, context-aware Telegram notification for a pending operation.

    Each notification is a self-contained proposal: shows what will happen, why,
    and enough context to decide without opening anything else. Buttons below
    are tailored to the specific operation type."""
    op_type = op.get("type", "unknown")
    subject = op.get("subject", op.get("name", "Untitled"))
    to = op.get("to", "")
    draft_link = op.get("gmail_link", "")
    op_id = op.get("op_id", op.get("_filename", "").replace(".md", ""))
    action_source = op.get("action_source", "")
    is_blocked = op.get("status") == "blocked"
    needs_input = op.get("needs_human_input") == "true"

    # Read the full operation file for body content
    body_text = ""
    op_path = op.get("_path", "")
    if op_path and os.path.exists(op_path):
        try:
            raw = open(op_path).read()
            # Extract body after frontmatter
            if raw.startswith("---"):
                end = raw.index("---", 3) + 3
                body_text = raw[end:].strip()
            else:
                body_text = raw.strip()
        except Exception:
            pass

    # Build context-rich message
    if op_type == "email":
        msg = f"📧 Email draft ready\n\n"
        msg += f"Subject: {subject}\n"
        if to:
            msg += f"To: {to}\n"

        # Show the actual email body preview
        # Extract from ## Email Body HTML or ## Deliverable section
        preview = ""
        for section_name in ["email body html", "deliverable", "email body"]:
            marker = f"## {section_name}"
            lower_body = body_text.lower()
            idx = lower_body.find(marker)
            if idx != -1:
                section_start = body_text.index("\n", idx) + 1
                next_section = body_text.find("\n## ", section_start)
                raw_section = body_text[section_start:next_section] if next_section != -1 else body_text[section_start:]
                # Strip HTML tags for Telegram preview
                preview = re.sub(r'<[^>]+>', '', raw_section).strip()
                break

        if not preview and body_text:
            preview = re.sub(r'<[^>]+>', '', body_text).strip()

        if preview:
            # Show first ~400 chars, cleaned up
            clean = "\n".join(line.strip() for line in preview.split("\n") if line.strip())[:400]
            msg += f"\n---\n{clean}\n---\n"

        if draft_link:
            msg += f"\nGmail draft: {draft_link}\n"

        if action_source:
            msg += f"\nFrom: {action_source}\n"

    elif op_type == "calendar":
        when = op.get("when", "")
        duration = op.get("duration", "")
        attendees = op.get("attendees", "")
        description = op.get("description", "")

        msg = f"📅 Calendar event proposal\n\n"
        msg += f"Event: {subject}\n"
        if when:
            msg += f"When: {when}\n"
        if duration:
            msg += f"Duration: {duration}\n"
        if attendees:
            msg += f"With: {attendees}\n"
        if description:
            msg += f"\n{description[:300]}\n"
        if action_source:
            msg += f"\nFrom: {action_source}\n"

    elif is_blocked:
        msg = f"⚠️ Blocked — needs your input\n\n"
        msg += f"{subject}\n"
        # Show what's blocking it
        if body_text:
            preview = body_text[:400]
            msg += f"\n{preview}\n"
        if action_source:
            msg += f"\nFrom: {action_source}\n"

    else:
        msg = f"⚡ Ready for your call\n\n"
        msg += f"{subject}\n"
        if body_text:
            preview = body_text[:300]
            msg += f"\n{preview}\n"
        if action_source:
            msg += f"\nFrom: {action_source}\n"

    return msg


def _build_op_keyboard(op):
    """Build context-aware inline keyboard buttons for an operation.

    Buttons are fluid — they match the specific task, not a fixed template.
    Email? "Send as-is" + "Edit first" + "Don't send"
    Calendar? "Add to calendar" + "Change time" + "Skip"
    Blocked? "Reply with info" + "Skip"
    """
    op_id = op.get("op_id", op.get("_filename", "").replace(".md", ""))
    op_type = op.get("type", "unknown")
    is_blocked = op.get("status") == "blocked"
    to = op.get("to", "")
    subject = op.get("subject", "")

    buttons = []

    if is_blocked:
        buttons.append([
            InlineKeyboardButton("💬 Give info", callback_data=f"op_reply_{op_id}"),
            InlineKeyboardButton("⏭️ Skip for now", callback_data=f"op_reject_{op_id}"),
        ])
    elif op_type == "email":
        # Row 1: the main action with context
        send_label = f"✅ Send to {to.split('@')[0]}" if to else "✅ Send as-is"
        buttons.append([
            InlineKeyboardButton(send_label, callback_data=f"op_approve_{op_id}"),
        ])
        # Row 2: alternatives
        buttons.append([
            InlineKeyboardButton("✏️ Edit first", callback_data=f"op_edit_{op_id}"),
            InlineKeyboardButton("❌ Don't send", callback_data=f"op_reject_{op_id}"),
        ])
    elif op_type == "calendar":
        when = op.get("when", "")
        cal_label = f"📅 Add to calendar" if not when else f"📅 Confirm {when}"
        # Truncate label if too long for Telegram callback
        if len(cal_label) > 40:
            cal_label = "📅 Add to calendar"
        buttons.append([
            InlineKeyboardButton(cal_label, callback_data=f"op_approve_{op_id}"),
        ])
        buttons.append([
            InlineKeyboardButton("🕐 Change time", callback_data=f"op_reply_{op_id}"),
            InlineKeyboardButton("❌ Skip", callback_data=f"op_reject_{op_id}"),
        ])
    else:
        buttons.append([
            InlineKeyboardButton("✅ Go ahead", callback_data=f"op_approve_{op_id}"),
            InlineKeyboardButton("✏️ Adjust", callback_data=f"op_reply_{op_id}"),
        ])
        buttons.append([
            InlineKeyboardButton("❌ Cancel", callback_data=f"op_reject_{op_id}"),
        ])

    return InlineKeyboardMarkup(buttons)


async def handle_op_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle inline button clicks for operation approve/reject/edit/reply."""
    query = update.callback_query
    await query.answer()

    data = query.data
    if not data.startswith("op_"):
        return

    parts = data.split("_", 2)
    if len(parts) < 3:
        return

    action = parts[1]  # "approve", "reject", "edit", "reply"
    op_id = parts[2]

    # Keep original message visible so you remember what you're acting on
    original = query.message.text or ""
    if len(original) > 3500:
        original = original[:3500] + "\n..."

    if action == "approve":
        context.args = [op_id]
        await query.edit_message_text(
            text=f"{original}\n\n━━━━━━━━━━━━━━━\n✅ Approved. Executing..."
        )
        await cmd_approve(update, context)
    elif action == "reject":
        context.args = [op_id]
        await query.edit_message_text(
            text=f"{original}\n\n━━━━━━━━━━━━━━━\n❌ Cancelled."
        )
        await cmd_reject(update, context)
    elif action == "edit":
        op_file = f"Meta/operations/pending/{op_id}.md"
        obs_url = obsidian_url(op_file)
        await query.edit_message_text(
            text=f"{original}\n\n━━━━━━━━━━━━━━━\n✏️ Edit in Obsidian, then tap Send below."
        )
        chat_id = query.message.chat_id
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"Open in Obsidian:\n{obs_url}\n\nWhen done editing:",
            reply_markup=InlineKeyboardMarkup([[
                InlineKeyboardButton("✅ Send edited version", callback_data=f"op_approve_{op_id}"),
                InlineKeyboardButton("❌ Nevermind", callback_data=f"op_reject_{op_id}"),
            ]])
        )
    elif action == "reply":
        context.user_data["op_reply_for"] = op_id
        await query.edit_message_text(
            text=f"{original}\n\n━━━━━━━━━━━━━━━\n✏ Type your response below..."
        )


_notified_ops = set()  # Track which ops we've already pinged about


async def check_and_notify_operations(app):
    """Check for new pending operations and send Telegram notifications.
    Called periodically by the job queue."""
    global _notified_ops
    chat_id = get_allowed_chat_id()
    if not chat_id:
        return

    ops = get_pending_operations()
    for op in ops:
        fname = op.get("_filename", "")
        notify = op.get("notify", "").lower()
        if fname in _notified_ops:
            continue
        if notify != "true":
            continue

        msg = _format_op_notification(op)
        keyboard = _build_op_keyboard(op)
        try:
            await app.bot.send_message(
                chat_id=int(chat_id), text=msg,
                reply_markup=keyboard
            )
            _notified_ops.add(fname)
            logger.info(f"Notified about operation: {fname}")
        except Exception as e:
            logger.error(f"Failed to notify about operation {fname}: {e}")


async def run_pipeline_and_report(filepath, update, context):
    """Run the voice pipeline and report results back to Telegram."""
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "process-voice-memo.sh"), filepath],
            cwd=VAULT_DIR, capture_output=True, text=True, timeout=600,
        )

        # Check if the pipeline actually succeeded
        if result.returncode != 0:
            error_tail = (result.stderr or result.stdout or "unknown error")[-500:]
            await update.message.reply_text(
                f"⚠️ Pipeline failed (exit {result.returncode}):\n\n"
                f"`{error_tail}`\n\n"
                f"Audio is saved in _drop — will retry."
            )
            logger.error(f"Pipeline failed: {error_tail}")
            return

        # Report what was extracted
        changed = get_recent_changes()
        people = [f for f in changed if "People/" in f]
        actions = [f for f in changed if "Actions/" in f]
        concepts = [f for f in changed if "Concepts/" in f]
        events = [f for f in changed if "Events/" in f]
        places = [f for f in changed if "Places/" in f]
        decisions = [f for f in changed if "Decisions/" in f]

        parts = []
        if people:
            names = [os.path.basename(f)[:-3] for f in people]
            parts.append(f"👤 {len(people)} people: {', '.join(names)}")
        if actions:
            names = [os.path.basename(f)[:-3] for f in actions]
            parts.append(f"✅ {len(actions)} actions: {', '.join(names)}")
        if concepts:
            parts.append(f"💡 {len(concepts)} concepts")
        if events:
            parts.append(f"📅 {len(events)} events")
        if places:
            parts.append(f"📍 {len(places)} places")
        if decisions:
            parts.append(f"⚖️ {len(decisions)} decisions")

        if parts:
            msg = "Done! Extracted:\n\n" + "\n".join(parts)
        else:
            msg = "Processed, but nothing new was extracted. Might have updated existing entries."

        await update.message.reply_text(msg)

        # Push any pending review items that agents flagged
        review_count = await push_pending_reviews(update, context)
        if review_count:
            await update.message.reply_text(
                f"👆 {review_count} item(s) need your verification. "
                f"Reply \"confirm\", \"correct [field] [value]\", or \"skip\"."
            )

        # Ask about gaps in recently created actions
        gaps = get_actions_needing_input()
        if gaps:
            # Pick the most recent / most incomplete one
            worst = max(gaps, key=lambda x: len(x[1]))
            name, missing = worst
            await update.message.reply_text(
                f"Quick question: \"{name}\" is missing {', '.join(missing)}.\n\n"
                f"Reply by voice or text to fill in the gaps."
            )

    except subprocess.TimeoutExpired:
        await update.message.reply_text("Pipeline is still running (>10 min). Check Obsidian later.")
    except Exception as e:
        await update.message.reply_text(f"Pipeline error: {e}")
        logger.error(f"Pipeline error: {e}")


async def run_extractor_on_note(note_path, update):
    """Run the extractor on a text note and report back."""
    try:
        rel_path = os.path.relpath(note_path, VAULT_DIR)
        result = await asyncio.to_thread(
            subprocess.run,
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-extractor.sh"), rel_path],
            cwd=VAULT_DIR, capture_output=True, text=True, timeout=300,
        )

        changed = get_recent_changes()
        if changed:
            names = [os.path.basename(f)[:-3] for f in changed[:5]]
            await update.message.reply_text(
                f"Processed your note. Updated: {', '.join(names)}"
            )
        else:
            await update.message.reply_text("Noted and processed. ✓")

    except Exception as e:
        logger.error(f"Extractor error on text note: {e}")


async def try_action_routing(text, update, context):
    """Route action-oriented commands that don't need note-saving.

    Decompose, status checks, email drafts — these are commands, not thoughts.
    Returns True if handled, False if not detected.
    """
    text_lower = text.strip().lower()

    # --- Decomposer: break down requests ---
    decompose_patterns = [
        "break down ", "decompose ", "break up ", "split up ",
        "steps for ", "plan out ", "how do i do ",
    ]
    for pattern in decompose_patterns:
        if text_lower.startswith(pattern):
            query = text[len(pattern):].strip()
            match = find_action_by_name(query)
            if match:
                action_path, action_name = match
                await react(update.message, "👀")
                await update.message.reply_text(f"📋 Breaking down: {action_name}... ~30 seconds")
                result = await run_agent_command(
                    update, "run-task-enricher.sh", ["--decompose", action_path],
                    timeout=300, loading_msg="📋 Decomposing..."
                )
                if result and result.returncode == 0:
                    await update.message.reply_text(f"📋 Done! Use /steps {action_name} to see the plan.")
                    await react(update.message, "👍")
                elif result:
                    await update.message.reply_text(f"❌ Failed:\n{(result.stderr or '')[-500:]}")
                    await react(update.message, "👎")
                return True
            break

    # --- Status: how's X going ---
    status_patterns = [
        "how's ", "hows ", "status of ", "progress on ",
        "where are we on ", "update on ", "what's happening with ",
    ]
    for pattern in status_patterns:
        if text_lower.startswith(pattern):
            query = text[len(pattern):].strip().rstrip("?")
            if query:
                await react(update.message, "👀")
                result = await run_agent_command(
                    update, "run-task-enricher.sh", ["--status", query],
                    timeout=30, loading_msg="📊 Checking..."
                )
                if result and result.returncode == 0 and result.stdout.strip():
                    await update.message.reply_text(result.stdout.strip())
                    return True
            break

    # --- Email: send email to ---
    email_patterns = ["email ", "send email to ", "write to ", "draft email "]
    for pattern in email_patterns:
        if text_lower.startswith(pattern):
            query = text[len(pattern):].strip()
            match = find_action_by_name(query)
            if match:
                action_path, action_name = match
                await react(update.message, "⚡")
                result = await run_agent_command(
                    update, "run-email-workflow.sh", [query],
                    timeout=120, loading_msg="📧 Drafting..."
                )
                if result and result.returncode == 0:
                    op_id = ""
                    for line in (result.stdout or "").splitlines():
                        if "Operation created:" in line:
                            op_id = line.split(":")[-1].strip()
                    msg = "📧 Email draft created!"
                    if op_id:
                        msg += f"\n\nIt'll appear for approval, or use:\n/approve {op_id}"
                    await update.message.reply_text(msg)
                    await react(update.message, "👍")
                else:
                    await update.message.reply_text(f"❌ Couldn't draft email:\n{(result.stderr or '')[-300:]}")
                    await react(update.message, "👎")
                return True
            break

    return False


async def try_advisor_routing(text, update, context):
    """Detect if the Advisor should engage with this text.

    Called AFTER the note is already saved. This runs ON TOP of saving.
    The note exists in Inbox regardless — Advisor engagement is a bonus.

    Triggers on:
      - Direct questions (should I, what if, why, ends in ?)
      - Strategic thinking (I'm thinking about, I want to, considering)
      - Decision signals (I need to decide, torn between, not sure whether)
      - Strategy keywords (strategy, roadmap, plan for, grow, scale)

    Returns True if Advisor engaged (so caller skips the 👍 reaction).
    """
    text_lower = text.strip().lower()

    # Skip very short messages — not worth Advisor's time
    if len(text) < 25:
        return False

    # --- Direct questions ---
    question_starters = [
        "should i ", "what if ", "how do i ", "how should i ", "why ",
        "is it worth ", "what do you think ", "what's the best ", "what would you ",
        "would it be ", "do you think ", "can you help me think ",
        "i'm not sure ", "i don't know if ", "help me decide ",
    ]
    is_question = any(text_lower.startswith(q) for q in question_starters) or (
        text_lower.endswith("?") and len(text) > 20
    )

    # --- Strategic thinking / musing ---
    thinking_patterns = [
        "i'm thinking about ", "i've been thinking ", "i want to ",
        "i need to decide ", "i'm considering ", "i'm torn between ",
        "not sure whether ", "wondering if ", "debating whether ",
        "maybe i should ", "i could ", "one option is ",
        "the thing is ", "my concern is ", "the problem is ",
        "i realized ", "it occurred to me ", "i just had an idea ",
    ]
    is_thinking = any(text_lower.startswith(p) for p in thinking_patterns)

    # --- Reflective / emotional / debrief patterns ---
    # These catch conversation debriefs, self-reflection, emotional processing.
    # e.g. "I had a talk with Lars...", "I have a lot on my mind", "I'm bad at..."
    reflective_starters = [
        "i have a lot on my mind", "i had a talk with ", "i just talked to ",
        "i met with ", "i spoke with ", "i had a meeting with ",
        "i had a conversation with ", "i just met ",
        "i'm bad at ", "i struggle with ", "i need to work on ",
        "i keep failing at ", "i'm frustrated ", "i'm worried ",
        "i feel ", "i've been struggling ", "i can't seem to ",
        "i'm disappointed ", "i'm stuck ", "i don't know what to do ",
        "i'm overwhelmed ", "honestly ", "the truth is ",
        "i need to be honest ", "i'm avoiding ", "i've been avoiding ",
        "i procrastinated ", "i keep putting off ",
    ]
    is_reflective = any(text_lower.startswith(p) for p in reflective_starters)

    # --- Deep personal/work reflections (longer text with introspective signals) ---
    # Catches messages like "...I didn't do much. Obviously uncool. I am really bad
    # on keeping deadlines..." — long text with personal pronouns + self-assessment
    reflective_keywords = [
        "deadline", "performance", "quarter", "review",
        "motivation", "accountability", "procrastinat",
        "struggle", "failing", "avoidance", "avoided",
        "emotionally", "logically", "honest with myself",
        "i need to change", "wake-up call", "reality check",
        "not proud", "disappointed in myself", "uncool",
        "burned out", "stressed", "anxious", "overwhelmed",
        "talk with my boss", "talk with lars", "salary",
        "i care", "i don't care", "don't really care",
    ]
    is_deep_reflection = (
        len(text) > 120
        and sum(1 for kw in reflective_keywords if kw in text_lower) >= 2
    )

    # --- Strategy keywords (longer text only, to avoid false positives) ---
    strategy_keywords = [
        "strategy", "roadmap", "business model", "revenue", "pipeline",
        "positioning", "competitive", "market", "pricing", "scaling",
        "freelance rate", "income goal", "career", "pivot",
    ]
    is_strategic = len(text) > 60 and any(kw in text_lower for kw in strategy_keywords)

    # --- Explicit strategy asks ---
    strategy_starters = [
        "strategy for ", "strategize ", "plan for ", "roadmap for ",
        "how can i increase ", "how can i grow ", "how to scale ",
    ]
    is_strategy_cmd = any(text_lower.startswith(s) for s in strategy_starters)

    if not (is_question or is_thinking or is_reflective or is_deep_reflection
            or is_strategic or is_strategy_cmd):
        return False

    # Advisor should engage! Show the progression.
    # Deep reflections and strategy get the full treatment; questions get quick mode.
    mode = "strategy" if (is_strategy_cmd or is_strategic or is_deep_reflection or is_reflective) else "ask"
    loading = "🧠 Analyzing strategy..." if mode == "strategy" else "🧠 Thinking..."

    session_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-{mode}"
    context.user_data["advisor_session"] = {
        "id": session_id,
        "topic": text,
        "last_active": datetime.now(),
        "turn": 1,
    }

    # Try SDK streaming first for fast response
    streamed = await send_streaming_response(
        update, text, agent="ADVISOR", mode=mode, placeholder=loading
    )

    if streamed:
        await react(update.message, "🧠")
        return True

    # Fallback: subprocess via run-advisor.sh
    result = await run_agent_command(
        update, "run-advisor.sh", [mode, text, "--session-id", session_id],
        timeout=300, loading_msg=loading
    )

    if result and result.returncode == 0 and result.stdout.strip():
        response = result.stdout.strip()
        response = convert_wikilinks(response)
        if len(response) > 3800:
            response = response[:3800] + "\n\n... (see full in Obsidian)"
        response += '\n\n(say "done" to end this conversation)'
        try:
            await update.message.reply_text(response, parse_mode="Markdown")
        except Exception:
            await update.message.reply_text(response)
        await react(update.message, "🧠")
    elif result:
        logger.error(f"Advisor failed (exit={result.returncode}): {(result.stderr or '')[-300:]}")
        await update.message.reply_text("🧠 Advisor hit an issue. Your note is saved — try /ask to re-engage.")
        await react(update.message, "👎")

    return True


def should_triage(text: str) -> bool:
    """Should this message go through Advisor triage?

    Returns False for trivial messages that don't warrant an AI call.
    Triage is the lightweight Advisor pass (~$0.01, 5-15s) that acknowledges
    with personality and decides what agents to trigger.
    """
    text_stripped = text.strip()
    text_lower = text_stripped.lower()

    # Skip very short messages
    if len(text_stripped) < 15:
        return False

    # Skip single/two-word responses without question mark
    if len(text_stripped.split()) <= 2 and not text_stripped.endswith("?"):
        return False

    # Skip pure emoji (rough heuristic: all non-alphanumeric non-space)
    if all(not c.isalnum() for c in text_stripped.replace(" ", "")):
        return False

    return True


async def run_advisor_triage(text: str, update: Update, context: ContextTypes.DEFAULT_TYPE, note_path: str = ""):
    """Run the Advisor in triage mode — lightweight, fast acknowledgment + routing.

    Returns True if triage engaged, False if it failed (caller falls back).
    Triage decides: acknowledge like a person, trigger agents, optionally upgrade to conversation.

    Tries SDK streaming first for fast first-token latency.
    Falls back to subprocess (run-advisor.sh) if SDK unavailable.
    """
    # Try SDK streaming for triage (fast first-token)
    streamed = await send_streaming_response(
        update, text, agent="ADVISOR", mode="triage", placeholder="🧠 ..."
    )
    if streamed:
        await react(update.message, "🧠")
        # For triage, also check if we should extract entities
        if note_path and len(text) >= 50:
            asyncio.create_task(_run_extractor_bg(note_path, update))
        return True

    # Fallback: subprocess via run-advisor.sh
    try:
        result = await run_agent_command(
            update, "run-advisor.sh", ["triage", text],
            timeout=90, loading_msg="🧠 ...", loading_emoji="🧠",
        )

        if not result or result.returncode != 0:
            return False

        stdout = result.stdout.strip() if result.stdout else ""
        if not stdout:
            return False

        # Parse response and triggers from stdout
        # run-advisor.sh triage outputs: response text, then ---ADVISOR_TRIGGERS--- block
        response = stdout
        triggers = []

        if "---ADVISOR_TRIGGERS---" in stdout:
            parts = stdout.split("---ADVISOR_TRIGGERS---", 1)
            response = parts[0].strip()
            trigger_block = parts[1].split("---END_TRIGGERS---")[0].strip() if "---END_TRIGGERS---" in parts[1] else parts[1].strip()
            try:
                triggers = json.loads(trigger_block)
            except (json.JSONDecodeError, ValueError):
                triggers = []

        # Strip any remaining delimiter artifacts from Claude's output
        for delim in ["---RESPONSE---", "---TRIGGERS---", "---END---"]:
            response = response.replace(delim, "").strip()

        # Send the response if non-empty
        if response:
            # Convert [[wikilinks]] to clickable Obsidian deep links
            response = convert_wikilinks(response)

            # Send with Markdown for clickable links; fallback to plain text
            async def _send_md(text):
                try:
                    await update.message.reply_text(text, parse_mode="Markdown")
                except Exception:
                    await update.message.reply_text(text)

            # Split long messages for Telegram (4096 char limit)
            if len(response) > 4000:
                split_at = response.rfind("\n\n", 0, 3900)
                if split_at == -1:
                    split_at = 3900
                await _send_md(response[:split_at])
                await asyncio.sleep(0.2)
                await _send_md(response[split_at:].strip())
            else:
                await _send_md(response)
            await react(update.message, "🧠")

        # Execute triggers in background
        for trigger in triggers:
            trig_type = trigger.get("type", "")
            trig_value = trigger.get("value", "")

            if trig_type == "EXTRACT" and note_path:
                # Run extractor on the saved note
                asyncio.create_task(_run_extractor_bg(note_path, update))

            elif trig_type == "MODE_SWITCH" and trig_value.lower() == "deep":
                # Upgrade to full conversation
                session_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-strategy"
                context.user_data["advisor_session"] = {
                    "id": session_id,
                    "topic": text[:80],
                    "last_active": datetime.now(),
                    "turn": 1,
                }
                # The response already contains the Advisor's initial deep engagement

            elif trig_type == "RESEARCH":
                asyncio.create_task(_run_bg_script("run-researcher.sh", [trig_value]))

            elif trig_type == "DECOMPOSE":
                asyncio.create_task(_run_bg_script("run-task-enricher.sh", ["--decompose", trig_value]))

            elif trig_type == "CREATE_ACTION":
                asyncio.create_task(_run_bg_script("run-advisor.sh", ["ask", f"CREATE_ACTION trigger: {trig_value}"]))

        return True

    except Exception as e:
        logger.error(f"Advisor triage failed: {e}")
        return False


async def _run_extractor_bg(note_path: str, update: Update):
    """Run extractor in background (fire-and-forget)."""
    try:
        await run_extractor_on_note(note_path, update)
    except Exception as e:
        logger.error(f"Background extractor failed: {e}")


async def _run_bg_script(script: str, args: list):
    """Run a script in background via asyncio.to_thread (fire-and-forget)."""
    try:
        cmd = ["/bin/bash", os.path.join(SCRIPTS_DIR, script)] + args
        await asyncio.to_thread(
            subprocess.run, cmd, capture_output=True, text=True, timeout=300
        )
    except Exception as e:
        logger.error(f"Background script {script} failed: {e}")


def _get_allowed_chat_id():
    """Get the allowed chat ID as integer."""
    return int(ALLOWED_CHAT_ID) if ALLOWED_CHAT_ID else None


async def check_agent_feedback(context: ContextTypes.DEFAULT_TYPE):
    """Read agent feedback queue and optionally route to Advisor for commentary.

    Runs every 60 seconds via job_queue. Reads new JSONL entries since last bookmark,
    filters for notify=true, and sends Advisor commentary to Telegram.
    """
    feedback_path = os.path.join(VAULT_DIR, "Meta", "agent-feedback.jsonl")
    bookmark_path = os.path.join(VAULT_DIR, "Meta", ".feedback-bookmark")

    if not os.path.exists(feedback_path):
        return

    # Read bookmark (last processed line number) — with corruption guard
    last_line = 0
    if os.path.exists(bookmark_path):
        try:
            last_line = int(open(bookmark_path).read().strip())
        except (ValueError, OSError):
            last_line = 0

    try:
        lines = open(feedback_path).readlines()
    except OSError:
        return

    new_entries = lines[last_line:]
    if not new_entries:
        return

    # Update bookmark
    try:
        with open(bookmark_path, "w") as f:
            f.write(str(len(lines)))
    except OSError:
        pass

    # Filter for notify=true entries
    notable = []
    for line in new_entries:
        try:
            entry = json.loads(line.strip())
            if entry.get("notify"):
                notable.append(entry)
        except (json.JSONDecodeError, ValueError):
            continue

    if not notable:
        return

    # Quiet hours check: don't send feedback between 22:00-08:00
    now = datetime.now()
    if now.hour >= 22 or now.hour < 8:
        logger.info(f"Agent feedback queued during quiet hours ({len(notable)} entries)")
        # Roll back bookmark so we pick these up after quiet hours
        try:
            with open(bookmark_path, "w") as f:
                f.write(str(last_line))
        except OSError:
            pass
        return

    # Batch: combine summaries if multiple notable events
    summaries = "\n".join(e.get("summary", "") for e in notable if e.get("summary"))
    if not summaries:
        return

    # Route to Advisor feedback mode for intelligent commentary
    try:
        cmd = ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-advisor.sh"), "feedback", summaries]
        result = await asyncio.to_thread(
            subprocess.run, cmd, capture_output=True, text=True, timeout=60
        )

        chat_id = _get_allowed_chat_id()
        if not chat_id:
            return

        if result and result.returncode == 0 and result.stdout.strip():
            # Advisor had something worth saying
            await context.bot.send_message(chat_id=chat_id, text=result.stdout.strip())
        # If empty response, Advisor decided nothing was worth commenting on — silence is fine
    except Exception as e:
        logger.error(f"Agent feedback routing failed: {e}")


# ── Voice Pipeline Progress Poller ──────────────────────────────────────

# Stage definitions for the evolving progress message
VOICE_STAGES = {
    "received":    {"idx": 0, "icon": "📥", "bar": "▓░░░░", "text": "Received"},
    "transcribed": {"idx": 1, "icon": "📝", "bar": "▓▓░░░", "text": "Transcribed"},
    "extracting":  {"idx": 2, "icon": "🔍", "bar": "▓▓▓░░", "text": "Extracting"},
    "extracted":   {"idx": 3, "icon": "✅", "bar": "▓▓▓▓░", "text": "Extracted"},
    "reviewing":   {"idx": 4, "icon": "🔎", "bar": "▓▓▓▓░", "text": "Reviewing"},
    "complete":    {"idx": 5, "icon": "✅", "bar": "▓▓▓▓▓", "text": "Done!"},
    "failed":      {"idx": -1, "icon": "❌", "bar": "▓▓░░░", "text": "Failed"},
}

# Track which progress files we've already sent the final message for
_voice_progress_done = set()


def _build_progress_text(progress: dict) -> str:
    """Build the evolving progress message text from a progress dict."""
    stage = progress.get("stage", "received")
    stage_info = VOICE_STAGES.get(stage, VOICE_STAGES["received"])

    # Build the stage icons line
    done_stages = []
    current_idx = stage_info["idx"]

    for s_name in ["received", "transcribed", "extracting", "extracted", "reviewing"]:
        s = VOICE_STAGES[s_name]
        if s["idx"] < current_idx:
            done_stages.append(f"{s['icon']}✅")
        elif s["idx"] == current_idx and stage not in ("complete", "failed"):
            done_stages.append(f"{s['icon']}⏳")

    icons = " ".join(done_stages)
    bar = stage_info["bar"]

    if stage == "complete":
        # Final message with summary
        summary = progress.get("summary", "")
        duration = progress.get("duration", "?")
        word_count = progress.get("word_count", "")
        wc_str = f" ({word_count} words)" if word_count else ""

        text = f"📥✅ 📝✅ 🔍✅ 🔎✅ ▓▓▓▓▓ Done!{wc_str}\n"
        if summary:
            text += f"\n{summary}"
        return text

    elif stage == "failed":
        reason = progress.get("reason", "unknown")
        return f"{icons} ❌ Pipeline failed\nReason: {reason}"

    elif stage == "transcribed":
        word_count = progress.get("word_count", "?")
        return f"{icons} {bar} Transcribed ({word_count} words). Extracting..."

    elif stage == "extracting":
        return f"{icons} {bar} Extracting people, events, actions..."

    elif stage == "extracted":
        return f"{icons} {bar} Extracted. Reviewing quality..."

    elif stage == "reviewing":
        return f"{icons} {bar} Reviewing extraction..."

    else:
        duration = progress.get("duration", "?")
        return f"{icons} {bar} Received ({duration}s). Transcribing..."


async def poll_voice_progress(context: ContextTypes.DEFAULT_TYPE):
    """Poll voice progress files and update Telegram status messages.

    Runs every 10 seconds. Reads Meta/.voice-progress/*.json files,
    edits the corresponding Telegram message with current pipeline stage.
    Cleans up after completion.
    """
    progress_dir = os.path.join(VAULT_DIR, "Meta", ".voice-progress")
    if not os.path.exists(progress_dir):
        return

    try:
        files = [f for f in os.listdir(progress_dir) if f.endswith(".json")]
    except OSError:
        return

    for fname in files:
        fpath = os.path.join(progress_dir, fname)
        slug = os.path.splitext(fname)[0]

        # Skip already-completed ones
        if slug in _voice_progress_done:
            # Clean up old completed files (>5 min old)
            try:
                age = time.time() - os.path.getmtime(fpath)
                if age > 300:
                    os.remove(fpath)
                    _voice_progress_done.discard(slug)
            except OSError:
                pass
            continue

        try:
            with open(fpath, "r") as f:
                progress = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        message_id = progress.get("message_id")
        chat_id = progress.get("chat_id")
        stage = progress.get("stage", "received")

        if not message_id or not chat_id:
            continue

        # Build the progress text
        new_text = _build_progress_text(progress)

        # Stale detection: if progress file is >45 min old and still early stage,
        # mark as failed (avoids stuck "received" forever when pipeline crashes)
        try:
            file_age = time.time() - os.path.getmtime(fpath)
            if file_age > 2700 and stage in ("received", "transcribing"):
                progress["stage"] = "failed"
                progress["details"] = {"error": f"Stale: stuck at '{stage}' for >{int(file_age//60)} min"}
                stage = "failed"
                with open(fpath, "w") as f:
                    json.dump(progress, f)
                logger.warning(f"Marked stale voice progress as failed: {slug} (age={int(file_age)}s)")
        except OSError:
            pass

        # Only edit if stage changed (avoid redundant edits)
        last_stage = progress.get("_last_displayed_stage")
        if last_stage == stage:
            continue

        try:
            await context.bot.edit_message_text(
                text=new_text,
                chat_id=chat_id,
                message_id=message_id,
            )
            # Mark this stage as displayed
            progress["_last_displayed_stage"] = stage
            with open(fpath, "w") as f:
                json.dump(progress, f)
        except Exception as e:
            # Message might have been deleted or rate limited
            logger.debug(f"Voice progress edit failed for {slug}: {e}")

        # Mark as done if complete or failed
        if stage in ("complete", "failed"):
            _voice_progress_done.add(slug)


async def try_quick_action(text, update):
    """Handle quick action commands without running the full pipeline.

    Supported patterns:
      "done [action name]"        → marks action as done
      "drop [action name]"        → marks action as dropped
      "add [action name]"         → creates new action
      "[action] - due [date]"     → updates due date
      "[action] - priority [p]"   → updates priority
      "[action] - output [text]"  → updates expected output

    Returns True if handled, False if not a quick action.
    """
    text_lower = text.strip().lower()

    try:
        actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")

        # --- "done [action]" ---
        if text_lower.startswith("done "):
            query = text.strip()[5:].strip()
            match = find_action_by_name(query)
            if match:
                path, name = match
                content = open(path).read()
                content = re.sub(r'^status:\s*\S+', 'status: done', content, flags=re.MULTILINE)
                with open(path, 'w') as f:
                    f.write(content)
                await update.message.reply_text(f"✅ Done: {name}")
                log_change("Telegram", f"Action marked done: {name}")
                return True
            else:
                await update.message.reply_text(f"Can't find an action matching \"{query}\"")
                return True

        # --- "drop [action]" ---
        if text_lower.startswith("drop "):
            query = text.strip()[5:].strip()
            match = find_action_by_name(query)
            if match:
                path, name = match
                content = open(path).read()
                content = re.sub(r'^status:\s*\S+', 'status: dropped', content, flags=re.MULTILINE)
                with open(path, 'w') as f:
                    f.write(content)
                await update.message.reply_text(f"❌ Dropped: {name}")
                log_change("Telegram", f"Action dropped: {name}")
                return True
            else:
                await update.message.reply_text(f"Can't find an action matching \"{query}\"")
                return True

        # --- "add [action name]" ---
        if text_lower.startswith("add "):
            action_text = text.strip()[4:].strip()

            # Parse optional fields: "add call dentist - due 2026-04-01 - priority high"
            name_part = action_text
            due = ""
            priority = "medium"
            output = ""

            if " - " in action_text:
                parts = action_text.split(" - ")
                name_part = parts[0].strip()
                for part in parts[1:]:
                    part = part.strip()
                    if part.lower().startswith("due "):
                        due = part[4:].strip()
                    elif part.lower().startswith("priority "):
                        priority = part[9:].strip()
                    elif part.lower().startswith("output "):
                        output = part[7:].strip()

            # Create the action file
            safe_name = name_part.replace("/", "-").replace("\\", "-")
            action_path = os.path.join(actions_dir, f"{safe_name}.md")

            if os.path.exists(action_path):
                await update.message.reply_text(f"Action \"{safe_name}\" already exists. Update it instead.")
                return True

            content = f"---\ntype: action\nname: {safe_name}\nstatus: open\npriority: {priority}\nsource: human\nfirst_mentioned: {datetime.now().strftime('%Y-%m-%d')}\n"
            if due:
                content += f"due: {due}\n"
            content += f"owner: \"[[Usman Kotwal]]\"\n"
            if output:
                content += f"output: \"{output}\"\n"
            content += f"mentions:\n  - Telegram {datetime.now().strftime('%Y-%m-%d')}\nlinked:\n  - \"[[Usman Kotwal]]\"\n---\n\n# {safe_name}\n\nCreated via Telegram.\n"

            os.makedirs(actions_dir, exist_ok=True)
            with open(action_path, 'w') as f:
                f.write(content)

            reply = f"✅ Action created: {safe_name}"
            if due:
                reply += f"\n⏰ Due: {due}"
            reply += f"\n🔵 Priority: {priority}"
            await update.message.reply_text(reply)
            log_change("Telegram", f"Action created: {safe_name}")
            return True

        # --- "[action] - due [date]" or "[action] - priority [p]" ---
        if " - " in text and any(kw in text_lower for kw in ["due ", "priority ", "output "]):
            parts = text.split(" - ", 1)
            query = parts[0].strip()
            updates_str = parts[1].strip()

            match = find_action_by_name(query)
            if match:
                path, name = match
                content = open(path).read()
                changes = []

                for update_part in updates_str.split(" - "):
                    update_part = update_part.strip()
                    if update_part.lower().startswith("due "):
                        val = update_part[4:].strip()
                        if re.search(r'^due:', content, re.MULTILINE):
                            content = re.sub(r'^due:\s*.*$', f'due: {val}', content, flags=re.MULTILINE)
                        else:
                            content = content.replace('status:', f'due: {val}\nstatus:', 1)
                        changes.append(f"⏰ due → {val}")
                    elif update_part.lower().startswith("priority "):
                        val = update_part[9:].strip()
                        content = re.sub(r'^priority:\s*.*$', f'priority: {val}', content, flags=re.MULTILINE)
                        changes.append(f"🔵 priority → {val}")
                    elif update_part.lower().startswith("output "):
                        val = update_part[7:].strip()
                        if re.search(r'^output:', content, re.MULTILINE):
                            content = re.sub(r'^output:\s*.*$', f'output: "{val}"', content, flags=re.MULTILINE)
                        else:
                            content = content.replace('status:', f'output: "{val}"\nstatus:', 1)
                        changes.append(f"🎯 output → {val}")

                if changes:
                    with open(path, 'w') as f:
                        f.write(content)
                    await update.message.reply_text(f"Updated: {name}\n" + "\n".join(changes))
                    log_change("Telegram", f"Action updated: {name} — {', '.join(changes)}")
                    return True

        return False

    except Exception as e:
        await update.message.reply_text(f"Error handling action: {e}")
        return True


def find_action_by_name(query):
    """Fuzzy-find an action by name. Returns (path, name) or None."""
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    if not os.path.exists(actions_dir):
        return None

    query_lower = query.lower().strip()
    best_match = None
    best_score = 0

    for f in os.listdir(actions_dir):
        if not f.endswith(".md"):
            continue
        name = f[:-3]
        name_lower = name.lower()

        # Exact match
        if name_lower == query_lower:
            return (os.path.join(actions_dir, f), name)

        # Substring match
        if query_lower in name_lower or name_lower in query_lower:
            score = len(query_lower) / max(len(name_lower), 1)
            if score > best_score:
                best_score = score
                best_match = (os.path.join(actions_dir, f), name)

        # Word overlap
        query_words = set(query_lower.split())
        name_words = set(name_lower.split())
        overlap = len(query_words & name_words)
        if overlap > 0:
            score = overlap / max(len(query_words), len(name_words))
            if score > best_score:
                best_score = score
                best_match = (os.path.join(actions_dir, f), name)

    if best_score >= 0.4:
        return best_match
    return None


# --- Task Enricher ---

ACTIONS_DIR = os.path.join(VAULT_DIR, "Canon", "Actions")


def parse_action(filepath):
    """Parse an action file and return a dict of its metadata + content."""
    try:
        content = open(filepath).read()
        meta = {"path": filepath, "name": os.path.basename(filepath)[:-3], "raw": content}

        # Parse frontmatter
        if content.startswith("---"):
            end = content.index("---", 3)
            fm = content[3:end]
            body = content[end + 3:].strip()
            meta["body"] = body

            for line in fm.strip().split("\n"):
                if ":" in line and not line.strip().startswith("-"):
                    key, val = line.split(":", 1)
                    key = key.strip()
                    val = val.strip().strip("'\"")
                    if val:
                        meta[key] = val

            # Parse mentions array
            mentions = []
            in_mentions = False
            for line in fm.strip().split("\n"):
                if line.strip().startswith("mentions:"):
                    in_mentions = True
                    continue
                if in_mentions:
                    if line.strip().startswith("- "):
                        mentions.append(line.strip()[2:].strip().strip("'\""))
                    else:
                        in_mentions = False
            meta["mentions_list"] = mentions

        return meta
    except Exception as e:
        logger.warning(f"Error parsing action {filepath}: {e}")
        return None


def score_action(action):
    """Calculate priority score for an action (higher = more urgent).

    score = (days_until_due < 3 ? 50 : 0)
          + (mention_count * 10)
          + (days_since_creation > 7 ? 20 : 0)
          + (priority == "high" ? 30 : priority == "medium" ? 15 : 0)
          + (has_enrichment ? 0 : 25)
    """
    score = 0
    today = datetime.now().date()

    # Due date urgency
    due = action.get("due", "")
    if due:
        try:
            due_date = datetime.strptime(due, "%Y-%m-%d").date()
            days_until = (due_date - today).days
            if days_until < 0:
                score += 70  # Overdue!
            elif days_until < 3:
                score += 50
            elif days_until < 7:
                score += 25
        except ValueError:
            pass

    # Mention frequency
    mention_count = len(action.get("mentions_list", []))
    score += mention_count * 10

    # Age penalty
    first = action.get("first_mentioned", "")
    if first:
        try:
            first_date = datetime.strptime(first, "%Y-%m-%d").date()
            age_days = (today - first_date).days
            if age_days > 7:
                score += 20
        except ValueError:
            pass

    # Priority
    p = action.get("priority", "")
    if p == "high":
        score += 30
    elif p == "medium":
        score += 15

    # Un-enriched bonus (needs attention)
    if "## Enrichment" not in action.get("raw", ""):
        score += 25

    return score


def is_snoozed(action):
    """Check if an action is currently snoozed."""
    snooze = action.get("snooze_until", "")
    if snooze:
        try:
            snooze_date = datetime.strptime(snooze, "%Y-%m-%d").date()
            if datetime.now().date() < snooze_date:
                return True
        except ValueError:
            pass
    return False


def get_all_open_actions():
    """Get all open/in-progress actions, parsed and scored."""
    if not os.path.exists(ACTIONS_DIR):
        return []

    actions = []
    for f in os.listdir(ACTIONS_DIR):
        if not f.endswith(".md"):
            continue
        path = os.path.join(ACTIONS_DIR, f)
        action = parse_action(path)
        if not action:
            continue
        status = action.get("status", "")
        if status not in ("open", "in-progress"):
            continue
        if is_snoozed(action):
            continue
        action["score"] = score_action(action)
        actions.append(action)

    actions.sort(key=lambda a: a["score"], reverse=True)
    return actions


def get_stale_actions():
    """Find actions open >7 days OR mentioned 3+ times with no progress."""
    if not os.path.exists(ACTIONS_DIR):
        return []

    today = datetime.now().date()
    stale = []

    for f in os.listdir(ACTIONS_DIR):
        if not f.endswith(".md"):
            continue
        path = os.path.join(ACTIONS_DIR, f)
        action = parse_action(path)
        if not action:
            continue
        status = action.get("status", "")
        if status not in ("open", "in-progress"):
            continue

        is_stale = False
        reason = ""

        # Check age
        first = action.get("first_mentioned", "")
        if first:
            try:
                first_date = datetime.strptime(first, "%Y-%m-%d").date()
                age = (today - first_date).days
                if age > 7:
                    is_stale = True
                    reason = f"Open for {age} days"
            except ValueError:
                pass

        # Check mention frequency
        mentions = len(action.get("mentions_list", []))
        if mentions >= 3:
            is_stale = True
            reason = f"Mentioned {mentions} times, still open"

        if is_stale:
            action["stale_reason"] = reason
            stale.append(action)

    return stale


def format_action_card(action, include_enrichment=False):
    """Format an action as a Telegram message card."""
    name = action.get("name", "?")
    status = action.get("status", "open")
    priority = action.get("priority", "?")
    due = action.get("due", "")
    output = action.get("output", "")
    score = action.get("score", 0)
    mentions = len(action.get("mentions_list", []))

    # Status icon
    p_icon = {"high": "🔴", "medium": "🟡", "low": "🔵"}.get(priority, "⚪")

    lines = [f"🎯 {name}"]
    if due:
        # Calculate days until
        try:
            due_date = datetime.strptime(due, "%Y-%m-%d").date()
            days = (due_date - datetime.now().date()).days
            if days < 0:
                lines.append(f"⏰ OVERDUE by {abs(days)} days ({due})")
            elif days == 0:
                lines.append(f"⏰ Due TODAY ({due})")
            elif days <= 3:
                lines.append(f"⏰ Due in {days} days ({due})")
            else:
                lines.append(f"⏰ Due: {due}")
        except ValueError:
            lines.append(f"⏰ Due: {due}")

    lines.append(f"{p_icon} Priority: {priority}")

    if output:
        lines.append(f"🎯 Output: {output}")

    if mentions > 0:
        lines.append(f"💬 Mentioned {mentions} time(s)")

    # Extract next step from enrichment if present
    next_step = action.get("next_step", "")
    if not next_step and "## Enrichment" in action.get("raw", ""):
        body = action.get("raw", "")
        enrichment_start = body.index("## Enrichment")
        enrichment = body[enrichment_start:]
        for line in enrichment.split("\n"):
            if line.strip().startswith("**Next step"):
                next_step = line.split(":", 1)[1].strip() if ":" in line else ""
                break

    if next_step:
        lines.append(f"\n▶️ Next: {next_step}")
    else:
        lines.append(f"\n▶️ Next: not enriched yet — /enrich {name}")

    return "\n".join(lines)


def snooze_action(action_path, days):
    """Add snooze_until field to action frontmatter."""
    content = open(action_path).read()
    snooze_date = (datetime.now().date() + timedelta(days=days)).strftime("%Y-%m-%d")

    if "snooze_until:" in content:
        content = re.sub(r'^snooze_until:.*$', f'snooze_until: {snooze_date}', content, flags=re.MULTILINE)
    else:
        # Insert before closing ---
        content = content.replace("\n---\n", f"\nsnooze_until: {snooze_date}\n---\n", 1)

    with open(action_path, 'w') as f:
        f.write(content)
    return snooze_date


# --- Task Enricher Command Handlers ---

async def cmd_next(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show the single most actionable thing right now. ADHD-friendly: ONE thing."""
    if not is_authorized(update):
        return

    actions = get_all_open_actions()
    if not actions:
        await update.message.reply_text("No open actions. Either you're done, or you're avoiding. 😏")
        return

    top = actions[0]
    card = format_action_card(top)

    # Footer with quick actions
    name = top["name"]
    card += f"\n\n/done {name}\n/snooze {name} 3"

    await update.message.reply_text(card)


async def cmd_enrich(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Enrich a specific action with next steps and context."""
    if not is_authorized(update):
        return

    query = " ".join(context.args) if context.args else ""
    if not query:
        # Show top 3 un-enriched actions
        actions = get_all_open_actions()
        unenriched = [a for a in actions if "## Enrichment" not in a.get("raw", "")]
        if not unenriched:
            await update.message.reply_text("All actions are enriched. Nice.")
            return

        lines = ["Actions needing enrichment:\n"]
        for a in unenriched[:5]:
            lines.append(f"  • {a['name']} (score: {a['score']})")
        lines.append(f"\nUse: /enrich [action name]")
        await update.message.reply_text("\n".join(lines))
        return

    match = find_action_by_name(query)
    if not match:
        await update.message.reply_text(f"Can't find action matching \"{query}\"")
        return

    path, name = match
    action = parse_action(path)
    if not action:
        await update.message.reply_text(f"Error reading action: {name}")
        return

    # Generate enrichment by analyzing the action and finding related Canon entries
    await update.message.reply_text(f"Enriching \"{name}\"... looking up contacts and context.")

    # Find linked people and their contact info
    linked_info = []
    body = action.get("raw", "")
    # Find all [[Name]] references
    people_refs = re.findall(r'\[\[([^\]]+)\]\]', body)
    people_dir = os.path.join(VAULT_DIR, "Canon", "People")

    for ref in people_refs:
        # Handle display links [[Full Name|Display]]
        actual_name = ref.split("|")[0]
        person_path = os.path.join(people_dir, f"{actual_name}.md")
        if os.path.exists(person_path):
            person_content = open(person_path).read()
            phone = ""
            email = ""
            for line in person_content.split("\n"):
                if line.startswith("phone:"):
                    phone = line.split(":", 1)[1].strip().strip("'\"")
                elif line.startswith("email:"):
                    email = line.split(":", 1)[1].strip().strip("'\"")
            if phone or email:
                info = f"📇 {actual_name}"
                if phone:
                    info += f" — 📞 {phone}"
                if email:
                    info += f" — ✉️ {email}"
                linked_info.append(info)

    # Build enrichment message
    card = format_action_card(action, include_enrichment=True)
    if linked_info:
        card += "\n\n--- Contacts ---\n" + "\n".join(linked_info)

    # Suggest what's missing
    missing = []
    if not action.get("due"):
        missing.append("due date")
    if not action.get("output"):
        missing.append("expected output")
    if "## Enrichment" not in body:
        missing.append("enrichment (next steps)")

    if missing:
        card += f"\n\n⚠️ Missing: {', '.join(missing)}"
        card += f"\nUpdate: \"{name} - due 2026-04-15 - output done\""

    await update.message.reply_text(card)


async def cmd_stale(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show all stale actions — things you keep mentioning but never do."""
    if not is_authorized(update):
        return

    stale = get_stale_actions()
    if not stale:
        await update.message.reply_text("No stale actions. You're on top of things. 💪")
        return

    lines = [f"⚠️ Stale Actions ({len(stale)}):\n"]
    for a in stale:
        name = a.get("name", "?")
        reason = a.get("stale_reason", "")
        lines.append(f"  • {name}")
        lines.append(f"    {reason}")
        lines.append(f"    → /act {name} | /snooze {name} 7 | /drop {name}")
        lines.append("")

    await update.message.reply_text("\n".join(lines))


async def cmd_snooze(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Snooze an action for N days. /snooze driving license 7"""
    if not is_authorized(update):
        return

    args = context.args if context.args else []
    if len(args) < 2:
        await update.message.reply_text("Usage: /snooze [action name] [days]\nExample: /snooze driving license 7")
        return

    # Last arg is days, rest is action name
    try:
        days = int(args[-1])
    except ValueError:
        await update.message.reply_text("Last argument must be a number of days.")
        return

    query = " ".join(args[:-1])
    match = find_action_by_name(query)
    if not match:
        await update.message.reply_text(f"Can't find action matching \"{query}\"")
        return

    path, name = match
    snooze_date = snooze_action(path, days)
    await update.message.reply_text(f"😴 Snoozed: {name}\nWill resurface after {snooze_date}")
    log_change("Telegram", f"Action snoozed: {name} until {snooze_date}")


# --- Operator Commands ---

async def cmd_ops(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show pending operations waiting for approval."""
    if not is_authorized(update):
        return

    ops = get_pending_operations()
    if not ops:
        # Also show recent completed
        completed = get_completed_operations(3)
        if completed:
            lines = ["No pending operations.\n\nRecent:"]
            for op in completed:
                status = op.get("status", "?")
                subject = op.get("subject", op.get("name", "?"))
                lines.append(f"  ✓ {subject} ({status})")
            await update.message.reply_text("\n".join(lines))
        else:
            await update.message.reply_text("No operations pending or recent.")
        return

    lines = [f"📋 {len(ops)} pending operation(s):\n"]
    for op in ops:
        msg = _format_op_notification(op)
        lines.append(msg)
        lines.append("")

    await update.message.reply_text("\n".join(lines))


async def cmd_approve(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Approve a pending operation. /approve op-id"""
    if not is_authorized(update):
        return

    args = context.args if context.args else []
    if not args:
        await update.message.reply_text("Usage: /approve <op-id>\nSee /ops for pending operations.")
        return

    op_id = " ".join(args)

    # Find matching operation
    ops = get_pending_operations()
    match = None
    for op in ops:
        fname = op.get("_filename", "")
        file_op_id = op.get("op_id", fname.replace(".md", ""))
        if op_id in file_op_id or op_id in fname:
            match = op
            break

    if not match:
        await update.message.reply_text(f"No pending operation matching \"{op_id}\".\nUse /ops to see what's pending.")
        return

    fname = match["_filename"]
    path = match["_path"]
    subject = match.get("subject", match.get("name", fname))
    op_type = match.get("type", "unknown")

    # Idempotency: check file still exists in pending/ (another /approve may have moved it)
    if not os.path.exists(path):
        await update.message.reply_text(f"Already processed: {subject}")
        return

    # Move-based atomicity: pending/ → executing/ (prevents double-tap race)
    os.makedirs(OPS_EXECUTING_DIR, exist_ok=True)
    executing_path = os.path.join(OPS_EXECUTING_DIR, fname)
    try:
        os.rename(path, executing_path)
    except FileNotFoundError:
        await update.message.reply_text(f"Already processed: {subject}")
        return

    # Update file: status → executing
    try:
        content = open(executing_path).read()
        content = content.replace("status: pending", "status: executing")
        content += f"\napproved_date: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"
        with open(executing_path, "w") as f:
            f.write(content)
    except Exception as e:
        logger.error(f"Failed to update operation file: {e}")

    # Execute based on type
    if op_type == "email":
        to_email = match.get("to", "")
        email_subject = match.get("subject", subject)
        send_script = os.path.join(SCRIPTS_DIR, "send-email.sh")

        if to_email and os.path.exists(send_script):
            await update.message.reply_text(f"📤 Sending: {subject}...")
            try:
                result = await asyncio.to_thread(
                    subprocess.run,
                    ["/bin/bash", send_script, to_email, email_subject, executing_path],
                    capture_output=True, text=True, timeout=30,
                )
                if result.returncode == 0:
                    # Success: move to completed with status executed
                    try:
                        content = open(executing_path).read()
                        content = content.replace("status: executing", "status: executed")
                        content += f"\nexecuted_date: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"
                        with open(executing_path, "w") as f:
                            f.write(content)
                    except Exception:
                        pass
                    _move_executing_to_completed(executing_path, fname)
                    # Update source action if we can find it
                    _mark_action_operated(match)
                    await update.message.reply_text(
                        f"✅ Email Sent — {to_email}: {email_subject}\n"
                        f"Action updated: {match.get('source_action', '?')}"
                    )
                else:
                    # Failure: move back to pending, alert user
                    error_msg = (result.stderr or result.stdout or "unknown error")[:200]
                    _move_executing_to_pending(executing_path, fname)
                    await update.message.reply_text(
                        f"⚠️ Send failed: {error_msg}\n"
                        f"Op kept in pending. Try /approve {op_id} again."
                    )
            except subprocess.TimeoutExpired:
                _move_executing_to_pending(executing_path, fname)
                await update.message.reply_text(
                    f"⚠️ Send timed out after 30s.\n"
                    f"Op kept in pending. Try /approve {op_id} again."
                )
            except Exception as e:
                _move_executing_to_pending(executing_path, fname)
                await update.message.reply_text(
                    f"⚠️ Send failed: {str(e)[:200]}\n"
                    f"Op kept in pending. Try /approve {op_id} again."
                )
        else:
            # No send script or no email — fallback to old behavior
            _move_executing_to_completed(executing_path, fname)
            await update.message.reply_text(f"✅ Approved: {subject}")
    elif op_type == "calendar":
        # Calendar operations: call calendar-create.sh
        cal_script = os.path.join(SCRIPTS_DIR, "calendar-create.sh")
        if os.path.exists(cal_script):
            await update.message.reply_text(f"📅 Creating calendar event: {subject}...")
            try:
                result = await asyncio.to_thread(
                    subprocess.run,
                    ["/bin/bash", cal_script, executing_path],
                    capture_output=True, text=True, timeout=30,
                )
                if result.returncode == 0:
                    try:
                        content = open(executing_path).read()
                        content = content.replace("status: executing", "status: executed")
                        content += f"\nexecuted_date: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"
                        with open(executing_path, "w") as f:
                            f.write(content)
                    except Exception:
                        pass
                    _move_executing_to_completed(executing_path, fname)
                    _mark_action_operated(match)
                    await update.message.reply_text(f"📅 Calendar event created: {subject}")
                else:
                    error_msg = (result.stderr or result.stdout or "unknown error")[:200]
                    _move_executing_to_pending(executing_path, fname)
                    await update.message.reply_text(
                        f"⚠️ Calendar create failed: {error_msg}\n"
                        f"Op kept in pending. Try /approve {op_id} again."
                    )
            except subprocess.TimeoutExpired:
                _move_executing_to_pending(executing_path, fname)
                await update.message.reply_text(f"⚠️ Calendar create timed out. Try /approve {op_id} again.")
            except Exception as e:
                _move_executing_to_pending(executing_path, fname)
                await update.message.reply_text(f"⚠️ Calendar create failed: {str(e)[:200]}")
        else:
            _move_executing_to_completed(executing_path, fname)
            await update.message.reply_text(f"📅 Approved: {subject}\n(calendar-create.sh not found, marked as approved)")
    else:
        # Non-email/calendar ops: just mark approved and move to completed
        _move_executing_to_completed(executing_path, fname)
        await update.message.reply_text(f"✅ Approved: {subject}")

    log_change("Operator", f"Operation approved: {subject}")


async def cmd_reject(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Reject a pending operation. /reject op-id"""
    if not is_authorized(update):
        return

    args = context.args if context.args else []
    if not args:
        await update.message.reply_text("Usage: /reject <op-id>")
        return

    op_id = " ".join(args)

    ops = get_pending_operations()
    match = None
    for op in ops:
        fname = op.get("_filename", "")
        file_op_id = op.get("op_id", fname.replace(".md", ""))
        if op_id in file_op_id or op_id in fname:
            match = op
            break

    if not match:
        await update.message.reply_text(f"No pending operation matching \"{op_id}\".")
        return

    fname = match["_filename"]
    path = match["_path"]
    subject = match.get("subject", match.get("name", fname))

    # Update and move
    try:
        content = open(path).read()
        content = content.replace("status: pending", "status: rejected")
        content += f"\nrejected_date: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"
        with open(path, "w") as f:
            f.write(content)
    except Exception as e:
        logger.error(f"Failed to update operation file: {e}")

    _move_to_completed(path, fname)
    await update.message.reply_text(f"❌ Rejected: {subject}\nOperation cancelled.")
    log_change("Operator", f"Operation rejected: {subject}")


async def cmd_ops_log(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show recent completed operations. /ops-log [count]"""
    if not is_authorized(update):
        return

    args = context.args if context.args else []
    limit = 10
    if args and args[0].isdigit():
        limit = min(int(args[0]), 25)

    completed = get_completed_operations(limit)
    if not completed:
        await update.message.reply_text("No completed operations yet.")
        return

    lines = [f"📋 Last {len(completed)} operations:\n"]
    for op in completed:
        status = op.get("status", "?")
        subject = op.get("subject", op.get("name", "?"))
        op_type = op.get("type", "")
        date = op.get("approved_date", op.get("rejected_date", op.get("executed_date", "")))
        icon = {"approved": "✅", "rejected": "❌", "executed": "⚡"}.get(status, "❓")
        type_icon = {"email": "📧", "calendar": "📅", "document": "📄"}.get(op_type, "🔧")
        lines.append(f"{icon} {type_icon} {subject}")
        if date:
            lines.append(f"   {status} on {date}")
        lines.append("")

    await update.message.reply_text("\n".join(lines))


REVIEW_QUEUE_DIR = os.path.join(VAULT_DIR, "Meta", "review-queue")


def parse_review_queue():
    """Parse all individual review-queue files from Meta/review-queue/ directory.
    Each file is a markdown file with YAML frontmatter."""
    if not os.path.exists(REVIEW_QUEUE_DIR):
        return []
    items = []
    for f in sorted(os.listdir(REVIEW_QUEUE_DIR)):
        if not f.endswith(".md"):
            continue
        path = os.path.join(REVIEW_QUEUE_DIR, f)
        try:
            content = open(path).read()
            item = {"_filename": f, "_path": path}
            # Parse frontmatter
            if content.startswith("---"):
                end = content.index("---", 3)
                fm = content[3:end].strip()
                for line in fm.split("\n"):
                    if ":" in line and not line.strip().startswith("-"):
                        key, val = line.split(":", 1)
                        item[key.strip()] = val.strip().strip('"').strip("'")
            # Grab body after frontmatter for context
            if "---" in content[3:]:
                body = content[content.index("---", 3) + 3:].strip()
                # Keep enough body for full context (Telegram limit is 4096 per message)
                item["_body"] = body[:2000]
            items.append(item)
        except Exception as e:
            logger.warning(f"Failed to parse review item {f}: {e}")
    return items


def mark_review_item_status(filepath, new_status):
    """Update the status field in a review-queue file."""
    try:
        content = open(filepath).read()
        if re.search(r'^status:', content, re.MULTILINE):
            content = re.sub(r'^status:\s*.*$', f'status: {new_status}', content, flags=re.MULTILINE)
        else:
            # Add status after first ---
            content = content.replace("---\n", f"---\nstatus: {new_status}\n", 1)
        with open(filepath, 'w') as f:
            f.write(content)
    except Exception as e:
        logger.error(f"Failed to mark review item: {e}")


def resolve_review_item(filepath, action="approved"):
    """Move a resolved review item to a 'resolved' state or delete it."""
    mark_review_item_status(filepath, action)


# --- Inline Keyboard Review Flow ---

def build_review_keyboard(item_id, item_type="generic"):
    """Build inline keyboard buttons for a review item.
    Button labels adapt to item type so the user knows exactly what each button does."""
    if item_type == "fact-check":
        return InlineKeyboardMarkup([
            [
                InlineKeyboardButton("✅ Looks right", callback_data=f"review_approve_{item_id}"),
                InlineKeyboardButton("✏️ I'll correct it", callback_data=f"review_voice_{item_id}"),
            ],
            [
                InlineKeyboardButton("⏭️ Later", callback_data=f"review_skip_{item_id}"),
            ],
        ])
    elif item_type == "approval":
        return InlineKeyboardMarkup([
            [
                InlineKeyboardButton("✅ Go ahead", callback_data=f"review_approve_{item_id}"),
                InlineKeyboardButton("🚫 Don't do this", callback_data=f"review_reject_{item_id}"),
            ],
            [
                InlineKeyboardButton("✏️ Yes but change...", callback_data=f"review_voice_{item_id}"),
                InlineKeyboardButton("⏭️ Later", callback_data=f"review_skip_{item_id}"),
            ],
        ])
    elif item_type == "human-input":
        return InlineKeyboardMarkup([
            [
                InlineKeyboardButton("✏️ Type my answer", callback_data=f"review_voice_{item_id}"),
                InlineKeyboardButton("🎤 Voice answer", callback_data=f"review_voicerec_{item_id}"),
            ],
            [
                InlineKeyboardButton("✅ Already handled", callback_data=f"review_approve_{item_id}"),
                InlineKeyboardButton("⏭️ Later", callback_data=f"review_skip_{item_id}"),
            ],
        ])
    else:
        return InlineKeyboardMarkup([
            [
                InlineKeyboardButton("✅ Got it", callback_data=f"review_approve_{item_id}"),
                InlineKeyboardButton("✏️ Reply", callback_data=f"review_voice_{item_id}"),
            ],
            [
                InlineKeyboardButton("⏭️ Later", callback_data=f"review_skip_{item_id}"),
            ],
        ])


def format_review_message(item):
    """Format a review item as a clear, decision-framed Telegram message.
    Returns (message_text, item_type) where item_type drives button labels.

    Design principles:
    - Lead with THE ASK: what decision or input is needed, in one line
    - Then CONTEXT: enough to decide without opening Obsidian
    - Then WHAT HAPPENS: what the system will do with your answer
    - Never dump raw file content — always frame it
    """
    name = item.get('name', item.get('_filename', '?'))
    body = item.get('_body', '').strip()
    urgency = item.get('urgency', '')
    reason = item.get('reason', '')

    # Extract structured sections from body
    sections = {}
    current_key = None
    current_lines = []
    for line in body.split('\n'):
        if line.startswith('## '):
            if current_key:
                sections[current_key] = '\n'.join(current_lines).strip()
            current_key = line[3:].strip().lower()
            current_lines = []
        elif line.startswith('# '):
            continue  # skip H1
        else:
            current_lines.append(line)
    if current_key:
        sections[current_key] = '\n'.join(current_lines).strip()

    # Find key sections by fuzzy matching
    what_needs = ""
    why_section = ""
    recommended = ""
    summary = ""
    next_steps = ""
    for key, val in sections.items():
        if 'what needs' in key or 'what need' in key:
            what_needs = val
        elif key.startswith('why'):
            why_section = val
        elif 'recommend' in key or 'suggested' in key:
            recommended = val
        elif 'summary' in key:
            summary = val
        elif 'next step' in key:
            next_steps = val

    # Classify item type — drives both message framing and button labels
    name_lower = name.lower()
    body_lower = body.lower()

    if any(w in name_lower for w in ['confirm', 'verify', 'resolve', 'birth', 'check']):
        item_type = "fact-check"
    elif any(w in body_lower for w in ['voice memo', 'record what', 'human-only', 'add a short', 'only you know']):
        item_type = "human-input"
    elif any(w in name_lower for w in ['cleanup', 'legacy', 'delete', 'remove']):
        item_type = "approval"
    elif any(w in name_lower for w in ['approve', 'sync']):
        item_type = "approval"
    else:
        item_type = "generic"

    # --- Build message by type ---
    urgency_icon = {"high": "🔴", "medium": "🟡", "low": "⚪"}.get(urgency, "")
    msg = ""

    if item_type == "fact-check":
        msg += f"❓ {urgency_icon} I need you to check something\n\n"
        msg += f"━━━ {name} ━━━\n\n"
        if what_needs:
            msg += f"{what_needs}\n\n"
        if why_section:
            msg += f"💡 {why_section}\n\n"
        msg += "👇 If something's wrong, tap ✏️ and type the correct answer.\n"

    elif item_type == "human-input":
        msg += f"🎤 {urgency_icon} Only you know this\n\n"
        msg += f"━━━ {name} ━━━\n\n"
        if what_needs:
            msg += f"{what_needs}\n\n"
        if recommended:
            msg += f"💡 Suggestion: {recommended}\n\n"
        if why_section:
            msg += f"Why: {why_section}\n\n"
        msg += "👇 Send a voice or text message with your answer.\n"

    elif item_type == "approval":
        msg += f"⚡ {urgency_icon} Approve this action?\n\n"
        msg += f"━━━ {name} ━━━\n\n"
        # For approval items, explain WHAT will happen if approved
        if summary:
            msg += f"{summary}\n\n"
        if what_needs:
            msg += f"📋 What happens if you approve:\n{what_needs}\n\n"
        elif next_steps:
            msg += f"📋 What happens if you approve:\n{next_steps}\n\n"
        elif reason:
            msg += f"📋 {reason}\n\n"
        if why_section:
            msg += f"💡 {why_section}\n\n"
        # For big items, include enough detail
        if not summary and not what_needs and body:
            body_clean = '\n'.join(
                line for line in body.split('\n')
                if not line.startswith('# ')
            ).strip()
            msg += f"{body_clean[:1200]}\n\n"
        msg += "👇 Approve to let the system proceed, or reject to cancel.\n"

    else:
        msg += f"📋 {urgency_icon} Review needed\n\n"
        msg += f"━━━ {name} ━━━\n\n"
        if what_needs:
            msg += f"{what_needs}\n\n"
        if recommended:
            msg += f"➡️ Suggested: {recommended}\n\n"
        if why_section:
            msg += f"💡 {why_section}\n\n"
        # Fallback: show body
        if not what_needs and body:
            body_clean = '\n'.join(
                line for line in body.split('\n')
                if not line.startswith('# ')
            ).strip()
            msg += f"{body_clean[:1200]}\n"

    # Trim to Telegram limit
    if len(msg) > 3800:
        msg = msg[:3800] + "\n\n…(open in Obsidian for full details)"

    return msg.strip(), item_type


async def handle_review_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle inline button presses for review items."""
    query = update.callback_query
    await query.answer()

    if not is_authorized(update):
        return

    data = query.data  # e.g. "review_approve_alex-birth-year"
    parts = data.split("_", 2)  # ["review", "action", "item_id"]
    if len(parts) < 3:
        return

    action = parts[1]
    item_id = parts[2]

    # Find the matching review-queue file
    items = parse_review_queue()
    target = None
    for item in items:
        fname = item.get("_filename", "").replace(".md", "")
        if item_id in fname:
            target = item
            break

    if not target:
        await query.edit_message_text(f"Item not found: {item_id}")
        return

    filepath = target.get("_path", "")
    name = target.get("name", target.get("_filename", ""))

    # IMPORTANT: Keep the original message context visible.
    # ADHD brain needs to see WHAT was decided, not just that something was decided.
    # We preserve the full original text and append the outcome at the bottom.
    original = query.message.text or ""
    # Trim to leave room for outcome (Telegram 4096 char limit)
    if len(original) > 3500:
        original = original[:3500] + "\n..."

    if action == "approve":
        resolve_review_item(filepath, "approved")
        await query.edit_message_text(
            f"{original}\n\n"
            f"━━━━━━━━━━━━━━━\n"
            f"✅ You approved this. The system will act on it next cycle."
        )
        log_change("Telegram", f"Review approved: {name}")

    elif action == "reject":
        resolve_review_item(filepath, "rejected")
        await query.edit_message_text(
            f"{original}\n\n"
            f"━━━━━━━━━━━━━━━\n"
            f"🚫 Rejected. Won't be acted on."
        )
        log_change("Telegram", f"Review rejected: {name}")

    elif action == "skip":
        await query.edit_message_text(
            f"{original}\n\n"
            f"━━━━━━━━━━━━━━━\n"
            f"⏭️ Skipped. Will come back later."
        )

    elif action in ("voice", "voicerec"):
        # Set context so next text or voice message is treated as review input
        context.user_data["review_reply_for"] = filepath
        context.user_data["review_reply_name"] = name

        await query.edit_message_text(
            f"{original}\n\n"
            f"━━━━━━━━━━━━━━━\n"
            f"✏ Type or 🎤 voice your answer below. "
            f"It'll be saved to this item."
        )


async def push_pending_reviews(update, context):
    """Send all pending review items to Telegram with inline buttons."""
    items = [i for i in parse_review_queue()
             if i.get('status', 'pending') in ('pending', '')]
    if not items:
        return 0

    for item in items:
        item_id = item.get('_filename', '').replace('.md', '')
        msg, item_type = format_review_message(item)
        keyboard = build_review_keyboard(item_id, item_type)
        await update.message.reply_text(msg, reply_markup=keyboard)
        mark_review_item_status(item.get('_path', ''), 'sent')

    return len(items)


# --- Command Handlers ---

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """First contact or deep link entry point.

    Deep links from email/Telegram buttons:
      /start approve_<op_id>  → approve operation
      /start reject_<op_id>   → reject operation
      /start reply_<op_id>    → set up text reply to operation
      /start done_<action>    → mark action done
      /start steps_<action>   → show decomposer status
      /start review_<item_id> → show review item
      /start next             → show next action
      /start actions          → list actions
    """
    chat_id = update.effective_chat.id

    # Handle deep link parameters
    args = context.args if context.args else []
    if args and is_authorized(update):
        payload = args[0]

        if payload.startswith("approve_"):
            op_id = payload[len("approve_"):]
            context.args = [op_id]
            await cmd_approve(update, context)
            return

        elif payload.startswith("reject_"):
            op_id = payload[len("reject_"):]
            context.args = [op_id]
            await cmd_reject(update, context)
            return

        elif payload.startswith("reply_"):
            op_id = payload[len("reply_"):]
            # Set up for text reply — next message goes to this operation
            context.user_data["op_reply_for"] = op_id
            # Find the operation to show context
            ops = get_pending_operations()
            op_subject = op_id
            for op in ops:
                if op.get("op_id", "") == op_id or op_id in op.get("_filename", ""):
                    op_subject = op.get("subject", op.get("name", op_id))
                    break
            await update.message.reply_text(
                f"💬 Replying to: {op_subject}\n\n"
                f"Type your response below — it'll be saved to the operation."
            )
            return

        elif payload.startswith("done_"):
            action_name = payload[len("done_"):].replace("_", " ")
            match = find_action_by_name(action_name)
            if match:
                path, name = match
                content = open(path).read()
                content = re.sub(r'^status:\s*\S+', 'status: done', content, flags=re.MULTILINE)
                with open(path, 'w') as f:
                    f.write(content)
                await update.message.reply_text(f"✅ Done: {name}")
                log_change("Telegram", f"Action marked done: {name}")
            else:
                await update.message.reply_text(f"Can't find action matching: {action_name}")
            return

        elif payload.startswith("steps_"):
            action_query = payload[len("steps_"):].replace("_", " ")
            context.args = action_query.split()
            await cmd_steps(update, context)
            return

        elif payload == "next":
            context.args = []
            await cmd_next(update, context)
            return

        elif payload == "actions":
            context.args = []
            await cmd_actions(update, context)
            return

        elif payload.startswith("review_"):
            # Show a specific review item
            context.args = []
            await cmd_review(update, context)
            return

    # Already authorized? Show a welcome, not the setup message
    if is_authorized(update):
        await update.message.reply_text(
            "👋 Hey! Just talk to me — ask a question, give a voice memo, or say what's on your mind.\n\n"
            "Type /help for all commands."
        )
        return

    # First time setup — show chat ID
    await update.message.reply_text(
        f"Hey! Your chat ID is: {chat_id}\n\n"
        f"Save this to ~/.vault-bot-chat-id or set VAULT_BOT_CHAT_ID={chat_id}\n\n"
        f"Then restart the bot. After that, only you can talk to me."
    )
    if not ALLOWED_CHAT_ID:
        chat_id_file = os.path.expanduser("~/.vault-bot-chat-id")
        with open(chat_id_file, "w") as f:
            f.write(str(chat_id))
        logger.info(f"Auto-saved chat ID {chat_id} to {chat_id_file}")


async def cmd_briefing(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Send today's briefing summary."""
    if not is_authorized(update):
        return

    try:
        await react(update.message, "⚡")
        await typing(update)

        today = datetime.now().strftime("%Y-%m-%d")
        briefing_path = os.path.join(VAULT_DIR, "Inbox", f"{today} - Daily Briefing.md")

        if not os.path.exists(briefing_path):
            # Generate it
            await asyncio.to_thread(
                subprocess.run,
                ["/bin/bash", os.path.join(SCRIPTS_DIR, "daily-briefing.sh")],
                cwd=VAULT_DIR,
                timeout=60,
            )

        if os.path.exists(briefing_path):
            content = open(briefing_path).read()
            # Strip frontmatter for cleaner Telegram display
            if content.startswith("---"):
                end = content.index("---", 3)
                content = content[end + 3:].strip()
            # Telegram message limit is 4096 chars
            if len(content) > 4000:
                content = content[:4000] + "\n\n... (truncated, see full in Obsidian)"
            await update.message.reply_text(content)
            await react(update.message, "👍")
        else:
            await update.message.reply_text("Couldn't generate briefing. Check logs.")
            await react(update.message, "👎")
    except Exception as e:
        await update.message.reply_text(f"Error: {e}")
        await react(update.message, "👎")


async def cmd_actions(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """List open actions — formatted to make Linear blush."""
    if not is_authorized(update):
        return

    try:
        await react(update.message, "⚡")
        await typing(update)
        actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
        high, medium, low, unset = [], [], [], []

        if os.path.exists(actions_dir):
            for f in sorted(os.listdir(actions_dir)):
                if not f.endswith(".md"):
                    continue
                path = os.path.join(actions_dir, f)
                content = open(path).read()
                if "status: open" not in content and "status: in-progress" not in content:
                    continue

                name = f[:-3]
                status = "in-progress" if "status: in-progress" in content else "open"

                # Extract fields
                due = ""
                owner = ""
                priority = ""
                for line in content.split("\n"):
                    if line.startswith("due:"):
                        due = line.split(":", 1)[1].strip().strip("'\"")
                    elif line.startswith("priority:"):
                        priority = line.split(":", 1)[1].strip().strip("'\"")
                    elif line.startswith("owner:"):
                        owner = line.split(":", 1)[1].strip().strip("'\"").replace("[[", "").replace("]]", "")

                # Status icon
                if status == "in-progress":
                    s_icon = "◑"
                else:
                    s_icon = "○"

                # Build line
                due_str = f"  ⏰ {due}" if due else ""
                owner_str = f"  → {owner}" if owner else ""

                entry = {
                    "name": name,
                    "line": f"{s_icon} {name}{due_str}{owner_str}",
                    "priority": priority,
                }

                if priority == "high":
                    high.append(entry)
                elif priority == "medium":
                    medium.append(entry)
                elif priority == "low":
                    low.append(entry)
                else:
                    unset.append(entry)

        total = len(high) + len(medium) + len(low) + len(unset)
        if total == 0:
            await update.message.reply_text("No open actions. Suspicious. 🤔")
            return

        lines = [f"━━━ Actions ({total}) ━━━\n"]

        if high:
            lines.append("🔴 URGENT")
            for a in high:
                lines.append(f"   {a['line']}")
            lines.append("")

        if medium:
            lines.append("🟡 NEXT UP")
            for a in medium:
                lines.append(f"   {a['line']}")
            lines.append("")

        if low:
            lines.append("🔵 LATER")
            for a in low:
                lines.append(f"   {a['line']}")
            lines.append("")

        if unset:
            lines.append("⚪ NEEDS PRIORITY")
            for a in unset:
                lines.append(f"   {a['line']}")
            lines.append("")

        # Footer with stats
        done_count = 0
        if os.path.exists(actions_dir):
            for f in os.listdir(actions_dir):
                if f.endswith(".md"):
                    c = open(os.path.join(actions_dir, f)).read()
                    if "status: done" in c:
                        done_count += 1

        lines.append(f"━━━ {done_count} done · {total} open ━━━")

        await update.message.reply_text("\n".join(lines))
    except Exception as e:
        await update.message.reply_text(f"Error: {e}")


async def cmd_changelog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show recent changelog entries."""
    if not is_authorized(update):
        return

    try:
        if os.path.exists(CHANGELOG):
            content = open(CHANGELOG).read()
            # Get last 30 lines
            lines = content.strip().split("\n")
            recent = "\n".join(lines[-30:])
            await update.message.reply_text(f"Recent changes:\n\n{recent}")
        else:
            await update.message.reply_text("No changelog yet.")
    except Exception as e:
        await update.message.reply_text(f"Error: {e}")


async def cmd_think(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Trigger the Thinker agent with an optional topic."""
    if not is_authorized(update):
        return

    try:
        topic = " ".join(context.args) if context.args else ""
        topic_str = f" on '{topic}'" if topic else ""

        await update.message.reply_text(f"Running Thinker{topic_str}... this takes a minute.")

        cmd = ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-thinker.sh")]
        if topic:
            cmd.append(topic)

        result = await asyncio.to_thread(
            subprocess.run, cmd, cwd=VAULT_DIR, capture_output=True, text=True, timeout=300
        )

        if result.returncode == 0:
            await update.message.reply_text(f"Thinker done{topic_str}. Check Meta/AI-Reflections/ in Obsidian.")
        else:
            await update.message.reply_text(f"Thinker had issues:\n{result.stderr[-500:]}")
    except Exception as e:
        await update.message.reply_text(f"Error: {e}")


async def cmd_email(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Draft an email from a Canon/Action. Usage: /email Follow up with Moyo"""
    if not is_authorized(update):
        return

    try:
        action_query = " ".join(context.args) if context.args else ""
        if not action_query:
            await update.message.reply_text(
                "Usage: /email <action name>\n"
                "Example: /email Follow up with Moyo\n\n"
                "I'll find the action, look up the recipient, draft the email in your voice, "
                "and show you the draft for approval."
            )
            return

        await react(update.message, "⚡")
        await typing(update)

        result = await asyncio.to_thread(
            subprocess.run,
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-email-workflow.sh"), action_query],
            cwd=VAULT_DIR,
            capture_output=True,
            text=True,
            timeout=120,
        )

        if result.returncode == 0:
            await react(update.message, "👍")
            # Extract op_id from output for direct link
            op_id = ""
            for line in result.stdout.splitlines():
                if "Operation created:" in line:
                    op_id = line.split(":")[-1].strip()
                    break
            msg = "📧 Email draft created!"
            if op_id:
                msg += f"\n\nIt'll appear here shortly for approval, or use:\n/approve {op_id}"
            await update.message.reply_text(msg)
        elif result.returncode == 1:
            await react(update.message, "👎")
            await update.message.reply_text(
                f"Couldn't find an action matching \"{action_query}\".\n\n"
                f"Try the exact name from Canon/Actions/."
            )
        elif result.returncode == 2:
            await react(update.message, "🤔")
            await update.message.reply_text(
                "No email address found for the linked person.\n"
                "I created a blocked operation — check Telegram in a moment."
            )
        else:
            await react(update.message, "👎")
            stderr_tail = result.stderr[-300:] if result.stderr else "No error output"
            await update.message.reply_text(f"Email draft failed:\n{stderr_tail}")

    except subprocess.TimeoutExpired:
        await react(update.message, "👎")
        await update.message.reply_text("Email drafting timed out. Claude CLI may be busy.")
    except Exception as e:
        await react(update.message, "👎")
        await update.message.reply_text(f"Error: {e}")


async def cmd_review(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show items needing human review — with inline buttons."""
    if not is_authorized(update):
        return

    try:
        await react(update.message, "⚡")
        await typing(update)
        items = parse_review_queue()
        actionable = [i for i in items
                      if i.get('status', 'pending') in ('pending', '', 'sent')]

        if not actionable:
            await update.message.reply_text("Nothing to review. The vault is clean. ✨")
            return

        await update.message.reply_text(
            f"📋 {len(actionable)} item(s) to review. Tap the buttons below each one."
        )

        for item in actionable:
            item_id = item.get('_filename', '').replace('.md', '')
            msg, item_type = format_review_message(item)
            keyboard = build_review_keyboard(item_id, item_type)
            await update.message.reply_text(msg, reply_markup=keyboard)
            mark_review_item_status(item.get('_path', ''), 'sent')

    except Exception as e:
        await update.message.reply_text(f"Error: {e}")


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show available commands."""
    if not is_authorized(update):
        return

    await update.message.reply_text(
        "Just talk to me naturally. I figure out what you mean.\n\n"
        "💬 Natural language (no slash needed):\n"
        "\"Should I go to that meetup?\" → Advisor\n"
        "\"Strategy for increasing income\" → Deep analysis\n"
        "\"Break down call Waqas\" → Step-by-step plan\n"
        "\"How's the contract stuff going?\" → Status\n"
        "\"Email Lisa about the meeting\" → Draft email\n"
        "\"Done driving license\" → Mark complete\n"
        "\"Add call dentist - due Friday\" → Create action\n\n"
        "📋 Actions:\n"
        "/actions — list open  •  /next — the ONE thing\n"
        "/enrich [action] — contacts & context\n"
        "/stale — things you keep avoiding\n"
        "/snooze [action] [days] — silence it\n\n"
        "🧠 Advisor & Planning:\n"
        "/ask [question] — quick question\n"
        "/strategy [topic] — deep strategic analysis\n"
        "/decompose [action] — break into steps\n"
        "/steps [action] — see the plan\n"
        "/replan [action] [context] — adjust the plan\n\n"
        "🤖 Agents:\n"
        "/briefing — today's briefing\n"
        "/think [topic] — run the Thinker\n"
        "/review — items needing verification\n"
        "/changelog — recent changes\n\n"
        "🔧 Operator:\n"
        "/ops — pending operations\n"
        "/approve [id] — approve & send\n"
        "/reject [id] — cancel\n\n"
        "Or just send:\n"
        "🎤 Voice → full pipeline\n"
        "💬 Long text → saved + extracted\n"
        "📍 Location → attached to next voice"
    )


# --- Message Handlers ---

async def handle_voice(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Voice message → download to _drop and let the watcher own processing.
    If user was replying to a review item, also link the voice to that item."""
    if not is_authorized(update):
        return

    # Check if this voice message is a reply to a review item
    review_path = context.user_data.get("review_reply_for")
    review_name = context.user_data.get("review_reply_name", "")

    try:
        await react(update.message, "👀", "👀 Got it, processing...")

        voice = update.message.voice
        now = datetime.now()
        date_str = now.strftime("%Y-%m-%d")
        time_str = now.strftime("%H%M%S")

        # Build filename with available metadata
        parts = [f"tg_{date_str}_{time_str}"]

        # Attach location if recently shared
        if last_location:
            lat = last_location.get("lat", 0)
            lon = last_location.get("lon", 0)
            parts[0] = f"loc_{lat}_{lon}_{date_str}_{time_str}"
            last_location.clear()

        filename = f"{parts[0]}.ogg"
        filepath = os.path.join(DROP_DIR, filename)

        # Ensure _drop exists
        os.makedirs(DROP_DIR, exist_ok=True)

        # Download the voice file
        file = await voice.get_file()
        await file.download_to_drive(filepath)

        duration = voice.duration

        # If this was a review reply, link it to the review item
        if review_path:
            context.user_data.pop("review_reply_for", None)
            context.user_data.pop("review_reply_name", None)

            try:
                if os.path.exists(review_path):
                    timestamp = now.strftime("%Y-%m-%d %H:%M")
                    reply_section = (
                        f"\n\n## Human Voice Reply ({timestamp})\n"
                        f"Audio file: {filename} ({duration}s)\n"
                        f"Status: awaiting transcription — Whisper will process this, "
                        f"then the Extractor will update linked notes.\n"
                    )
                    with open(review_path, "a") as f:
                        f.write(reply_section)
                    log_change("Telegram", f"Voice reply linked to review: {review_name}")
            except Exception as e:
                logger.error(f"Failed to link voice to review item: {e}")

            await react(update.message, "👍")
            await update.message.reply_text(
                f"🎤 Got your voice reply for: {review_name}\n\n"
                f"Audio saved ({duration}s). The system will:\n"
                f"1. Transcribe it (Whisper)\n"
                f"2. Extract the answer\n"
                f"3. Update the linked notes\n\n"
                f"You'll get a notification when it's processed."
            )
        else:
            # Send progress status message (will be edited as pipeline progresses)
            status_msg = await update.message.reply_text(
                f"📥 ▓░░░░ Received ({duration}s). Transcribing..."
            )
            # Save message_id + slug so pipeline progress can update this message
            slug = os.path.splitext(os.path.basename(filepath))[0]
            progress_dir = os.path.join(VAULT_DIR, "Meta", ".voice-progress")
            os.makedirs(progress_dir, exist_ok=True)
            progress_file = os.path.join(progress_dir, f"{slug}.json")
            try:
                progress_data = {
                    "message_id": status_msg.message_id,
                    "chat_id": update.effective_chat.id,
                    "slug": slug,
                    "stage": "received",
                    "duration": duration,
                    "stages": [{"stage": "received", "ts": datetime.now().isoformat()}],
                }
                with open(progress_file, "w") as pf:
                    json.dump(progress_data, pf)
            except Exception as pe:
                logger.error(f"Failed to save voice progress: {pe}")

        log_change("Telegram", f"Voice message received ({duration}s) → {filename}")
        logger.info(f"Voice saved: {filepath}")

    except Exception as e:
        logger.error(f"Voice handler failed: {e}")
        try:
            await update.message.reply_text(
                f"⚠️ Voice handler failed: {e}\n\n"
                f"Audio may not have been saved. Try sending again."
            )
        except Exception:
            logger.error("Could not even send error message back to Telegram")


async def handle_audio(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Audio file (longer recordings) → save to queue and let watcher process it."""
    if not is_authorized(update):
        return

    try:
        audio = update.message.audio or update.message.document
        if not audio:
            return

        now = datetime.now()
        date_str = now.strftime("%Y-%m-%d")
        time_str = now.strftime("%H%M%S")

        # Try to get original filename, fallback to generated name
        orig_name = getattr(audio, "file_name", None)
        if orig_name:
            filename = f"tg_{date_str}_{orig_name}"
        else:
            filename = f"tg_{date_str}_{time_str}.ogg"

        filepath = os.path.join(DROP_DIR, filename)
        os.makedirs(DROP_DIR, exist_ok=True)

        file = await audio.get_file()
        await file.download_to_drive(filepath)

        await update.message.reply_text("Audio saved in _drop. Processing starts automatically.")
        log_change("Telegram", f"Audio file received → {filename}")
        logger.info(f"Audio saved: {filepath}")

    except Exception as e:
        logger.error(f"Audio handler failed: {e}")
        try:
            await update.message.reply_text(
                f"⚠️ Audio handler failed: {e}\n\nTry sending again."
            )
        except Exception:
            logger.error("Could not send error message back to Telegram")


async def handle_location(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Location shared → store for next voice message."""
    if not is_authorized(update):
        return

    loc = update.message.location
    last_location["lat"] = round(loc.latitude, 6)
    last_location["lon"] = round(loc.longitude, 6)

    await update.message.reply_text(
        f"📍 Location saved ({last_location['lat']}, {last_location['lon']}). "
        f"It'll be attached to your next voice message."
    )


async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Text message → save as quick note to Inbox."""
    if not is_authorized(update):
        return

    text = update.message.text
    if not text or text.startswith("/"):
        return

    # --- Check if this is a reply to an operation (from inline button) ---
    op_reply_id = context.user_data.get("op_reply_for")
    if op_reply_id:
        context.user_data.pop("op_reply_for", None)
        op_path = os.path.join(VAULT_DIR, "Meta", "operations", "pending", f"{op_reply_id}.md")
        if os.path.exists(op_path):
            try:
                # 📥 = saved, waiting for agent pickup
                await react(update.message, "📥", "📥 Saved.")
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
                with open(op_path, "a") as f:
                    f.write(f"\n\n## Human Input ({timestamp})\n{text}\n")
                await update.message.reply_text(
                    f"📥 Saved → waiting for agent pickup.\n"
                    f"Or if it's ready now: /approve {op_reply_id}"
                )
                log_change("Telegram", f"Human input added to operation: {op_reply_id}")
            except Exception as e:
                await update.message.reply_text(f"Error saving reply: {e}")
        else:
            await update.message.reply_text(f"⚠️ Operation {op_reply_id} not found in pending.")
        return

    # --- Check if this is a reply to a review item (from inline button) ---
    review_path = context.user_data.get("review_reply_for")
    if review_path:
        review_name = context.user_data.get("review_reply_name", "item")
        # Clear the flag immediately so it doesn't stick
        context.user_data.pop("review_reply_for", None)
        context.user_data.pop("review_reply_name", None)

        try:
            if os.path.exists(review_path):
                # 📥 = saved, waiting for agent pickup
                await react(update.message, "📥", "📥 Saved.")
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
                reply_section = f"\n\n## Human Reply ({timestamp})\n{text}\n"
                with open(review_path, "a") as f:
                    f.write(reply_section)
                # Build Obsidian deep link for the review item
                rel_path = os.path.relpath(review_path, VAULT_DIR)
                obs_url = obsidian_url(rel_path)
                await update.message.reply_text(
                    f"📥 Saved → agent picks this up next cycle.\n"
                    f"You'll get a notification when it's done.\n\n"
                    f"📎 Open in Obsidian: {obs_url}",
                    disable_web_page_preview=True,
                )
                log_change("Telegram", f"Human reply added to review: {review_name}")
            else:
                await update.message.reply_text(f"Review item file not found: {review_name}")
        except Exception as e:
            await update.message.reply_text(f"Error saving reply: {e}")
        return

    # --- Check for pending decomposer input (one question at a time) ---
    decomposer_input = context.user_data.get("decomposer_input")
    if decomposer_input:
        slug = decomposer_input["slug"]
        parent = decomposer_input.get("parent", "your plan")
        context.user_data.pop("decomposer_input", None)
        try:
            # 📥 = saved, waiting for agent pickup
            await react(update.message, "📥", "📥 Saved.")
            os.makedirs(DECOMPOSER_ANSWERS_DIR, exist_ok=True)
            tmp_path = os.path.join(DECOMPOSER_ANSWERS_DIR, f"{slug}.tmp")
            final_path = os.path.join(DECOMPOSER_ANSWERS_DIR, f"{slug}.md")
            with open(tmp_path, "w") as f:
                f.write(f"---\nslug: {slug}\nanswered: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n---\n\n{text}\n")
            os.rename(tmp_path, final_path)
            await update.message.reply_text(
                f"📥 Saved → executor picks this up next run.\n"
                f"Continuing with: {parent}"
            )
        except Exception as e:
            await update.message.reply_text(f"❌ Error saving answer: {e}")
        return

    # --- Check for active advisor session ---
    advisor_session = context.user_data.get("advisor_session")
    if advisor_session:
        elapsed = (datetime.now() - advisor_session["last_active"]).total_seconds()
        if elapsed > 1800:
            # Session expired
            topic = advisor_session.get("topic", "your question")
            context.user_data.pop("advisor_session", None)
            await update.message.reply_text(
                f"🧠 Our conversation about {topic} timed out.\n"
                f"Pick up where we left off: /ask {topic}"
            )
        elif text.strip().lower() == "done":
            topic = advisor_session.get("topic", "your question")
            context.user_data.pop("advisor_session", None)
            await update.message.reply_text(f"🧠 Session on \"{topic}\" ended. Talk anytime with /ask.")
            return
        else:
            # Route as advisor follow-up
            session_id = advisor_session["id"]
            result = await run_agent_command(
                update, "run-advisor.sh", ["ask", text, "--session-id", session_id],
                timeout=300, loading_msg="🧠 Thinking..."
            )
            if result and result.returncode == 0 and result.stdout.strip():
                response = result.stdout.strip()
                if len(response) > 3800:
                    response = response[:3800] + "\n\n... (see full in Obsidian)"
                advisor_session["last_active"] = datetime.now()
                advisor_session["turn"] = advisor_session.get("turn", 1) + 1
                response += '\n\n(say "done" to end this conversation)'
                await update.message.reply_text(response)
            elif result:
                await update.message.reply_text(f"🧠 Advisor had issues:\n{(result.stderr or '')[-500:]}")
            return

    # Handle review responses (legacy text commands)
    text_lower = text.strip().lower()

    if text_lower == "confirm":
        # Confirm the most recently sent review item
        items = [i for i in parse_review_queue() if i.get('status') == 'sent']
        if items:
            item = items[-1]
            target_file = item.get('file', '')
            file_path = os.path.join(VAULT_DIR, target_file) if target_file else ''
            field = item.get('field', '')
            value = item.get('value', '')

            try:
                if file_path and os.path.exists(file_path) and field:
                    content = open(file_path).read()
                    content = _add_locked_field(content, field)
                    with open(file_path, 'w') as f:
                        f.write(content)

                resolve_review_item(item["_path"], "approved")
                file_name = os.path.basename(target_file) if target_file else item.get("name", "item")
                await update.message.reply_text(
                    f"✅ Confirmed: {file_name}" + (f" → {field} = {value}\nField is now locked." if field else "")
                )

                remaining = [i for i in parse_review_queue() if i.get('status', 'pending') in ('pending', 'sent')]
                if remaining:
                    await update.message.reply_text(f"({len(remaining)} more items to review. Type /review)")
            except Exception as e:
                await update.message.reply_text(f"Error confirming: {e}")
            return

    if text_lower == "skip":
        items = [i for i in parse_review_queue() if i.get('status') == 'sent']
        if items:
            item = items[-1]
            mark_review_item_status(item["_path"], "pending")
            await update.message.reply_text("Skipped. It'll come back later.")
            return

    if text_lower.startswith("correct "):
        parts = text.strip()[8:].split(" ", 1)
        if len(parts) == 2:
            field, new_value = parts[0], parts[1]
            items = [i for i in parse_review_queue() if i.get('status') == 'sent']
            if items:
                item = items[-1]
                target_file = item.get('file', '')
                file_path = os.path.join(VAULT_DIR, target_file) if target_file else ''

                try:
                    if file_path and os.path.exists(file_path):
                        content = open(file_path).read()
                        content = re.sub(
                            rf'^({re.escape(field)}:\s*).*$',
                            rf'\g<1>{new_value}',
                            content,
                            flags=re.MULTILINE
                        )
                        content = _add_locked_field(content, field)
                        with open(file_path, 'w') as f:
                            f.write(content)

                    resolve_review_item(item["_path"], "approved")
                    file_name = os.path.basename(target_file) if target_file else item.get("name", "item")
                    await update.message.reply_text(
                        f"✏️ Corrected: {file_name} → {field} = {new_value}\nField is now locked."
                    )

                    remaining = [i for i in parse_review_queue() if i.get('status', 'pending') in ('pending', 'sent')]
                    if remaining:
                        await update.message.reply_text(f"({len(remaining)} more to review. Type /review)")
                except Exception as e:
                    await update.message.reply_text(f"Error correcting: {e}")
                return

    now = datetime.now()
    date_str = now.strftime("%Y-%m-%d")
    time_str = now.strftime("%H:%M")

    # --- Smart routing (no note-saving) ---
    # Quick actions and status checks don't need note-saving

    # 1. Quick action commands (instant, no pipeline needed)
    #    Patterns: "done [action]", "drop [action]", "add [action]"
    handled = await try_quick_action(text, update)
    if handled:
        return

    # 2. Decompose / status / email commands (action-oriented, not thoughts)
    handled = await try_action_routing(text, update, context)
    if handled:
        return

    # --- Everything below is a "thought" — always save as note first ---
    # Feedback Protocol: 👀 (received) → save → route → 👍 (done)
    await react(update.message, "👀", "📝 Got it.")

    note_path = os.path.join(
        VAULT_DIR, "Inbox", f"{date_str} - Telegram Note.md"
    )
    if os.path.exists(note_path):
        with open(note_path, "a") as f:
            f.write(f"\n\n**{time_str}:** {text}")
    else:
        with open(note_path, "w") as f:
            f.write(f"---\ntype: note\ndate: {date_str}\nsource: human\nstatus: inbox\n---\n\n")
            f.write(f"# Telegram Notes — {date_str}\n\n")
            f.write(f"**{time_str}:** {text}")
    logger.info(f"Text note saved: {note_path}")

    # 3. Advisor triage — the always-on brain
    #    Note is ALREADY saved — Advisor triage runs ON TOP of the saved note.
    #    Triage decides: acknowledge + route (extract, research, mode_switch, etc.)
    advisor_engaged = False
    if should_triage(text):
        advisor_engaged = await run_advisor_triage(text, update, context, note_path=note_path)

    # 4. Fallback: if triage failed or skipped, use old pattern matching + extractor
    if not advisor_engaged:
        # Try old-style advisor routing as fallback
        advisor_engaged = await try_advisor_routing(text, update, context)

    # 5. Run extractor on substantial messages if Advisor didn't already trigger it
    if not advisor_engaged and len(text) >= 50:
        await run_extractor_on_note(note_path, update)

    # 6. Final reaction: done
    if not advisor_engaged:
        await react(update.message, "👍")


# --- Agent Command Helper (DRY: all agent commands use this) ---

DECOMPOSER_INPUT_DIR = os.path.join(VAULT_DIR, "Meta", "decomposer", "pending-input")
DECOMPOSER_ANSWERS_DIR = os.path.join(VAULT_DIR, "Meta", "decomposer", "answers")


async def run_agent_command(
    update: Update,
    script: str,
    args: list = None,
    timeout: int = 300,
    loading_msg: str = "⚡ Working...",
    loading_emoji: str = "⚡",
):
    """Run an agent script via asyncio.to_thread. Handles auth, loading state, errors."""
    if not is_authorized(update):
        return None

    await react(update.message, loading_emoji, loading_msg)
    await typing(update)

    # Use /bin/bash to execute scripts — bypasses macOS com.apple.provenance
    # xattr that blocks direct execution of files created/modified by Claude.
    script_path = os.path.join(SCRIPTS_DIR, script)
    cmd = ["/bin/bash", script_path]
    if args:
        cmd.extend(args)

    try:
        result = await asyncio.to_thread(
            subprocess.run,
            cmd,
            cwd=VAULT_DIR,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result
    except subprocess.TimeoutExpired:
        await update.message.reply_text(
            "⏳ Still thinking... I'll keep working and message you when done."
        )
        # TODO: background the work and notify when done
        return None
    except Exception as e:
        await update.message.reply_text(f"❌ Error: {e}")
        return None


async def send_streaming_response(
    update: Update,
    prompt: str,
    agent: str = "ADVISOR",
    mode: str = "",
    system_prompt: str = "",
    placeholder: str = "🧠 ...",
) -> str:
    """Send a streaming LLM response via progressive Telegram message edits.

    1. Send placeholder message immediately
    2. Stream via Anthropic SDK, editing the message every ~1s
    3. Final edit with complete response + wikilinks

    Returns the complete response text, or empty string on failure.
    Falls back to subprocess (run_agent_command) if SDK is unavailable.
    """
    if not HAS_VAULT_LIB:
        return ""  # Caller should fall back to subprocess

    # Check if runtime is API-based (claude). If not, can't stream.
    runtime = vault_lib.resolve_runtime(agent, mode)
    provider = runtime.split(":")[0] if ":" in runtime else runtime
    if provider != "claude":
        return ""  # Caller should fall back to subprocess

    # Send placeholder
    msg = await update.message.reply_text(placeholder)
    last_edit_time = time.time()
    edit_buffer = ""

    async def on_chunk(chunk: str, full_text: str):
        nonlocal last_edit_time, edit_buffer
        edit_buffer = full_text
        now = time.time()
        # Edit message every 1.0s to stay under Telegram rate limits
        if now - last_edit_time >= 1.0 and len(edit_buffer) > 10:
            display = edit_buffer[:4000]  # Telegram 4096 char limit
            try:
                await msg.edit_text(display, parse_mode="Markdown")
            except Exception:
                try:
                    await msg.edit_text(display)
                except Exception:
                    pass  # Rate limited or other issue, skip this edit
            last_edit_time = now

    try:
        # Build the full Advisor prompt with vault context
        # (mirrors what run-advisor.sh does with knowledge file, actions, etc.)
        if agent == "ADVISOR":
            full_prompt = vault_lib.build_advisor_prompt(prompt, mode)
        else:
            full_prompt = prompt

        # Enable vault tools for Advisor ask/strategy (not triage — must stay fast)
        use_tools = (agent == "ADVISOR" and mode in ("ask", "strategy"))
        tools_arg = vault_lib.VAULT_TOOLS if use_tools else None

        async def on_tool_use_status(tool_name, description):
            """Show 'Checking vault...' status during tool-use rounds."""
            try:
                await msg.edit_text(f"🔍 {description}")
            except Exception:
                pass

        response = await vault_lib.invoke_llm(
            prompt=full_prompt,
            agent=agent,
            mode=mode,
            stream=True,
            on_chunk=on_chunk,
            on_tool_use=on_tool_use_status if use_tools else None,
            system_prompt=system_prompt,
            tools=tools_arg,
        )

        if not response:
            await msg.edit_text("🧠 Didn't get a response. Try /ask to re-engage.")
            return ""

        # Final edit with complete response + wikilinks
        # Don't convert wikilinks until the final message (avoids mid-stream link changes)
        final = convert_wikilinks(response)
        if len(final) > 4000:
            final = final[:3900] + "\n\n... (see full in Obsidian)"

        try:
            await msg.edit_text(final, parse_mode="Markdown")
        except Exception:
            try:
                await msg.edit_text(final)
            except Exception:
                pass

        return response

    except Exception as e:
        logger.error(f"Streaming response failed: {e}")
        try:
            await msg.edit_text("❌ Hit a wall. Your note is saved — try /ask to re-engage.")
        except Exception:
            pass
        return ""


# --- Advisor Commands ---

async def cmd_ask(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """General question to the Advisor. /ask Should I go to that AI meetup?"""
    topic = " ".join(context.args) if context.args else ""
    if not topic:
        await update.message.reply_text(
            "🧠 Usage: /ask <your question>\n"
            "Example: /ask Should I prioritize the Lars meeting?"
        )
        return

    # Create or continue session
    session = context.user_data.get("advisor_session")
    session_args = ["ask", topic]
    if session:
        elapsed = (datetime.now() - session["last_active"]).total_seconds()
        if elapsed < 1800:
            session_args.extend(["--session-id", session["id"]])
        else:
            context.user_data.pop("advisor_session", None)
            session = None

    if not session:
        session_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-ask"
        context.user_data["advisor_session"] = {
            "id": session_id,
            "topic": topic,
            "last_active": datetime.now(),
            "turn": 1,
        }
        session_args.extend(["--session-id", session_id])

    # Try SDK streaming first; fall back to subprocess
    # Build the prompt that run-advisor.sh would build (mode + topic + session)
    # For now, we pass through to run-advisor.sh which assembles context.
    # SDK streaming bypasses the shell script and calls the API directly.
    streamed = await send_streaming_response(
        update, topic, agent="ADVISOR", mode="ask", placeholder="🧠 Thinking..."
    )

    if streamed:
        # Streaming succeeded — update session state
        sess = context.user_data.get("advisor_session")
        if sess:
            sess["last_active"] = datetime.now()
            sess["turn"] = sess.get("turn", 1) + 1
        # Note: send_streaming_response already sent the message with wikilinks
        return

    # Fallback: subprocess via run-advisor.sh (for non-claude runtimes or SDK failure)
    result = await run_agent_command(
        update, "run-advisor.sh", session_args,
        timeout=300, loading_msg="🧠 Thinking..."
    )

    if result and result.returncode == 0 and result.stdout.strip():
        response = result.stdout.strip()
        response = convert_wikilinks(response)
        if len(response) > 3800:
            response = response[:3800] + "\n\n... (see full in Obsidian)"
        sess = context.user_data.get("advisor_session")
        if sess:
            sess["last_active"] = datetime.now()
            sess["turn"] = sess.get("turn", 1) + 1
            response += '\n\n(say "done" to end this conversation)'
        try:
            await update.message.reply_text(response, parse_mode="Markdown")
        except Exception:
            await update.message.reply_text(response)
    elif result:
        logger.error(f"Advisor /ask failed: {(result.stderr or '')[-300:]}")
        await update.message.reply_text("🧠 Advisor hit an issue. Try again with /ask.")


async def cmd_strategy(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Strategic analysis. /strategy Increase Income by Summer"""
    topic = " ".join(context.args) if context.args else ""
    if not topic:
        await update.message.reply_text(
            "🧠 Usage: /strategy <topic>\n"
            "Example: /strategy Increase Income by Summer"
        )
        return

    session_id = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-strategy"
    context.user_data["advisor_session"] = {
        "id": session_id,
        "topic": topic,
        "last_active": datetime.now(),
        "turn": 1,
    }

    # Try SDK streaming first
    streamed = await send_streaming_response(
        update, topic, agent="ADVISOR", mode="strategy",
        placeholder="🧠 Analyzing strategy..."
    )

    if streamed:
        sess = context.user_data.get("advisor_session")
        if sess:
            sess["last_active"] = datetime.now()
            sess["turn"] = sess.get("turn", 1) + 1
        return

    # Fallback: subprocess
    result = await run_agent_command(
        update, "run-advisor.sh", ["strategy", topic, "--session-id", session_id],
        timeout=300, loading_msg="🧠 Analyzing strategy..."
    )

    if result and result.returncode == 0 and result.stdout.strip():
        response = result.stdout.strip()
        response = convert_wikilinks(response)
        if len(response) > 3800:
            response = response[:3800] + "\n\n... (see full in Obsidian)"
        response += '\n\n(say "done" to end this conversation)'
        try:
            await update.message.reply_text(response, parse_mode="Markdown")
        except Exception:
            await update.message.reply_text(response)
    elif result:
        await update.message.reply_text(f"🧠 Strategy analysis had issues:\n{(result.stderr or '')[-500:]}")


# --- Decomposer Commands ---

async def cmd_decompose(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Break an action into executable steps. /decompose Call Waqas"""
    query = " ".join(context.args) if context.args else ""
    if not query:
        await update.message.reply_text(
            "📋 Usage: /decompose <action name>\n"
            "Example: /decompose Call Waqas Malik"
        )
        return

    match = find_action_by_name(query)
    if not match:
        await update.message.reply_text(f"⚠️ Couldn't find an action matching '{query}'. Try /actions to see the list.")
        return

    action_path, action_name = match
    await update.message.reply_text(f"📋 Breaking down: {action_name}... this takes ~30 seconds")

    result = await run_agent_command(
        update, "run-task-enricher.sh", ["--decompose", action_path],
        timeout=300, loading_msg="📋 Decomposing..."
    )

    if result and result.returncode == 0:
        await update.message.reply_text(f"📋 Decomposition complete for {action_name}. Check Telegram for the step summary, or use:\n/steps {action_name}")
    elif result:
        await update.message.reply_text(f"❌ Decomposition failed:\n{(result.stderr or '')[-500:]}")


async def cmd_steps(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show sub-steps for a decomposed action. /steps Call Waqas"""
    query = " ".join(context.args) if context.args else ""
    if not query:
        await update.message.reply_text(
            "📊 Usage: /steps <action name>\n"
            "Example: /steps Call Waqas Malik"
        )
        return

    # Run status mode (pure shell, instant)
    result = await run_agent_command(
        update, "run-task-enricher.sh", ["--status", query],
        timeout=30, loading_msg="📊 Loading..."
    )

    if result and result.returncode == 0 and result.stdout.strip():
        await update.message.reply_text(result.stdout.strip())
    elif result:
        await update.message.reply_text(f"⚠️ {(result.stderr or result.stdout or 'Not found')[:500]}")


async def cmd_replan(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Re-decompose an action with new context. /replan Call Waqas we don't need the GmbH"""
    args_text = " ".join(context.args) if context.args else ""
    if not args_text:
        await update.message.reply_text(
            "🔄 Usage: /replan <action name> [new context]\n"
            "Example: /replan Resolve Contracts we don't have a GmbH"
        )
        return

    # Split: first try to match an action name, rest is context
    # Simple heuristic: try progressively shorter prefixes
    match = None
    new_context = ""
    words = args_text.split()
    for i in range(len(words), 0, -1):
        candidate = " ".join(words[:i])
        match = find_action_by_name(candidate)
        if match:
            new_context = " ".join(words[i:])
            break

    if not match:
        await update.message.reply_text(f"⚠️ Couldn't find an action matching '{args_text}'. Try /actions.")
        return

    action_path, action_name = match
    redecompose_args = ["--redecompose", action_path]
    if new_context:
        redecompose_args.append(new_context)

    result = await run_agent_command(
        update, "run-task-enricher.sh", redecompose_args,
        timeout=300, loading_msg="🔄 Re-planning..."
    )

    if result and result.returncode == 0:
        await update.message.reply_text(f"🔄 Plan updated for {action_name}.")
    elif result:
        await update.message.reply_text(f"❌ Re-plan failed:\n{(result.stderr or '')[-500:]}")


# --- Execution Engine (runs as job_queue task) ---

async def run_executor(context: ContextTypes.DEFAULT_TYPE):
    """Periodic DAG walker: execute next eligible sub-actions."""
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-task-enricher.sh"), "--execute"],
            cwd=VAULT_DIR,
            capture_output=True,
            text=True,
            timeout=600,
        )
        if result.returncode != 0:
            logger.warning(f"Executor error: {result.stderr[-300:]}")
    except subprocess.TimeoutExpired:
        logger.warning("Executor timed out after 10 minutes")
    except Exception as e:
        logger.warning(f"Executor exception: {e}")


# --- Decomposer Input Collection ---

def get_pending_input():
    """Check for pending decomposer input questions."""
    if not os.path.exists(DECOMPOSER_INPUT_DIR):
        return None
    for f in sorted(os.listdir(DECOMPOSER_INPUT_DIR)):
        if f.endswith(".md"):
            path = os.path.join(DECOMPOSER_INPUT_DIR, f)
            try:
                content = open(path).read()
                slug = f[:-3]
                # Check if answer already exists
                answer_path = os.path.join(DECOMPOSER_ANSWERS_DIR, f)
                if os.path.exists(answer_path):
                    continue
                return {"slug": slug, "path": path, "content": content}
            except Exception:
                continue
    return None


# --- Main ---

def main():
    """Start the bot."""
    # Startup diagnostics
    import telegram
    ptb_version = getattr(telegram, '__version__', 'unknown')
    logger.info(f"python-telegram-bot version: {ptb_version}")
    has_reactions = hasattr(telegram, 'ReactionTypeEmoji')
    logger.info(f"Reaction support: {'yes' if has_reactions else 'NO — upgrade to v20.7+'}")
    if not has_reactions:
        logger.warning("Emoji reactions require python-telegram-bot >= 20.7. "
                       "Install with: pip install python-telegram-bot --upgrade")

    app = Application.builder().token(TOKEN).build()

    # Commands
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CommandHandler("briefing", cmd_briefing))
    app.add_handler(CommandHandler("actions", cmd_actions))
    app.add_handler(CommandHandler("changelog", cmd_changelog))
    app.add_handler(CommandHandler("review", cmd_review))
    app.add_handler(CommandHandler("think", cmd_think))
    # Task Enricher commands
    app.add_handler(CommandHandler("next", cmd_next))
    app.add_handler(CommandHandler("enrich", cmd_enrich))
    app.add_handler(CommandHandler("stale", cmd_stale))
    app.add_handler(CommandHandler("snooze", cmd_snooze))
    # Workflow commands
    app.add_handler(CommandHandler("email", cmd_email))

    # Advisor commands
    app.add_handler(CommandHandler("ask", cmd_ask))
    app.add_handler(CommandHandler("strategy", cmd_strategy))

    # Decomposer commands
    app.add_handler(CommandHandler("decompose", cmd_decompose))
    app.add_handler(CommandHandler("steps", cmd_steps))
    app.add_handler(CommandHandler("replan", cmd_replan))

    # Operator commands
    app.add_handler(CommandHandler("ops", cmd_ops))
    app.add_handler(CommandHandler("approve", cmd_approve))
    app.add_handler(CommandHandler("reject", cmd_reject))
    app.add_handler(CommandHandler("ops_log", cmd_ops_log))

    # Orchestrator commands (/run, /stop, /resume)
    if HAS_ORCH:
        app.add_handler(CommandHandler("run", orch_handlers.cmd_run))
        app.add_handler(CommandHandler("stop", orch_handlers.cmd_stop))
        app.add_handler(CommandHandler("resume", orch_handlers.cmd_resume))

    # Inline button callbacks
    if HAS_ORCH:
        app.add_handler(CallbackQueryHandler(orch_handlers.handle_exec_callback, pattern=r"^exec_"))
    app.add_handler(CallbackQueryHandler(handle_op_callback, pattern=r"^op_"))
    app.add_handler(CallbackQueryHandler(handle_review_callback))

    # Messages
    app.add_handler(MessageHandler(filters.VOICE, handle_voice))
    app.add_handler(MessageHandler(filters.AUDIO | filters.Document.AUDIO, handle_audio))
    app.add_handler(MessageHandler(filters.LOCATION, handle_location))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))

    # Operations watcher: check for new pending ops every 30 seconds.
    # If python-telegram-bot was installed without the optional job-queue extra,
    # keep the bot alive for voice/text handling and skip this background poller.
    if app.job_queue is not None:
        app.job_queue.run_repeating(
            lambda ctx: check_and_notify_operations(ctx.application),
            interval=30,
            first=10,
            name="ops_watcher",
        )
        # Execution engine: walk the sub-action DAG every 15 min
        app.job_queue.run_repeating(
            run_executor,
            interval=900,
            first=60,
            name="decomposer_executor",
        )
        # Orchestrator: advance automated steps every 5 min
        if HAS_ORCH:
            app.job_queue.run_repeating(
                orch_handlers.run_executor_tick,
                interval=300,
                first=90,
                name="orchestrator_executor",
            )
        # Agent feedback: check for new agent work and route to Advisor for commentary
        app.job_queue.run_repeating(
            check_agent_feedback,
            interval=60,
            first=30,
            name="agent_feedback",
        )
        # Voice pipeline progress: poll progress files and update status messages
        app.job_queue.run_repeating(
            poll_voice_progress,
            interval=10,
            first=5,
            name="voice_progress",
        )
    else:
        logger.warning(
            "JobQueue unavailable; skipping operations watcher. "
            "Install python-telegram-bot[job-queue] to enable background polling."
        )

    logger.info("Vault bot starting...")
    logger.info(f"Vault: {VAULT_DIR}")
    logger.info(f"Drop: {DROP_DIR}")
    logger.info(f"Operations: {OPS_PENDING_DIR}")
    logger.info(f"Authorized chat: {ALLOWED_CHAT_ID or 'ANY (first /start will lock it)'}")

    app.run_polling()


if __name__ == "__main__":
    main()
