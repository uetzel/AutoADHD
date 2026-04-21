"""
orchestrator_handlers.py — Telegram handlers for the orchestrator.

Imported by vault-bot.py. Provides:
  - cmd_run: /run <action-name> command handler
  - cmd_stop: /stop <action-name> command handler
  - cmd_resume: /resume <action-name> command handler
  - handle_exec_callback: callback handler for exec_* button presses
  - run_executor_tick: periodic job that advances automated steps
  - present_choices: send choice buttons to Telegram
"""

import os
import logging
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import ContextTypes

logger = logging.getLogger("orch-handlers")

# Import orchestrator
import importlib.util
_SCRIPTS_DIR = os.path.join(
    os.environ.get("VAULT_DIR", "${VAULT_DIR:-$HOME/VaultSandbox}"),
    "Meta", "scripts",
)
_spec = importlib.util.spec_from_file_location("orchestrator", os.path.join(_SCRIPTS_DIR, "orchestrator.py"))
orch_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(orch_mod)


def _get_chat_id(context):
    """Get the allowed chat ID from environment."""
    cid = os.environ.get("ALLOWED_CHAT_ID", "")
    return int(cid) if cid else None


async def cmd_run(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /run <action-name> — decompose and start orchestration."""
    if not update.message:
        return

    args = context.args
    if not args:
        await update.message.reply_text("Usage: /run <action name>")
        return

    action_name = " ".join(args)

    # Check if already running
    existing = orch_mod.find_by_name(action_name)
    if existing and existing.state not in (orch_mod.State.COMPLETE, orch_mod.State.FAILED):
        progress = orch_mod.get_progress_text(existing)
        await update.message.reply_text(f"Already running! Here's where you are:\n\n{progress}")
        return

    # Find the action file
    action_path = _find_action_file(action_name)
    if not action_path:
        await update.message.reply_text(
            f"No action found matching '{action_name}'. Check Canon/Actions/."
        )
        return

    # Send immediate "on it" response (<1s)
    msg = await update.message.reply_text(f"\U0001f3c3 Running: {action_name}\n\nBreaking into steps...")

    # Start orchestration (this calls decompose)
    orch = orch_mod.start(action_path)

    if orch.state == orch_mod.State.FAILED:
        await msg.edit_text(f"\u26a0\ufe0f Couldn't break down '{action_name}'. Try a simpler version?")
        return

    # Save the progress message ID for future edits
    orch.progress_message_id = msg.message_id
    orch.save()

    # Update progress
    progress = orch_mod.get_progress_text(orch)
    try:
        await msg.edit_text(progress)
    except Exception:
        pass

    # Advance to first step
    await _advance_and_act(orch, update.effective_chat.id, context)


async def cmd_stop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /stop <action-name> — pause an orchestration."""
    args = context.args
    if not args:
        await update.message.reply_text("Usage: /stop <action name>")
        return

    action_name = " ".join(args)
    orch = orch_mod.find_by_name(action_name)
    if not orch:
        await update.message.reply_text(f"No active orchestration for '{action_name}'.")
        return

    done_count = sum(1 for s in orch.steps if s.get("status") == "done")
    total = len(orch.steps)
    orch_mod.stop(orch)

    await update.message.reply_text(f"\u23f9 Stopped. {done_count}/{total} steps done. /resume when ready.")


async def cmd_resume(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle /resume <action-name> — resume a paused orchestration."""
    args = context.args
    if not args:
        await update.message.reply_text("Usage: /resume <action name>")
        return

    action_name = " ".join(args)
    orch = orch_mod.find_by_name(action_name)
    if not orch:
        await update.message.reply_text(f"No orchestration found for '{action_name}'.")
        return

    if orch.state != orch_mod.State.PAUSED:
        await update.message.reply_text(f"'{action_name}' isn't paused (state: {orch.state.value}).")
        return

    orch_mod.resume(orch)
    await _advance_and_act(orch, update.effective_chat.id, context)


async def handle_exec_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Handle exec_* callback button presses.

    Callback data format: exec_{slug}_{choice_id}
    """
    query = update.callback_query
    if not query:
        return
    await query.answer()

    data = query.data
    parts = data.split("_", 2)
    if len(parts) < 3:
        return

    _, slug, choice_id = parts[0], parts[1], parts[2]

    orch = orch_mod.Orchestration.load(slug)
    if not orch:
        await query.edit_message_text("\u26a0\ufe0f Orchestration not found. It may have expired.")
        return

    # Handle the choice
    result = orch_mod.handle_choice(orch, choice_id)
    if not result:
        await query.edit_message_text("\u26a0\ufe0f Couldn't process that choice.")
        return

    # Update progress message
    chat_id = query.message.chat_id
    await _update_progress(orch, chat_id, context)

    # Continue advancing
    if result.get("action") not in ("waiting", "complete", "error", "none"):
        await _advance_and_act(orch, chat_id, context)
    elif result.get("action") == "complete":
        await _update_progress(orch, chat_id, context)
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"\u2705 {orch.action_name} is done!",
        )


async def present_choices(chat_id: int, orch, step: dict, context: ContextTypes.DEFAULT_TYPE):
    """Send choice buttons to Telegram. Max 4 + skip."""
    choices = step.get("choices", [])
    keyboard = []
    for choice in choices[:4]:
        label = choice.get("label", choice.get("id", "?"))
        callback = f"exec_{orch.slug}_{choice.get('id', 'unknown')}"
        keyboard.append([InlineKeyboardButton(label, callback_data=callback)])

    # Always add skip
    keyboard.append([InlineKeyboardButton("\u23ed Skip for now",
                                          callback_data=f"exec_{orch.slug}_skip")])

    markup = InlineKeyboardMarkup(keyboard)
    step_name = step.get("name", "")
    await context.bot.send_message(
        chat_id=chat_id,
        text=f"Your call: {step_name}\n\n",
        reply_markup=markup,
    )


async def ask_input(chat_id: int, orch, step: dict, context: ContextTypes.DEFAULT_TYPE):
    """Ask the user for text input. Stores the orchestration slug in user_data."""
    question = step.get("input_question", "What should we do?")
    await context.bot.send_message(
        chat_id=chat_id,
        text=f"\u270d\ufe0f {question}",
    )
    # Mark that next text message is an orchestrator input answer
    context.application.user_data.setdefault(chat_id, {})["orch_input_for"] = orch.slug


async def run_executor_tick(context: ContextTypes.DEFAULT_TYPE):
    """Periodic job: advance automated steps for all active orchestrations.

    Runs every 5 min when orchestrations exist, skips otherwise.
    """
    active = orch_mod.list_active()
    if not active:
        return

    chat_id = _get_chat_id(context)
    if not chat_id:
        return

    for orch in active:
        if orch.state != orch_mod.State.EXECUTING:
            continue

        result = orch_mod.advance(orch)
        if result.get("action") == "execute_automated":
            await _execute_automated_step(orch, result, chat_id, context)
        elif result.get("action") == "complete":
            await _update_progress(orch, chat_id, context)


async def _advance_and_act(orch, chat_id: int, context):
    """Advance the orchestration and act on the result."""
    result = orch_mod.advance(orch)
    action = result.get("action", "none")

    if action == "execute_automated":
        await _execute_automated_step(orch, result, chat_id, context)
    elif action == "present_choice":
        await _update_progress(orch, chat_id, context)
        await present_choices(chat_id, orch, result["step"], context)
    elif action == "ask_input":
        await _update_progress(orch, chat_id, context)
        await ask_input(chat_id, orch, result["step"], context)
    elif action == "create_approval":
        await _update_progress(orch, chat_id, context)
        step = result["step"]
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"\u2705 Ready: {step.get('name', '')}\n\n\u2705 Approve | \u23ed Skip",
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("\u2705 Approve",
                                      callback_data=f"exec_{orch.slug}_approve")],
                [InlineKeyboardButton("\u23ed Skip",
                                      callback_data=f"exec_{orch.slug}_skip")],
            ]),
        )
    elif action == "notify_manual":
        await _update_progress(orch, chat_id, context)
        step = result["step"]
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"\U0001f44b Manual step: {step.get('name', '')}\n\nDo this yourself, then /done {orch.action_name}",
        )
    elif action == "complete":
        await _update_progress(orch, chat_id, context)
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"\u2705 {orch.action_name} is done!",
        )
    # "waiting" and "none" — do nothing


async def _execute_automated_step(orch, result, chat_id, context):
    """Execute an automated step via the task enricher."""
    step = result["step"]
    step_idx = result["step_idx"]

    # Update progress to show current step
    await _update_progress(orch, chat_id, context)

    # Execute the step (for now, just mark it done — actual execution
    # would call run-task-enricher.sh --execute or invoke-agent.sh)
    try:
        agent_hint = step.get("agent_hint", "enricher")
        # TODO: implement actual execution via invoke-agent.sh
        # For now, mark as done to advance the loop
        orch_mod.mark_step_done(orch, step_idx)
    except Exception as e:
        logger.error(f"Automated step failed: {e}")
        await context.bot.send_message(
            chat_id=chat_id,
            text=f"\u26a0\ufe0f Step {step_idx+1} failed: {e}\n\n\U0001f50d Retry | \u23ed Skip | \u274c Stop",
            reply_markup=InlineKeyboardMarkup([
                [InlineKeyboardButton("\U0001f50d Retry", callback_data=f"exec_{orch.slug}_retry")],
                [InlineKeyboardButton("\u23ed Skip", callback_data=f"exec_{orch.slug}_skip")],
                [InlineKeyboardButton("\u274c Stop", callback_data=f"exec_{orch.slug}_stop")],
            ]),
        )
        return

    # Update progress and advance
    await _update_progress(orch, chat_id, context)
    await _advance_and_act(orch, chat_id, context)


async def _update_progress(orch, chat_id, context):
    """Edit the progress message with current state."""
    if not orch.progress_message_id:
        return
    text = orch_mod.get_progress_text(orch)
    try:
        await context.bot.edit_message_text(
            chat_id=chat_id,
            message_id=orch.progress_message_id,
            text=text,
        )
    except Exception:
        pass  # Message may not be editable (too old, etc.)


def _find_action_file(action_name: str) -> str:
    """Find an action file by name in Canon/Actions/."""
    vault_dir = os.environ.get("VAULT_DIR", "${VAULT_DIR:-$HOME/VaultSandbox}")
    actions_dir = os.path.join(vault_dir, "Canon", "Actions")
    search = action_name.lower()
    for dirpath, _, filenames in os.walk(actions_dir):
        for fname in filenames:
            if fname.endswith(".md") and search in fname.lower():
                return os.path.join(dirpath, fname).replace(vault_dir + "/", "")
    return ""
