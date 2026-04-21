#!/usr/bin/env python3
"""
vault-mcp-server.py — MCP server exposing vault tools to Claude Desktop / ChatGPT.

Runs via stdio transport (Claude Desktop) or SSE (remote clients).
Reuses tool executors from vault-lib.py.

Usage:
  python3 vault-mcp-server.py              # stdio (Claude Desktop)
  python3 vault-mcp-server.py --sse 8765   # SSE on port 8765

Claude Desktop config (claude_desktop_config.json):
  {
    "mcpServers": {
      "vault": {
        "command": "python3",
        "args": ["${VAULT_DIR:-$HOME/VaultSandbox}/Meta/scripts/vault-mcp-server.py"]
      }
    }
  }
"""

import os
import sys
import json
import subprocess
import logging
from datetime import datetime

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("vault-mcp")

VAULT_DIR = os.environ.get("VAULT_DIR", "${VAULT_DIR:-$HOME/VaultSandbox}")
SCRIPTS_DIR = os.path.join(VAULT_DIR, "Meta", "scripts")

# Import vault-lib for shared tool executors
import importlib.util
_spec = importlib.util.spec_from_file_location("vault_lib", os.path.join(SCRIPTS_DIR, "vault-lib.py"))
vault_lib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vault_lib)

try:
    from mcp.server import Server
    from mcp.types import Tool, TextContent
    from mcp.server.stdio import stdio_server
except ImportError:
    print("Missing dependency. Run: pip3 install mcp", file=sys.stderr)
    sys.exit(1)

server = Server("vault")

# --- Read tools (reuse from vault-lib.py) ---

READ_TOOLS = vault_lib.VAULT_TOOLS  # 5 tools already defined

# --- Write tools (new) ---

WRITE_TOOLS = [
    {
        "name": "vault_create_note",
        "description": "Create a new note in Inbox/ with frontmatter. Returns the file path.",
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Note title"},
                "content": {"type": "string", "description": "Note body (markdown)"},
                "note_type": {"type": "string", "default": "note", "description": "Type: note, action, reflection, etc."},
            },
            "required": ["title", "content"],
        },
    },
    {
        "name": "vault_update_action",
        "description": "Update frontmatter fields of an action by name. Only specified fields are changed.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action_name": {"type": "string", "description": "Action name to find"},
                "updates": {"type": "object", "description": "Key-value pairs to update in frontmatter"},
            },
            "required": ["action_name", "updates"],
        },
    },
    {
        "name": "vault_trigger_agent",
        "description": "Trigger an agent run. Valid agents: extractor, reviewer, thinker, briefing, retro, enricher, researcher, mirror.",
        "input_schema": {
            "type": "object",
            "properties": {
                "agent": {"type": "string", "description": "Agent name"},
                "args": {"type": "string", "description": "Additional arguments", "default": ""},
            },
            "required": ["agent"],
        },
    },
    {
        "name": "vault_log_decision",
        "description": "Log a decision via the vault's decision logging system.",
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "decided": {"type": "string"},
                "why": {"type": "string"},
                "rejected": {"type": "string", "default": ""},
                "check_later": {"type": "string", "default": ""},
            },
            "required": ["title", "decided", "why"],
        },
    },
    {
        "name": "vault_send_telegram",
        "description": "Send a Telegram message via the vault bot.",
        "input_schema": {
            "type": "object",
            "properties": {
                "message": {"type": "string", "description": "Message text to send"},
            },
            "required": ["message"],
        },
    },
    {
        "name": "vault_advisor_ask",
        "description": "Route a question to the Advisor agent and return the response.",
        "input_schema": {
            "type": "object",
            "properties": {
                "question": {"type": "string"},
                "mode": {"type": "string", "default": "ask", "description": "ask or strategy"},
            },
            "required": ["question"],
        },
    },
]

ALL_TOOLS = READ_TOOLS + WRITE_TOOLS

ALLOWED_AGENTS = {
    "extractor": "run-extractor.sh",
    "reviewer": "run-reviewer.sh",
    "thinker": "run-thinker.sh",
    "briefing": "daily-briefing.sh",
    "retro": "run-retro.sh",
    "enricher": "run-task-enricher.sh",
    "researcher": "run-researcher.sh",
    "mirror": "run-mirror.sh",
}


def _exec_create_note(title: str, content: str, note_type: str = "note") -> str:
    """Create a note in Inbox/."""
    date = datetime.now().strftime("%Y-%m-%d")
    slug = title.replace(" ", "-").replace("/", "-")[:50]
    filename = f"{date} - {slug}.md"
    filepath = os.path.join(VAULT_DIR, "Inbox", filename)

    if os.path.exists(filepath):
        return f"Note already exists: Inbox/{filename}"

    frontmatter = f"""---
type: {note_type}
name: {title}
created: {date}
source: ai-generated
source_agent: MCP
source_date: {datetime.now().isoformat(timespec='minutes')}
---

"""
    try:
        with open(filepath, "w") as f:
            f.write(frontmatter + content)
        return f"Created: Inbox/{filename}"
    except IOError as e:
        return f"Failed to create note: {e}"


def _exec_update_action(action_name: str, updates: dict) -> str:
    """Update frontmatter fields of an action."""
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    search = action_name.lower()
    for dirpath, _, filenames in os.walk(actions_dir):
        for fname in filenames:
            if fname.endswith(".md") and search in fname.lower():
                fpath = os.path.join(dirpath, fname)
                try:
                    with open(fpath) as f:
                        content = f.read()
                    if not content.startswith("---"):
                        return f"No frontmatter in {fname}"
                    end = content.find("---", 3)
                    if end == -1:
                        return f"Malformed frontmatter in {fname}"

                    fm_text = content[3:end]
                    body = content[end + 3:]

                    for key, value in updates.items():
                        # Replace existing field or add new one
                        import re
                        pattern = rf"^{re.escape(key)}:.*$"
                        replacement = f"{key}: {value}"
                        if re.search(pattern, fm_text, re.MULTILINE):
                            fm_text = re.sub(pattern, replacement, fm_text, flags=re.MULTILINE)
                        else:
                            fm_text = fm_text.rstrip() + f"\n{replacement}\n"

                    with open(fpath, "w") as f:
                        f.write(f"---{fm_text}---{body}")

                    rel = fpath.replace(VAULT_DIR + "/", "")
                    return f"Updated {rel}: {', '.join(updates.keys())}"
                except Exception as e:
                    return f"Error updating {fname}: {e}"
    return f"Action not found: '{action_name}'"


def _exec_trigger_agent(agent: str, args: str = "") -> str:
    """Trigger an agent run."""
    agent_lower = agent.lower()
    script = ALLOWED_AGENTS.get(agent_lower)
    if not script:
        return f"Unknown agent: '{agent}'. Valid: {', '.join(ALLOWED_AGENTS.keys())}"

    script_path = os.path.join(SCRIPTS_DIR, script)
    if not os.path.exists(script_path):
        return f"Script not found: {script}"

    cmd = ["/bin/bash", script_path]
    if args:
        cmd.extend(args.split())

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode == 0:
            return f"Agent '{agent}' completed successfully."
        return f"Agent '{agent}' failed (exit {result.returncode}): {result.stderr[:500]}"
    except subprocess.TimeoutExpired:
        return f"Agent '{agent}' timed out after 120s."
    except Exception as e:
        return f"Failed to run '{agent}': {e}"


def _exec_log_decision(title: str, decided: str, why: str, rejected: str = "", check_later: str = "") -> str:
    """Log a decision via log-decision.sh."""
    script = os.path.join(SCRIPTS_DIR, "log-decision.sh")
    if not os.path.exists(script):
        return "log-decision.sh not found."
    try:
        cmd = ["/bin/bash", script, title, decided, why, rejected, check_later]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return f"Decision logged: {title}" if result.returncode == 0 else f"Failed: {result.stderr[:200]}"
    except Exception as e:
        return f"Error: {e}"


def _exec_send_telegram(message: str) -> str:
    """Send a Telegram message."""
    script = os.path.join(SCRIPTS_DIR, "send-telegram.sh")
    if not os.path.exists(script):
        return "send-telegram.sh not found."
    try:
        result = subprocess.run(["/bin/bash", script, message], capture_output=True, text=True, timeout=30)
        return "Sent." if result.returncode == 0 else f"Failed: {result.stderr[:200]}"
    except Exception as e:
        return f"Error: {e}"


def _exec_advisor_ask(question: str, mode: str = "ask") -> str:
    """Route a question to the Advisor."""
    script = os.path.join(SCRIPTS_DIR, "run-advisor.sh")
    if not os.path.exists(script):
        return "run-advisor.sh not found."
    try:
        result = subprocess.run(
            ["/bin/bash", script, mode, question],
            capture_output=True, text=True, timeout=120,
        )
        return result.stdout.strip() if result.returncode == 0 else f"Advisor failed: {result.stderr[:500]}"
    except subprocess.TimeoutExpired:
        return "Advisor timed out."
    except Exception as e:
        return f"Error: {e}"


@server.list_tools()
async def list_tools():
    return [
        Tool(name=t["name"], description=t["description"], inputSchema=t["input_schema"])
        for t in ALL_TOOLS
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict):
    # Read tools (dispatched via vault-lib)
    if name in ("vault_grep", "vault_read_note", "vault_list_actions",
                "vault_recent_changes", "vault_check_status"):
        result = vault_lib.execute_vault_tool(name, arguments)
        return [TextContent(type="text", text=result)]

    # Write tools
    if name == "vault_create_note":
        result = _exec_create_note(
            arguments.get("title", "Untitled"),
            arguments.get("content", ""),
            arguments.get("note_type", "note"),
        )
    elif name == "vault_update_action":
        result = _exec_update_action(
            arguments.get("action_name", ""),
            arguments.get("updates", {}),
        )
    elif name == "vault_trigger_agent":
        result = _exec_trigger_agent(
            arguments.get("agent", ""),
            arguments.get("args", ""),
        )
    elif name == "vault_log_decision":
        result = _exec_log_decision(
            arguments.get("title", ""),
            arguments.get("decided", ""),
            arguments.get("why", ""),
            arguments.get("rejected", ""),
            arguments.get("check_later", ""),
        )
    elif name == "vault_send_telegram":
        result = _exec_send_telegram(arguments.get("message", ""))
    elif name == "vault_advisor_ask":
        result = _exec_advisor_ask(
            arguments.get("question", ""),
            arguments.get("mode", "ask"),
        )
    else:
        result = f"Unknown tool: {name}"

    return [TextContent(type="text", text=result)]


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
