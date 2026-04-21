"""
vault-lib.py — Shared Python library for the vault agent system.

== WHAT THIS IS ==

This is the Python-side equivalent of invoke-agent.sh. It provides LLM
invocation with streaming support via the Anthropic Python SDK, plus shared
utilities used by multiple Python entry points.

== WHO IMPORTS THIS ==

  - vault-bot.py (Telegram bot) — for SDK streaming of Advisor responses
  - vault-mcp-server.py (MCP server, future) — for Claude App / ChatGPT access

vault-bot.py imports this via importlib because the filename has a hyphen:
    spec = importlib.util.spec_from_file_location("vault_lib", "vault-lib.py")

== HOW LLM CALLS WORK ==

Two execution paths exist (both read agent-runtimes.conf):

  1. SDK path (this file): vault-bot.py calls invoke_llm() which calls the
     Anthropic API directly. Supports streaming (on_chunk callback).
     Requires API credits and ~/.anthropic/api_key.

  2. CLI path (invoke-agent.sh): Bash scripts call invoke-agent.sh which
     runs `claude` or `codex` CLI. No streaming. Covered by Max subscription.

invoke_llm() tries SDK first. If it fails (no API key, no credits, rate
limit, non-claude runtime), it falls back to subprocess + invoke-agent.sh.

== CONFIG FORMAT (agent-runtimes.conf) ==

  AGENT=runtime                     # Single runtime
  AGENT=runtime1,runtime2           # Fallback chain (try first, then second)
  AGENT_MODE=runtime                # Per-mode override
  runtime = claude | claude:model | codex
  model = opus | sonnet | haiku | <full-model-id>

Resolution: AGENT_MODE > AGENT > default "claude"

== BILLING ==

Current setup (Option 3):
  - Max subscription ($100/month) covers Claude CLI for all agents
  - Small API credits (~$5/month) cover Haiku triage for fast Telegram UX
  - To go API-only: uncomment ADVISOR_ASK/STRATEGY overrides, drop Max to Pro ($20)
  - To go CLI-only: comment out ADVISOR_TRIAGE, no API needed

== KEY FUNCTIONS ==

  invoke_llm()           — async LLM call (SDK streaming or subprocess fallback)
  resolve_runtime()      — read agent-runtimes.conf, resolve agent+mode to runtime
  resolve_model()        — "claude:haiku" → "claude-haiku-4-5-20251001"
  build_advisor_prompt() — assemble full Advisor prompt with vault context
  convert_wikilinks()    — [[Note Name]] → obsidian:// deep links
  parse_frontmatter()    — extract YAML frontmatter from .md files
  parse_advisor_output() — split ---RESPONSE---/---TRIGGERS---/---END--- blocks
  log_token_usage()      — append to Meta/analytics/token-usage.jsonl
"""

import os
import re
import json
import asyncio
import subprocess
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional, Callable, List, Tuple
from urllib.parse import quote

logger = logging.getLogger("vault-lib")

# --- Config ---
VAULT_DIR = os.environ.get(
    "VAULT_DIR",
    "${VAULT_DIR:-$HOME/VaultSandbox}",
)
SCRIPTS_DIR = os.path.join(VAULT_DIR, "Meta", "scripts")
OBSIDIAN_VAULT = "VaultSandbox"
CONFIG_FILE = os.environ.get(
    "AGENT_RUNTIME_CONFIG",
    os.path.join(VAULT_DIR, "Meta", "agent-runtimes.conf"),
)
INVOKE_AGENT_SH = os.path.join(SCRIPTS_DIR, "invoke-agent.sh")
API_KEY_FILE = os.path.expanduser("~/.anthropic/api_key")
TOKEN_LOG_FILE = os.path.join(VAULT_DIR, "Meta", "analytics", "token-usage.jsonl")

# Model ID mapping (matches invoke-agent.sh)
MODEL_MAP = {
    "opus": "claude-opus-4-6",
    "sonnet": "claude-sonnet-4-6",
    "haiku": "claude-haiku-4-5-20251001",
}

# Default model when none specified
DEFAULT_MODEL = "claude-sonnet-4-6"


# ── Anthropic client (lazy init) ─────��────────────────────────────────

_anthropic_client = None


def _get_client():
    """Get or create the async Anthropic client. Reads API key from file."""
    global _anthropic_client
    if _anthropic_client is not None:
        return _anthropic_client

    try:
        import anthropic
    except ImportError:
        logger.error("anthropic package not installed. Run: pip3 install anthropic")
        return None

    # Read API key: env var first, then file
    api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not api_key and os.path.exists(API_KEY_FILE):
        with open(API_KEY_FILE, "r") as f:
            api_key = f.read().strip()

    if not api_key:
        logger.error("No Anthropic API key found. Set ANTHROPIC_API_KEY or create ~/.anthropic/api_key")
        return None

    _anthropic_client = anthropic.AsyncAnthropic(api_key=api_key)
    return _anthropic_client


# ── Config parsing (mirrors invoke-agent.sh logic) ────────────────────

def _parse_config():
    """Parse agent-runtimes.conf into a dict.

    Format: KEY=value (one per line, # comments, blank lines ignored).
    Returns dict like {"ADVISOR": "claude", "ADVISOR_TRIAGE": "claude:haiku", ...}
    """
    config = {}
    if not os.path.exists(CONFIG_FILE):
        return config
    with open(CONFIG_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key and value:
                    config[key] = value
    return config


def resolve_runtime(agent: str, mode: str = "") -> str:
    """Resolve which runtime to use for an agent+mode.

    Mirrors invoke-agent.sh logic:
      1. Check mode-specific override (e.g., ADVISOR_TRIAGE)
      2. Check agent-level config (e.g., ADVISOR)
      3. Default to "claude"

    Always re-reads config (no cache) so changes take effect immediately.
    """
    config = _parse_config()
    agent_key = agent.upper().replace("-", "_")

    # Mode-specific override first
    if mode:
        mode_key = f"{agent_key}_{mode.upper().replace('-', '_')}"
        if mode_key in config:
            return config[mode_key]

    # Agent-level config
    if agent_key in config:
        return config[agent_key]

    # Default
    return "claude"


def resolve_model(runtime_spec: str) -> str:
    """Convert runtime spec to model ID.

    "claude" -> DEFAULT_MODEL
    "claude:opus" -> "claude-opus-4-6"
    "claude:sonnet" -> "claude-sonnet-4-6"
    "claude:haiku" -> "claude-haiku-4-5-20251001"
    "claude:some-full-id" -> "some-full-id" (pass-through)
    """
    if ":" not in runtime_spec:
        return DEFAULT_MODEL

    _, _, model = runtime_spec.partition(":")
    return MODEL_MAP.get(model, model)


# ── Token usage logging ─────────���─────────────────────────────────────

def log_token_usage(
    model: str,
    input_tokens: int,
    output_tokens: int,
    agent: str = "",
    mode: str = "",
):
    """Append token usage to Meta/analytics/token-usage.jsonl."""
    try:
        os.makedirs(os.path.dirname(TOKEN_LOG_FILE), exist_ok=True)
        entry = {
            "ts": datetime.utcnow().isoformat() + "Z",
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "agent": agent,
            "mode": mode,
        }
        with open(TOKEN_LOG_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        logger.warning(f"Failed to log token usage: {e}")


# ── invoke_llm — the core function ───────────���───────────────────────

# ── Vault Tools (used by Advisor tool-use + MCP server) ─────────────

VAULT_TOOLS = [
    {
        "name": "vault_grep",
        "description": "Search vault files for a term. Returns matching lines with file paths.",
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search term"},
                "directories": {
                    "type": "array", "items": {"type": "string"},
                    "description": "Directories to search (relative to vault root)",
                },
                "max_results": {"type": "integer", "default": 20},
            },
            "required": ["query"],
        },
    },
    {
        "name": "vault_read_note",
        "description": "Read a specific note by file path or fuzzy name.",
        "input_schema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "File path or note name"}},
            "required": ["path"],
        },
    },
    {
        "name": "vault_list_actions",
        "description": "List actions with optional status filter. Returns name, status, priority, due.",
        "input_schema": {
            "type": "object",
            "properties": {
                "status": {"type": "string", "description": "Filter: open, in-progress, done, dropped"},
                "limit": {"type": "integer", "default": 15},
            },
        },
    },
    {
        "name": "vault_recent_changes",
        "description": "Show recently modified vault files via git log.",
        "input_schema": {
            "type": "object",
            "properties": {
                "days": {"type": "integer", "default": 3},
                "directory": {"type": "string"},
            },
        },
    },
    {
        "name": "vault_check_status",
        "description": "Read frontmatter of an action by name. Returns all YAML fields.",
        "input_schema": {
            "type": "object",
            "properties": {"action_name": {"type": "string"}},
            "required": ["action_name"],
        },
    },
]


def _validate_vault_path(path: str) -> bool:
    """Reject paths that escape the vault directory."""
    if ".." in path:
        return False
    resolved = os.path.realpath(os.path.join(VAULT_DIR, path))
    return resolved.startswith(os.path.realpath(VAULT_DIR))


def _tool_vault_grep(query: str, directories: list = None, max_results: int = 20) -> str:
    if directories is None:
        directories = ["Canon", "Thinking"]
    search_paths = []
    for d in directories:
        if not _validate_vault_path(d):
            continue
        full = os.path.join(VAULT_DIR, d)
        if os.path.isdir(full):
            search_paths.append(full)
    if not search_paths:
        return "No valid directories to search."
    try:
        result = subprocess.run(
            ["grep", "-ril", "--include=*.md", query] + search_paths,
            capture_output=True, text=True, timeout=10,
        )
        files = [f.replace(VAULT_DIR + "/", "") for f in result.stdout.strip().split("\n") if f]
        if not files:
            return f"No results for '{query}'."
        output = []
        for fpath in files[:max_results]:
            try:
                gl = subprocess.run(
                    ["grep", "-in", "-m1", query, os.path.join(VAULT_DIR, fpath)],
                    capture_output=True, text=True, timeout=5,
                )
                output.append(f"  {fpath}: {gl.stdout.strip()}")
            except Exception:
                output.append(f"  {fpath}")
        return f"Found {len(files)} files matching '{query}':\n" + "\n".join(output)
    except Exception as e:
        return f"Search failed: {e}"


def _tool_vault_read_note(path: str) -> str:
    full = os.path.join(VAULT_DIR, path)
    if os.path.isfile(full) and _validate_vault_path(path):
        try:
            with open(full) as f:
                content = f.read()
            return content[:2000]
        except Exception as e:
            return f"Error reading {path}: {e}"
    search_name = path.lower().replace(".md", "")
    for root_dir in ["Canon", "Thinking", "Meta/AI-Reflections"]:
        base = os.path.join(VAULT_DIR, root_dir)
        if not os.path.isdir(base):
            continue
        for dirpath, _, filenames in os.walk(base):
            for fname in filenames:
                if fname.endswith(".md") and search_name in fname.lower():
                    fpath = os.path.join(dirpath, fname)
                    try:
                        with open(fpath) as f:
                            content = f.read()
                        rel = fpath.replace(VAULT_DIR + "/", "")
                        return f"Found: {rel}\n\n{content}"[:2000]
                    except Exception:
                        continue
    return f"Note not found: '{path}'."


def _tool_vault_list_actions(status: str = None, limit: int = 15) -> str:
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    if not os.path.isdir(actions_dir):
        return "No Canon/Actions/ directory found."
    results = []
    for dirpath, _, filenames in os.walk(actions_dir):
        for fname in sorted(filenames):
            if not fname.endswith(".md"):
                continue
            try:
                fm = parse_frontmatter(os.path.join(dirpath, fname))
                if status and fm.get("status", "") != status:
                    continue
                name = fm.get("name", fname.replace(".md", ""))
                line = f"  {name} | status: {fm.get('status', '?')} | priority: {fm.get('priority', '?')}"
                due = fm.get("due", "")
                if due:
                    line += f" | due: {due}"
                enr = fm.get("enrichment_status", "")
                if enr:
                    line += f" | enrichment: {enr}"
                results.append(line)
            except Exception:
                continue
            if len(results) >= limit:
                break
    if not results:
        return f"No actions found{' with status=' + status if status else ''}."
    return f"Actions ({len(results)}):\n" + "\n".join(results)


def _tool_vault_recent_changes(days: int = 3, directory: str = None) -> str:
    cmd = ["git", "-C", VAULT_DIR, "log", f"--since={days} days ago",
           "--name-only", "--format=%h %s (%ar)", "--diff-filter=ACMR"]
    if directory and _validate_vault_path(directory):
        cmd += ["--", directory]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        output = result.stdout.strip()
        return output[:2000] if output else f"No changes in the last {days} days."
    except Exception as e:
        return f"Git log failed: {e}"


def _tool_vault_check_status(action_name: str) -> str:
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    search = action_name.lower()
    for dirpath, _, filenames in os.walk(actions_dir):
        for fname in filenames:
            if fname.endswith(".md") and search in fname.lower():
                try:
                    fm = parse_frontmatter(os.path.join(dirpath, fname))
                    rel = os.path.join(dirpath, fname).replace(VAULT_DIR + "/", "")
                    lines = [f"Action: {rel}"]
                    for k, v in fm.items():
                        lines.append(f"  {k}: {v}")
                    return "\n".join(lines)
                except Exception as e:
                    return f"Error reading {fname}: {e}"
    return f"Action not found: '{action_name}'."


def execute_vault_tool(name: str, input_dict: dict) -> str:
    """Dispatch a vault tool call to the appropriate executor."""
    executors = {
        "vault_grep": lambda a: _tool_vault_grep(a.get("query", ""), a.get("directories"), a.get("max_results", 20)),
        "vault_read_note": lambda a: _tool_vault_read_note(a.get("path", "")),
        "vault_list_actions": lambda a: _tool_vault_list_actions(a.get("status"), a.get("limit", 15)),
        "vault_recent_changes": lambda a: _tool_vault_recent_changes(a.get("days", 3), a.get("directory")),
        "vault_check_status": lambda a: _tool_vault_check_status(a.get("action_name", "")),
    }
    executor = executors.get(name)
    if not executor:
        return f"Unknown tool: {name}"
    try:
        return executor(input_dict)
    except Exception as e:
        return f"Tool error ({name}): {e}"


async def invoke_llm(
    prompt: str,
    agent: str = "ADVISOR",
    mode: str = "",
    stream: bool = True,
    on_chunk=None,
    on_tool_use=None,
    max_retries: int = 3,
    system_prompt: str = "",
    tools: list = None,
) -> str:
    """Call an LLM with streaming support.

    Reads agent-runtimes.conf to determine runtime.
    If runtime is claude-based, uses Anthropic SDK directly.
    Otherwise falls back to invoke-agent.sh subprocess.

    Args:
        prompt: The user prompt
        agent: Agent name (e.g., "ADVISOR", "MIRROR")
        mode: Mode override (e.g., "triage", "feedback")
        stream: Enable streaming (only for claude runtimes)
        on_chunk: Callback(chunk_text, full_text_so_far) for streaming
        max_retries: Retry count for rate limits
        system_prompt: Optional system prompt (prepended)

    Returns:
        The complete LLM response text.
    """
    runtime_chain = resolve_runtime(agent, mode)

    # Try each provider in the fallback chain
    providers = [p.strip() for p in runtime_chain.split(",") if p.strip()]

    for i, provider_spec in enumerate(providers):
        provider = provider_spec.split(":")[0] if ":" in provider_spec else provider_spec

        if provider == "claude":
            result = await _call_claude_sdk(
                prompt=prompt,
                runtime_spec=provider_spec,
                agent=agent,
                mode=mode,
                stream=stream,
                on_chunk=on_chunk,
                on_tool_use=on_tool_use,
                max_retries=max_retries,
                system_prompt=system_prompt,
                tools=tools,
            )
            if result is not None:
                return result
            logger.warning(f"{provider_spec} failed for {agent}, trying next")
        else:
            # Non-API runtime: fall back to invoke-agent.sh
            result = await _call_subprocess(agent, prompt, mode)
            if result is not None:
                return result
            logger.warning(f"{provider_spec} failed for {agent}, trying next")

    logger.error(f"All runtimes failed for {agent} (chain: {runtime_chain})")
    return ""


async def _call_claude_sdk(
    prompt: str,
    runtime_spec: str,
    agent: str = "",
    mode: str = "",
    stream: bool = True,
    on_chunk=None,
    on_tool_use=None,
    max_retries: int = 3,
    system_prompt: str = "",
    tools: list = None,
) -> Optional[str]:
    """Call Anthropic API via SDK. Returns None on failure (triggers fallback).

    When tools are provided, runs a tool-use loop: non-streaming rounds
    execute tools and re-call the API until the model stops requesting tools
    (max 5 iterations). Only the final text response is streamed.
    """
    import anthropic

    client = _get_client()
    if client is None:
        return None

    model = resolve_model(runtime_spec)
    messages = [{"role": "user", "content": prompt}]
    kwargs = {
        "model": model,
        "max_tokens": 4096,
        "messages": messages,
    }
    if system_prompt:
        kwargs["system"] = system_prompt
    if tools:
        kwargs["tools"] = tools

    for attempt in range(max_retries):
        try:
            if tools:
                # Tool-use loop: non-streaming rounds until no more tool calls
                return await _tool_use_loop(
                    client, kwargs, agent, mode, on_chunk, on_tool_use,
                    max_iterations=5,
                )
            elif stream and on_chunk:
                return await _stream_claude(client, kwargs, agent, mode, on_chunk)
            else:
                return await _call_claude_sync(client, kwargs, agent, mode)

        except anthropic.RateLimitError:
            if attempt < max_retries - 1:
                wait = 2 ** attempt
                logger.warning(f"Rate limited, retrying in {wait}s (attempt {attempt + 1})")
                await asyncio.sleep(wait)
                continue
            logger.error("Rate limit exceeded after all retries")
            return None

        except anthropic.APIStatusError as e:
            if e.status_code == 529 and attempt < max_retries - 1:
                wait = 2 ** attempt
                logger.warning(f"API overloaded (529), retrying in {wait}s")
                await asyncio.sleep(wait)
                continue
            logger.error(f"API error: {e}")
            return None

        except anthropic.AuthenticationError as e:
            logger.error(f"Authentication failed: {e}")
            return None

        except Exception as e:
            logger.error(f"Unexpected error calling Claude SDK: {e}")
            return None

    return None


async def _tool_use_loop(
    client, kwargs, agent, mode, on_chunk, on_tool_use, max_iterations=5,
) -> str:
    """Run tool-use loop: call API, execute tools, re-call until done.

    Non-streaming during tool rounds. Streams the final text response.
    """
    total_input = 0
    total_output = 0

    for iteration in range(max_iterations):
        response = await client.messages.create(**kwargs)

        if response.usage:
            total_input += response.usage.input_tokens
            total_output += response.usage.output_tokens

        # Check for tool_use blocks
        tool_uses = [b for b in response.content if b.type == "tool_use"]

        if not tool_uses:
            # No tool calls, extract final text
            text = ""
            for block in response.content:
                if hasattr(block, "text"):
                    text += block.text
            log_token_usage(kwargs["model"], total_input, total_output, agent, mode)

            # Stream the final text if callback provided
            if on_chunk and text:
                await on_chunk(text, text)

            return text

        # Execute tool calls
        tool_results = []
        for tu in tool_uses:
            try:
                tool_name = tu.name
                tool_input = tu.input if isinstance(tu.input, dict) else {}

                # Notify caller what we're checking
                if on_tool_use:
                    # Generate human-friendly description
                    desc = _tool_use_description(tool_name, tool_input)
                    await on_tool_use(tool_name, desc)

                result_text = execute_vault_tool(tool_name, tool_input)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "content": result_text,
                })
            except Exception as e:
                logger.warning(f"Tool execution failed ({tu.name}): {e}")
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": tu.id,
                    "content": f"Tool error: {e}",
                    "is_error": True,
                })

        # Append assistant response + tool results to conversation
        kwargs["messages"].append({"role": "assistant", "content": response.content})
        kwargs["messages"].append({"role": "user", "content": tool_results})

    # Max iterations reached, extract whatever text we have
    logger.warning(f"Tool-use loop hit max iterations ({max_iterations}) for {agent}")
    text = ""
    for block in response.content:
        if hasattr(block, "text"):
            text += block.text
    log_token_usage(kwargs["model"], total_input, total_output, agent, mode)
    return text or "I wasn't able to complete the lookup. Let me answer with what I know."


def _tool_use_description(tool_name: str, tool_input: dict) -> str:
    """Generate a human-friendly description of what the Advisor is checking."""
    descriptions = {
        "vault_grep": lambda i: f"Searching for '{i.get('query', '?')}'...",
        "vault_read_note": lambda i: f"Reading '{i.get('path', '?')}'...",
        "vault_list_actions": lambda i: f"Checking your actions{' (' + i['status'] + ')' if i.get('status') else ''}...",
        "vault_recent_changes": lambda i: f"Looking at recent changes...",
        "vault_check_status": lambda i: f"Checking '{i.get('action_name', '?')}' status...",
    }
    fn = descriptions.get(tool_name)
    return fn(tool_input) if fn else f"Checking vault..."


async def _stream_claude(client, kwargs, agent, mode, on_chunk) -> str:
    """Stream a Claude response, calling on_chunk for each text delta."""
    full_response = ""
    input_tokens = 0
    output_tokens = 0

    async with client.messages.stream(**kwargs) as stream_obj:
        async for event in stream_obj:
            if hasattr(event, "type"):
                if event.type == "content_block_delta" and hasattr(event.delta, "text"):
                    chunk = event.delta.text
                    full_response += chunk
                    if on_chunk:
                        await on_chunk(chunk, full_response)
                elif event.type == "message_delta" and hasattr(event, "usage"):
                    output_tokens = getattr(event.usage, "output_tokens", 0)

        # Get final message for usage stats
        final = await stream_obj.get_final_message()
        if final and final.usage:
            input_tokens = final.usage.input_tokens
            output_tokens = final.usage.output_tokens

    log_token_usage(kwargs["model"], input_tokens, output_tokens, agent, mode)
    return full_response


async def _call_claude_sync(client, kwargs, agent, mode) -> str:
    """Non-streaming Claude call."""
    response = await client.messages.create(**kwargs)
    text = response.content[0].text if response.content else ""

    if response.usage:
        log_token_usage(
            kwargs["model"],
            response.usage.input_tokens,
            response.usage.output_tokens,
            agent,
            mode,
        )
    return text


async def _call_subprocess(agent: str, prompt: str, mode: str = "") -> Optional[str]:
    """Fall back to invoke-agent.sh for non-API runtimes (codex, etc.)."""
    if not os.path.exists(INVOKE_AGENT_SH):
        logger.error(f"invoke-agent.sh not found at {INVOKE_AGENT_SH}")
        return None

    cmd = ["/bin/bash", INVOKE_AGENT_SH, agent, prompt]
    if mode:
        cmd.append(mode)

    try:
        result = await asyncio.to_thread(
            subprocess.run,
            cmd,
            capture_output=True,
            text=True,
            timeout=300,
            cwd=VAULT_DIR,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            logger.warning(f"invoke-agent.sh failed (exit {result.returncode}): {result.stderr[:200]}")
            return None
    except subprocess.TimeoutExpired:
        logger.error(f"invoke-agent.sh timed out for {agent}")
        return None
    except Exception as e:
        logger.error(f"subprocess error: {e}")
        return None


# ── Wikilink conversion ──────────────���────────────────────────────────

_wikilink_pattern = re.compile(r'\[\[([^\]]+)\]\]')


def convert_wikilinks(text: str) -> str:
    """Convert [[Note Name]] wikilinks to clickable Obsidian deep links.

    Searches Canon subdirectories for matching files.
    Falls back to search-based Obsidian URL if not found.
    """
    def _replace_wikilink(match):
        note_name = match.group(1)
        # Search common Canon directories
        for subdir in ["Actions", "People", "Events", "Concepts", "Decisions",
                       "Projects", "Organizations", "Places"]:
            candidate = os.path.join(VAULT_DIR, "Canon", subdir, f"{note_name}.md")
            if os.path.exists(candidate):
                rel_path = f"Canon/{subdir}/{note_name}"
                encoded = quote(rel_path, safe="")
                url = f"obsidian://open?vault={OBSIDIAN_VAULT}&file={encoded}"
                return f"[{note_name}]({url})"
        # Check Thinking/ and Inbox/
        for subdir in ["Thinking", "Inbox"]:
            candidate = os.path.join(VAULT_DIR, subdir, f"{note_name}.md")
            if os.path.exists(candidate):
                rel_path = f"{subdir}/{note_name}"
                encoded = quote(rel_path, safe="")
                url = f"obsidian://open?vault={OBSIDIAN_VAULT}&file={encoded}"
                return f"[{note_name}]({url})"
        # Fallback: search URL
        encoded = quote(note_name, safe="")
        url = f"obsidian://search?vault={OBSIDIAN_VAULT}&query={encoded}"
        return f"[{note_name}]({url})"

    return _wikilink_pattern.sub(_replace_wikilink, text)


# ── Frontmatter parsing ─────���────────────────────────────────────────

def parse_frontmatter(filepath: str) -> dict:
    """Extract YAML frontmatter fields from a .md file.

    Returns dict of key: value pairs. Handles simple YAML only
    (no nested objects, arrays are returned as strings).
    """
    result = {}
    try:
        with open(filepath, "r") as f:
            lines = f.readlines()
    except (FileNotFoundError, PermissionError):
        return result

    if not lines or lines[0].strip() != "---":
        return result

    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key:
                result[key] = value

    return result


# ── Structured output parsing ───���─────────────────────────────────────

def parse_advisor_output(text: str) -> Tuple[str, List[str]]:
    """Parse Advisor structured output.

    Expected format:
        ---RESPONSE---
        [conversational text]
        ---TRIGGERS---
        EXTRACT: filepath
        RESEARCH: topic
        ---END---

    Returns (response_text, list_of_trigger_lines).
    If no delimiters found, returns (text, []).
    """
    response = text
    triggers = []

    if "---RESPONSE---" in text:
        parts = text.split("---RESPONSE---", 1)
        rest = parts[1] if len(parts) > 1 else ""

        if "---TRIGGERS---" in rest:
            resp_part, trigger_part = rest.split("---TRIGGERS---", 1)
            response = resp_part.strip()
            # Remove ---END--- if present
            trigger_part = trigger_part.split("---END---")[0]
            triggers = [
                line.strip()
                for line in trigger_part.strip().split("\n")
                if line.strip()
            ]
        else:
            # No triggers section
            response = rest.split("---END---")[0].strip()
    elif "---TRIGGERS---" in text:
        # Response before triggers, no explicit ---RESPONSE--- marker
        resp_part, trigger_part = text.split("---TRIGGERS---", 1)
        response = resp_part.strip()
        trigger_part = trigger_part.split("---END---")[0]
        triggers = [
            line.strip()
            for line in trigger_part.strip().split("\n")
            if line.strip()
        ]

    return response, triggers


# ── Advisor prompt building ──────────────────────────────────────────

def _read_file(path: str, max_lines: int = 0) -> str:
    """Read a file, optionally limiting to first N lines."""
    try:
        with open(path, "r") as f:
            if max_lines > 0:
                return "".join(f.readlines()[:max_lines])
            return f.read()
    except (FileNotFoundError, PermissionError):
        return ""


def _list_actions_summary() -> str:
    """Get a compact list of actions with status."""
    actions_dir = os.path.join(VAULT_DIR, "Canon", "Actions")
    lines = []
    if not os.path.isdir(actions_dir):
        return ""
    for fname in sorted(os.listdir(actions_dir)):
        if not fname.endswith(".md"):
            continue
        fpath = os.path.join(actions_dir, fname)
        fm = parse_frontmatter(fpath)
        name = fname.replace(".md", "")
        status = fm.get("status", "unknown")
        # Skip sub-actions (have parent_action field)
        if fm.get("parent_action"):
            continue
        lines.append(f"- {name} ({status})")
    return "\n".join(lines)


def _recent_inbox_notes(count: int = 3) -> str:
    """Get headers of recent Inbox notes."""
    inbox_dir = os.path.join(VAULT_DIR, "Inbox")
    if not os.path.isdir(inbox_dir):
        return ""
    files = sorted(
        [f for f in os.listdir(inbox_dir) if f.endswith(".md")],
        reverse=True,
    )[:count]
    parts = []
    for fname in files:
        fpath = os.path.join(inbox_dir, fname)
        content = _read_file(fpath, max_lines=5)
        parts.append(f"=== {fname} ===\n{content}")
    return "\n".join(parts)


def build_advisor_prompt(query: str, mode: str = "triage") -> str:
    """Build the full Advisor prompt with vault context.

    Mirrors the context assembly in run-advisor.sh so the SDK path
    gets the same quality responses as the CLI path.

    Modes:
      - triage: minimal context (~2K tokens) for fast response
      - ask: medium context (~4K tokens)
      - strategy: full context (~6K tokens)
      - feedback: minimal context for agent commentary
    """
    # Always load knowledge file
    knowledge = _read_file(os.path.join(VAULT_DIR, "Meta", "Agents", "advisor-knowledge.md"))

    if mode == "triage":
        actions = _list_actions_summary()
        recent = _recent_inbox_notes(3)

        return f"""You are Usman's strategic consultant. You know him deeply (see knowledge below).

## YOUR KNOWLEDGE
{knowledge}

## RECENT CONTEXT
{recent}

## OPEN ACTIONS
{actions}

## USER JUST SAID
{query}

## YOUR JOB (TRIAGE — be fast, warm, actionable)
1. Acknowledge what Usman said — like a real person who cares
2. Connect to what you know about him if relevant (reference specific actions, people, patterns)
3. Decide what should happen next:
   - If this is a substantial thought/reflection → respond thoughtfully (2-4 sentences)
   - If this is strategic/emotional/a debrief → respond with empathy AND insight
   - If this is just a note to save → warm acknowledgment (1 sentence)
   - If this is a question → answer it directly if you can
4. Keep it SHORT unless the topic demands depth. Usman has ADHD.
5. End with what happens next or just warmth.

ANTI-SLOP RULES:
- NEVER say "I hear you", "That's valid", "It sounds like you're feeling"
- NEVER start with "Great question!" or "That's a really interesting point"
- Reference SPECIFIC vault notes by [[wikilink name]], never "your goals"
- Use Usman's own language back at him
- Max response: 4 sentences for triage
- Don't ask multiple questions. ONE question max.
- Don't hedge. Be direct.
- Match his register: warm, direct, slightly informal."""

    elif mode == "feedback":
        return f"""You are Usman's strategic consultant. Agents just completed some work. Add your perspective.

## YOUR KNOWLEDGE
{knowledge}

## WHAT JUST HAPPENED
{query}

## YOUR JOB
- If the agent work is interesting/relevant: comment briefly (1-3 sentences). Connect to what you know.
- If it's routine (QA pass, manifest rebuild): say nothing. Return empty response.
- If it reveals a pattern: flag it warmly.
- NEVER just repeat what the agent said. Add YOUR perspective."""

    else:
        # ask / strategy — fuller context
        actions = _list_actions_summary()
        decisions_summary = _read_file(os.path.join(VAULT_DIR, "Meta", "decisions-summary.md"))
        style_guide = _read_file(os.path.join(VAULT_DIR, "Meta", "style-guide.md"), max_lines=80)

        # Load beliefs
        beliefs = ""
        beliefs_dir = os.path.join(VAULT_DIR, "Canon", "Beliefs")
        if os.path.isdir(beliefs_dir):
            for fname in os.listdir(beliefs_dir):
                if fname.endswith(".md"):
                    beliefs += f"=== {fname} ===\n{_read_file(os.path.join(beliefs_dir, fname))}\n"

        mode_instruction = "strategic analysis" if mode == "strategy" else "thoughtful response"

        return f"""You are Usman's strategic consultant — a blend of Roger Martin, Bezos-level thinking, and empathetic coaching. You know him deeply.

## YOUR KNOWLEDGE
{knowledge}

## OPEN ACTIONS
{actions}

## DECISIONS SUMMARY
{decisions_summary}

## BELIEFS
{beliefs}

## STYLE GUIDE
{style_guide}

## USER'S QUESTION/TOPIC
{query}

## YOUR JOB ({mode_instruction})
- Give a direct, {mode_instruction} grounded in what you know about Usman
- Reference specific vault notes with [[wikilinks]]
- Connect to his goals, patterns, and open actions
- Be warm but direct. No corporate speak. No hedging.
- For strategy: provide concrete options with tradeoffs
- For questions: answer directly, then add your perspective
- ONE question at a time if you ask a follow-up
- Usman has ADHD — keep it focused, no walls of text

VAULT TOOLS: You have tools to look things up in the vault ON DEMAND. Use them when you need to check a specific fact, action status, person detail, or recent change that isn't in the context above. Don't guess — look it up. But don't use tools for things already provided in the context."""
