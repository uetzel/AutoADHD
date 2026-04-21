---
type: meta
name: Engineering Working Agreement
created: 2026-03-26
updated: 2026-04-06
source: ai-generated
status: active
---

# Engineering Working Agreement

This document defines how code and automation changes should be made in this vault.

The goal is simple: make good changes in small steps, verify them quickly, and avoid losing work.

## Default Principles

1. **TDD by default for non-trivial code changes.**
   Start with a failing or missing test when behavior changes, then make the smallest change that turns it green.
2. **Small batches.**
   Prefer small, focused commits over broad mixed changes.
3. **Refactor continuously.**
   Improve structure while behavior stays protected by tests.
4. **Continuous integration is mandatory.**
   The same checks should run locally and in CI.
5. **Shared ownership, clear boundaries.**
   Claude and Codex can both contribute, but only one write path should own a given change at a time.
6. **Main stays stable.**
   Script and tooling changes go through a branch and CI before merge.

## Required Workflow For Code And Tooling Changes

Use this sequence for changes under `Meta/scripts/`, CI config, tests, and related tooling:

1. Write or update a test first when the behavior is changing.
2. Make the smallest implementation change that satisfies the test.
3. Run `make check`.
4. Keep the diff scoped to one concern.
5. Merge only after checks pass.

If a change is too small for a meaningful new test, at minimum it must preserve or improve the existing verification suite.

## Required Workflow For Agent Content Runs

Agent content runs are different from code changes:

- Extractor, Reviewer, and similar content agents may run on `main` only when the worktree is clean.
- Runner scripts must refuse to run on a dirty worktree unless explicitly overridden.
- Runner scripts may ignore known operational noise only if that noise is intentionally non-source state (for example `.obsidian/workspace.json`) or a runner-managed audit file.
- Runner scripts must never use blanket staging that can capture unrelated edits.
- One agent pipeline may write at a time.
- Runner-owned metadata such as changelog entries should be written before the final scoped commit so one run lands as one coherent commit when possible.
- Agents should read source files by path rather than receiving large pasted context blobs whenever possible.
- Voice-triggered pipelines must stay narrow: no opportunistic agent creation, no architecture edits, no research side quests.

## Source Of Truth And Token Discipline

Agent outputs should be both grounded and cheap to run.

Use these defaults:

1. Treat notes, transcripts, book highlights, and verified web pages as source-of-truth artifacts.
2. Pass file paths and reading instructions into prompts instead of pasting full file contents.
3. Prefer one-hop context expansion only; pull more context only when the first pass shows it is needed.
4. Save intermediate results to files and re-read those files, instead of nesting previous full model transcripts into later prompts.
5. Require explicit provenance in outputs:
   - inbox note filename for extraction-derived facts
   - note path or quote note path for Readwise/book material
   - direct URL or local research note for web facts
6. Strip CLI transcript noise before saving model output into the vault.
7. Keep prompts procedural and bounded:
   - which files to read
   - which paths may be modified
   - what final artifact to produce
8. Use small verification passes after writing rather than huge prompts that try to solve everything in one shot.

If an agent cannot point to a source note, source quote, or source URL, it should lower confidence or queue the item for review.

## Shared Libraries (The Glue)

Two shared libraries power all agents. Understanding these is essential for debugging.

### lib-agent.sh (Bash)

Every agent runner script starts with `source "$SCRIPT_DIR/lib-agent.sh"`. It provides:

| Function | What it does |
|----------|-------------|
| `agent_git` | Run git from vault dir with explicit paths (robust in subprocess chains) |
| `agent_require_commands` | Check that required CLI tools exist before running |
| `agent_filtered_worktree_status` | `git status` minus operational noise (`.obsidian/workspace.json`, `_drop/`, `_processed/`, `_extracted/`, `.agent-locks/`, `changelog.md`) |
| `agent_assert_clean_worktree` | Refuse to run if worktree is dirty (override: `VAULT_AGENT_ALLOW_DIRTY=1`) |
| `agent_clear_stale_git_locks` | Remove `index.lock`/`HEAD.lock` if no live git process exists |
| `agent_acquire_lock` | mkdir-based concurrency lock with PID tracking, stale lock detection (max 15 min), opt-in retry (3x, 30s) |
| `agent_release_lock` | Clean up lock dir on exit |

**Concurrency model:** One agent writes at a time, enforced by lock files in `.agent-locks/`. Voice pipeline has opt-in retry (`AGENT_LOCK_RETRY=true`). Stale locks auto-break after 15 minutes or when the owning PID is dead.

### invoke-agent.sh (Bash)

The model-agnostic LLM invocation layer. Called by every agent runner:

```bash
./Meta/scripts/invoke-agent.sh AGENT_NAME "prompt text" [MODE]
```

What it does:
1. Reads `Meta/agent-runtimes.conf` to determine runtime (mode-specific → agent-level → default)
2. Splits comma-separated fallback chains and tries each provider in order
3. For Claude: tries Strategy 1 (OAuth from vault dir) → Strategy 2 (`--bare` + API key from `/tmp`)
4. Uses `--output-format json` to capture token usage
5. Logs to `Meta/agent-token-usage.jsonl` after each call (never fails the agent for logging)
6. Extracts text result from JSON via Python temp file parsing

**Provider format:** `claude`, `claude:opus`, `claude:sonnet`, `claude:haiku`, `codex`

### vault-lib.py (Python)

Shared Python library imported by `vault-bot.py` and `vault-mcp-server.py`:

| Component | What it provides |
|-----------|-----------------|
| `_call_claude_sdk()` | Anthropic SDK streaming with tool-use loop (max 5 iterations) |
| `VAULT_TOOLS` | 5 tool schemas for vault lookup (grep, read, list actions, recent changes, check status) |
| `execute_vault_tool()` | Dispatcher that routes tool calls to filesystem-based executors |
| Config parsing | Reads `agent-runtimes.conf`, resolves runtime chains (same logic as bash) |
| Wikilink helpers | Extract/resolve wikilinks from markdown text |
| Path validation | Security: rejects `..` traversal, validates paths against VAULT_DIR |

---

## Local Commands

These commands are the default entry points:

```bash
make test
make lint
make check
```

`make check` is the required pre-merge command for code and tooling work.

## CI Contract

CI must run the same core checks as local development:

- Python test suite
- Shell syntax validation for agent scripts
- Python compilation checks
- Optional static linting when the tool is available

If local and CI checks drift, fix the tooling so they converge again.

## macOS Compatibility (Hard Rules)

These are portability traps that have caused real production failures. Every script contributor must know them.

### 1. `sed` does not support `\s` — use `[[:space:]]`

macOS ships BSD `sed`, which treats `\s` as literal backslash+s (not whitespace). This silently breaks YAML parsing:

```bash
# WRONG — produces " open" on macOS (literal \s not matched)
status=$(echo "status: open" | sed 's/^status:\s*//')

# CORRECT — POSIX character class, works everywhere
status=$(echo "status: open" | sed 's/^status:[[:space:]]*//')
```

**Impact:** This bug broke ALL YAML field parsing in 3 scripts (71 instances). Task-Enricher found 0 actions for weeks because every status comparison failed.

### 2. No `timeout` command — use `perl -e 'alarm N; exec @ARGV'`

macOS does not ship GNU `timeout`. The command silently fails (especially when stderr is suppressed).

```bash
# WRONG — timeout doesn't exist on macOS
timeout 1800 whisper "$AUDIO" --model medium

# CORRECT — perl alarm is POSIX-compatible, available on every Mac
perl -e 'alarm 1800; exec @ARGV' whisper "$AUDIO" --model medium
```

**Alternative:** `brew install coreutils` provides `gtimeout`, but adds a dependency.

### 3. Never use backticks in double-quoted prompt strings

Backticks inside `"..."` trigger command substitution. Bash will try to execute the backtick content as a command:

```bash
# WRONG — bash executes `status: extracted` as a command
PROMPT="Set \`status: extracted\` in frontmatter"

# CORRECT — just use plain text
PROMPT="Set status: extracted in frontmatter"
```

### 4. Whisper requires explicit `--device mps` for GPU

OpenAI Whisper does NOT auto-detect Apple Silicon GPU. Without `--device mps`, it runs on CPU (3-10x slower for the medium model).

```bash
whisper "$AUDIO" --model medium --device mps
```

Falls back gracefully to CPU if MPS unavailable.

---

## Claude And Codex Split

Current default split (as of 2026-04-06):

- **Claude CLI**: ALL vault agents (covered by Max subscription, $100/month)
- **Codex**: Currently unused for agents (stdin pipe stalls under launchd)
- **Per-agent token tracking**: `Meta/agent-token-usage.jsonl` records cost per agent call

Future migration path:

- Review `agent-token-usage.jsonl` after 7+ days of data
- Move cheap/mechanical agents back to Codex when the pipe issue is resolved
- Preserve the same review gates and provenance requirements during migration

## XP Practices We Expect

- test-first for behavior changes
- frequent integration
- simple design before abstraction
- refactor after green
- collective ownership with explicit handoff
- no long-lived invisible work

## Definition Of Done

A code or tooling change is done only when:

- the behavior is implemented
- relevant tests exist and pass
- `make check` passes
- the change is documented if it affects workflow
- the handoff is clear enough that another agent can continue safely
