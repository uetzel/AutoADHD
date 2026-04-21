"""
orchestrator.py — Iterative execution loop for vault actions.

Drives actions from decomposition through execution to done:
  /run → DECOMPOSE → EXECUTE → CHOICE/INPUT/APPROVAL → RESEARCH → RE-ENRICH → DONE

State persists as JSON in Meta/decomposer/orchestrator/{action-slug}.json.
This file is the single source of truth for execution state.
Canon/Actions/ frontmatter tracks high-level lifecycle only.

Imported by vault-bot.py and orchestrator_handlers.py.
"""

import os
import re
import json
import logging
import subprocess
from enum import Enum
from datetime import datetime
from typing import Optional
from pathlib import Path

logger = logging.getLogger("orchestrator")

VAULT_DIR = os.environ.get("VAULT_DIR", "${VAULT_DIR:-$HOME/VaultSandbox}")
SCRIPTS_DIR = os.path.join(VAULT_DIR, "Meta", "scripts")
ORCH_DIR = os.path.join(VAULT_DIR, "Meta", "decomposer", "orchestrator")
FEEDBACK_FILE = os.path.join(VAULT_DIR, "Meta", "agent-feedback.jsonl")


class State(str, Enum):
    DECOMPOSING = "DECOMPOSING"
    EXECUTING = "EXECUTING"
    WAITING_INPUT = "WAITING_INPUT"
    WAITING_CHOICE = "WAITING_CHOICE"
    WAITING_APPROVAL = "WAITING_APPROVAL"
    RESEARCHING = "RESEARCHING"
    RE_ENRICHING = "RE_ENRICHING"
    COMPLETE = "COMPLETE"
    FAILED = "FAILED"
    PAUSED = "PAUSED"


def _slugify(name: str) -> str:
    """Convert action name to filesystem-safe slug."""
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug[:60]


def _now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _log_feedback(event: str, action: str, detail: str = "", notify: bool = False):
    """Append orchestrator event to agent-feedback.jsonl."""
    try:
        entry = {
            "ts": _now_iso(),
            "agent": "Orchestrator",
            "event": event,
            "summary": f"{action}: {detail}" if detail else action,
            "source": None,
            "files_changed": [],
            "notify": notify,
        }
        os.makedirs(os.path.dirname(FEEDBACK_FILE), exist_ok=True)
        with open(FEEDBACK_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        logger.warning(f"Failed to log feedback: {e}")


class Orchestration:
    """State for one action's execution lifecycle."""

    def __init__(self, action_path: str, action_name: str):
        self.action_path = action_path
        self.action_name = action_name
        self.slug = _slugify(action_name)
        self.state = State.DECOMPOSING
        self.steps = []  # list of sub-step dicts
        self.current_step_idx = 0
        self.created = _now_iso()
        self.updated = _now_iso()
        self.progress_message_id = None  # Telegram message ID for progress edits
        self.research_topic = None
        self.research_started = None
        self.depth = 0  # recursion depth for choice sub-steps
        self.max_depth = 3

    @property
    def state_file(self) -> str:
        return os.path.join(ORCH_DIR, f"{self.slug}.json")

    def save(self):
        """Persist state to JSON file."""
        try:
            os.makedirs(ORCH_DIR, exist_ok=True)
            data = {
                "action_path": self.action_path,
                "action_name": self.action_name,
                "slug": self.slug,
                "state": self.state.value,
                "steps": self.steps,
                "current_step_idx": self.current_step_idx,
                "created": self.created,
                "updated": _now_iso(),
                "progress_message_id": self.progress_message_id,
                "research_topic": self.research_topic,
                "research_started": self.research_started,
                "depth": self.depth,
            }
            with open(self.state_file, "w") as f:
                json.dump(data, f, indent=2)
        except IOError as e:
            logger.error(f"Failed to save orchestration state: {e}")
            raise

    @classmethod
    def load(cls, slug: str) -> Optional["Orchestration"]:
        """Load orchestration from state file."""
        path = os.path.join(ORCH_DIR, f"{slug}.json")
        if not os.path.exists(path):
            return None
        try:
            with open(path) as f:
                data = json.load(f)
            orch = cls(data["action_path"], data["action_name"])
            orch.slug = data["slug"]
            orch.state = State(data["state"])
            orch.steps = data.get("steps", [])
            orch.current_step_idx = data.get("current_step_idx", 0)
            orch.created = data.get("created", "")
            orch.updated = data.get("updated", "")
            orch.progress_message_id = data.get("progress_message_id")
            orch.research_topic = data.get("research_topic")
            orch.research_started = data.get("research_started")
            orch.depth = data.get("depth", 0)
            return orch
        except (json.JSONDecodeError, KeyError, IOError) as e:
            logger.error(f"Failed to load orchestration {slug}: {e}")
            return None

    def delete(self):
        """Remove state file on completion."""
        try:
            if os.path.exists(self.state_file):
                os.remove(self.state_file)
        except IOError as e:
            logger.warning(f"Failed to delete state file: {e}")


def list_active() -> list:
    """List all active orchestrations (state files in ORCH_DIR)."""
    if not os.path.isdir(ORCH_DIR):
        return []
    result = []
    for fname in os.listdir(ORCH_DIR):
        if fname.endswith(".json"):
            slug = fname.replace(".json", "")
            orch = Orchestration.load(slug)
            if orch and orch.state not in (State.COMPLETE, State.FAILED):
                result.append(orch)
    return result


def find_by_name(action_name: str) -> Optional[Orchestration]:
    """Find an active orchestration by action name (fuzzy match)."""
    search = action_name.lower()
    for orch in list_active():
        if search in orch.action_name.lower():
            return orch
    return None


def start(action_path: str) -> Orchestration:
    """Start a new orchestration for an action.

    1. Read the action file to get its name
    2. Check if an orchestration already exists
    3. Decompose via run-task-enricher.sh --decompose
    4. Load the resulting sub-steps
    5. Save state and return
    """
    import sys
    sys.path.insert(0, SCRIPTS_DIR)
    try:
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location("vault_lib", os.path.join(SCRIPTS_DIR, "vault-lib.py"))
        vault_lib = module_from_spec(spec)
        spec.loader.exec_module(vault_lib)
    except Exception:
        vault_lib = None

    # Read action name from frontmatter
    full_path = os.path.join(VAULT_DIR, action_path) if not os.path.isabs(action_path) else action_path
    action_name = os.path.basename(action_path).replace(".md", "")
    if vault_lib:
        try:
            fm = vault_lib.parse_frontmatter(full_path)
            action_name = fm.get("name", action_name)
        except Exception:
            pass

    # Check for existing orchestration
    slug = _slugify(action_name)
    existing = Orchestration.load(slug)
    if existing and existing.state not in (State.COMPLETE, State.FAILED):
        return existing

    orch = Orchestration(action_path, action_name)
    orch.state = State.DECOMPOSING
    orch.save()

    _log_feedback("orchestration_started", action_name)

    # Decompose
    try:
        subprocess.run(
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-task-enricher.sh"),
             "--decompose", full_path],
            capture_output=True, text=True, timeout=60,
        )
    except Exception as e:
        logger.error(f"Decompose failed: {e}")
        orch.state = State.FAILED
        orch.save()
        _log_feedback("orchestration_failed", action_name, f"decompose error: {e}")
        return orch

    # Load sub-steps from Canon/Actions/ (children of this action)
    orch.steps = _load_sub_steps(action_name, vault_lib)
    if not orch.steps:
        # No sub-steps created, treat as single-step action
        orch.steps = [{
            "name": action_name,
            "execution_type": "manual",
            "status": "pending",
            "sequence": 1,
        }]

    orch.state = State.EXECUTING
    orch.current_step_idx = 0
    orch.save()
    return orch


def _load_sub_steps(parent_name: str, vault_lib=None) -> list:
    """Load sub-action files that reference the parent action."""
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    steps = []
    if not os.path.isdir(actions_dir):
        return steps

    for dirpath, _, filenames in os.walk(actions_dir):
        for fname in sorted(filenames):
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(dirpath, fname)
            try:
                if vault_lib:
                    fm = vault_lib.parse_frontmatter(fpath)
                else:
                    fm = _simple_parse_frontmatter(fpath)
                parent = fm.get("parent_action", "")
                if parent_name.lower() not in str(parent).lower():
                    continue
                steps.append({
                    "name": fm.get("name", fname.replace(".md", "")),
                    "file": fpath.replace(VAULT_DIR + "/", ""),
                    "execution_type": fm.get("execution_type", "manual"),
                    "status": fm.get("status", "pending") if fm.get("status") != "done" else "done",
                    "sequence": int(fm.get("sequence", 99)),
                    "blocking": fm.get("blocking", True),
                    "depends_on": fm.get("depends_on", []),
                    "choices": fm.get("choices", []),
                    "input_question": fm.get("input_question", ""),
                    "agent_hint": fm.get("agent_hint", ""),
                })
            except Exception:
                continue

    steps.sort(key=lambda s: s.get("sequence", 99))
    return steps


def _simple_parse_frontmatter(filepath: str) -> dict:
    """Minimal YAML frontmatter parser (no pyyaml dependency)."""
    result = {}
    try:
        with open(filepath) as f:
            content = f.read()
        if not content.startswith("---"):
            return result
        end = content.find("---", 3)
        if end == -1:
            return result
        fm_text = content[3:end].strip()
        for line in fm_text.split("\n"):
            if ":" in line:
                key, _, value = line.partition(":")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if value.startswith("[") or value.startswith("-"):
                    continue  # skip arrays for simple parser
                result[key] = value
    except Exception:
        pass
    return result


def advance(orch: Orchestration) -> dict:
    """Find the next step to act on and return what to do.

    Returns a dict with:
      action: "execute_automated" | "present_choice" | "ask_input" |
              "create_approval" | "notify_manual" | "complete" | "waiting" | "none"
      step: the step dict (if applicable)
      ... additional fields depending on action
    """
    if orch.state == State.COMPLETE:
        return {"action": "complete"}
    if orch.state == State.PAUSED:
        return {"action": "waiting", "reason": "paused"}
    if orch.state in (State.WAITING_INPUT, State.WAITING_CHOICE, State.WAITING_APPROVAL):
        return {"action": "waiting", "reason": orch.state.value}
    if orch.state == State.RESEARCHING:
        # Check research timeout (30 min)
        if orch.research_started:
            try:
                started = datetime.fromisoformat(orch.research_started)
                if (datetime.now() - started).total_seconds() > 1800:
                    orch.state = State.EXECUTING
                    orch.research_topic = None
                    orch.research_started = None
                    orch.save()
                    _log_feedback("research_timeout", orch.action_name, "Proceeding without research")
                    return advance(orch)
            except Exception:
                pass
        return {"action": "waiting", "reason": "researching"}

    # Find next pending step
    for i, step in enumerate(orch.steps):
        if step.get("status") in ("done", "skipped"):
            continue

        # Check dependencies
        deps = step.get("depends_on", [])
        if deps:
            all_done = all(
                any(s.get("name", "").lower() in str(d).lower() and s.get("status") == "done"
                    for s in orch.steps)
                for d in deps
            )
            if not all_done:
                continue

        orch.current_step_idx = i
        exec_type = step.get("execution_type", "manual")

        if exec_type == "automated":
            return {"action": "execute_automated", "step": step, "step_idx": i}
        elif exec_type == "choice":
            orch.state = State.WAITING_CHOICE
            orch.save()
            _log_feedback("state_transition", orch.action_name, f"WAITING_CHOICE at step {i+1}")
            return {"action": "present_choice", "step": step, "step_idx": i,
                    "choices": step.get("choices", [])}
        elif exec_type == "input":
            orch.state = State.WAITING_INPUT
            orch.save()
            _log_feedback("state_transition", orch.action_name, f"WAITING_INPUT at step {i+1}")
            return {"action": "ask_input", "step": step, "step_idx": i,
                    "question": step.get("input_question", "What should we do?")}
        elif exec_type == "approval":
            orch.state = State.WAITING_APPROVAL
            orch.save()
            _log_feedback("state_transition", orch.action_name, f"WAITING_APPROVAL at step {i+1}")
            return {"action": "create_approval", "step": step, "step_idx": i}
        else:  # manual
            return {"action": "notify_manual", "step": step, "step_idx": i}

    # All steps done or skipped
    blocking_incomplete = [s for s in orch.steps
                           if s.get("blocking", True)
                           and s.get("status") not in ("done", "skipped")]
    if not blocking_incomplete:
        orch.state = State.COMPLETE
        orch.save()
        _log_feedback("orchestration_complete", orch.action_name,
                      f"All {len(orch.steps)} steps done",
                      notify=True)
        return {"action": "complete"}

    return {"action": "none", "reason": "all remaining steps have unmet dependencies"}


def mark_step_done(orch: Orchestration, step_idx: int):
    """Mark a step as done and save."""
    if 0 <= step_idx < len(orch.steps):
        orch.steps[step_idx]["status"] = "done"
        orch.state = State.EXECUTING
        orch.save()


def mark_step_skipped(orch: Orchestration, step_idx: int):
    """Mark a step as skipped and save."""
    if 0 <= step_idx < len(orch.steps):
        orch.steps[step_idx]["status"] = "skipped"
        orch.state = State.EXECUTING
        orch.save()


def handle_choice(orch: Orchestration, choice_id: str) -> Optional[dict]:
    """Handle a user's choice selection.

    If choice_id is "skip", marks the step as skipped.
    Otherwise, finds the chosen option, creates sub-steps for it,
    and transitions back to EXECUTING.
    """
    step_idx = orch.current_step_idx
    step = orch.steps[step_idx] if step_idx < len(orch.steps) else None
    if not step:
        return None

    if choice_id == "skip":
        mark_step_skipped(orch, step_idx)
        return advance(orch)

    # Find the chosen option
    choices = step.get("choices", [])
    chosen = None
    for c in choices:
        if c.get("id") == choice_id:
            chosen = c
            break

    if not chosen:
        return {"action": "error", "message": f"Choice '{choice_id}' not found"}

    # Record the choice
    step["chosen"] = choice_id
    step["status"] = "done"

    # If within recursion limit, create sub-steps for the chosen action
    if orch.depth < orch.max_depth and chosen.get("action"):
        # Insert new sub-steps after current step
        new_step = {
            "name": chosen.get("label", chosen["id"]),
            "execution_type": "automated",
            "status": "pending",
            "sequence": step.get("sequence", 0) + 0.5,
            "blocking": True,
            "depends_on": [],
            "from_choice": choice_id,
        }
        orch.steps.insert(step_idx + 1, new_step)

    orch.state = State.EXECUTING
    orch.save()
    _log_feedback("choice_made", orch.action_name, f"Chose: {chosen.get('label', choice_id)}")
    return advance(orch)


def handle_input(orch: Orchestration, answer: str) -> Optional[dict]:
    """Handle a user's text input for an input step."""
    step_idx = orch.current_step_idx
    if step_idx < len(orch.steps):
        orch.steps[step_idx]["answer"] = answer
        orch.steps[step_idx]["status"] = "done"

    orch.state = State.EXECUTING
    orch.save()
    _log_feedback("input_received", orch.action_name, f"Answer received for step {step_idx+1}")
    return advance(orch)


def trigger_research(orch: Orchestration, topic: str):
    """Transition to RESEARCHING state and start the researcher."""
    orch.state = State.RESEARCHING
    orch.research_topic = topic
    orch.research_started = _now_iso()
    orch.save()
    _log_feedback("research_triggered", orch.action_name, f"Topic: {topic}")

    # Start researcher in background
    try:
        subprocess.Popen(
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-researcher.sh"), topic],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        logger.error(f"Failed to start researcher: {e}")


def complete_research(orch: Orchestration):
    """Called when research completes. Re-decomposes and resumes."""
    orch.state = State.RE_ENRICHING
    orch.save()

    # Re-decompose with research findings
    full_path = os.path.join(VAULT_DIR, orch.action_path)
    try:
        subprocess.run(
            ["/bin/bash", os.path.join(SCRIPTS_DIR, "run-task-enricher.sh"),
             "--redecompose", full_path],
            capture_output=True, text=True, timeout=60,
        )
    except Exception as e:
        logger.warning(f"Re-decompose failed: {e}")

    # Reload steps
    try:
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location("vault_lib", os.path.join(SCRIPTS_DIR, "vault-lib.py"))
        vault_lib = module_from_spec(spec)
        spec.loader.exec_module(vault_lib)
    except Exception:
        vault_lib = None

    new_steps = _load_sub_steps(orch.action_name, vault_lib)
    if new_steps:
        # Keep completed steps, replace pending ones
        done = [s for s in orch.steps if s.get("status") in ("done", "skipped")]
        pending_new = [s for s in new_steps if s.get("status") not in ("done", "skipped")]
        orch.steps = done + pending_new

    orch.state = State.EXECUTING
    orch.research_topic = None
    orch.research_started = None
    orch.save()
    _log_feedback("research_complete", orch.action_name, "Re-enriched, resuming execution")


def stop(orch: Orchestration):
    """Pause an orchestration."""
    orch.state = State.PAUSED
    orch.save()
    _log_feedback("orchestration_paused", orch.action_name)


def resume(orch: Orchestration) -> dict:
    """Resume a paused orchestration."""
    orch.state = State.EXECUTING
    orch.save()
    _log_feedback("orchestration_resumed", orch.action_name)
    return advance(orch)


def get_progress_text(orch: Orchestration) -> str:
    """Generate the progress message text for Telegram."""
    if orch.state == State.COMPLETE:
        emoji = "\u2705"  # checkmark
        header = f"{emoji} {orch.action_name} \u2014 DONE"
    elif orch.state == State.PAUSED:
        header = f"\u23f8 {orch.action_name} \u2014 PAUSED"
    elif orch.state == State.FAILED:
        header = f"\u26a0\ufe0f {orch.action_name} \u2014 FAILED"
    else:
        header = f"\U0001f3c3 {orch.action_name}"

    lines = [header, ""]
    for i, step in enumerate(orch.steps):
        status = step.get("status", "pending")
        name = step.get("name", f"Step {i+1}")
        total = len(orch.steps)
        if status == "done":
            lines.append(f"\u2705 Step {i+1}/{total}: {name}")
        elif status == "skipped":
            lines.append(f"\u23ed Step {i+1}/{total}: {name} (skipped)")
        elif i == orch.current_step_idx and orch.state != State.COMPLETE:
            lines.append(f"\u26a1 Step {i+1}/{total}: {name}")
        else:
            lines.append(f"\u2b1c Step {i+1}/{total}: {name}")

    return "\n".join(lines)
