---
type: architecture
name: Vault System Architecture
created: 2026-03-23
updated: 2026-04-06
source: ai-generated
owner: "[[Usman Kotwal]]"
status: active
---

# Vault System Architecture

This is the blueprint. Every agent, script, and session reads this to understand how the system works, what it can touch, and how pieces connect. If it's not in here, it doesn't exist yet.

---

## What This System Is

A personal operating system for an ADHD brain. It captures thoughts, connects them, reflects patterns back, and — critically — *executes* on your behalf. You do the thinking and the final "yes." The system does everything in between.

The vault is the brain. Agents are specialized workers. This document is the nervous system.

---

## The Three Laws

1. **Provenance is sacred.** Every fact traces back to a human moment or an explicit source. Break the chain and the system becomes fiction.
2. **Review gates are structural, not advisory.** Critical actions cannot proceed without human approval. This is enforced by code, not by asking nicely in a markdown file.
3. **The system improves itself.** When an agent finds a problem, another agent fixes it. Findings that sit in logs unfixed are a system failure, not a backlog item.

---

## Execution Runtimes

The system runs across four environments. Each has different powers and constraints. Agents must be designed for the runtime they'll operate in.

### Runtime 1: Cowork (Claude Desktop)

**What it is:** Interactive sessions with a human. Ephemeral — dies when the session ends.

**Tools available:**
- Gmail (read, search, draft)
- Google Calendar (CRUD)
- Google Drive (search, fetch)
- Notion (search, create, update)
- Figma (read design context)
- Chrome (full browser automation)
- Scheduled Tasks (create recurring Cowork tasks)
- Full file system access to vault
- Git

**Best for:** Architecture work, deep analysis, complex multi-tool workflows, anything requiring human conversation, prototyping, execution that touches external services.

**Limitation:** Ephemeral. Cannot be scheduled. Requires Usman to be present.

### Runtime 2: Claude Code CLI (Local Mac)

**What it is:** Claude invoked from terminal scripts via `claude` CLI. Persistent — runs via launchd/cron on the Mac.

**Tools available:**
- Full file system (read/write vault files)
- Git (commit, push)
- Bash (run any local command)
- Web search (via Claude's built-in)
- Can invoke other CLI tools (curl, python, node, etc.)

**Best for:** Scheduled agents (Extractor, Reviewer, Thinker, Retro, Briefing), file manipulation, script fixes, vault maintenance, self-healing loop.

**Limitation:** No MCP tools (no Gmail, Calendar, Drive, Notion). Cannot send emails or create calendar events directly. Can draft things into vault files that Cowork or Telegram picks up.

### Runtime 3: Telegram Bot (vault-bot.py)

**What it is:** Persistent Python process on Mac. Two-way: receives voice memos and commands, sends notifications and review prompts. Includes the Advisor agent for conversational interaction.

**Tools available:**
- Telegram messaging (send/receive text, voice, files)
- Voice pipeline (Whisper transcription)
- Vault file read/write
- Can trigger Claude Code CLI scripts
- Review queue management
- Anthropic Python SDK (via vault-lib.py) for streaming Advisor responses
- Agent feedback queue monitoring (JSONL-based)

**Best for:** Human-in-the-loop approvals, daily nudges, voice capture, quick actions (done/drop/snooze), delivering review gate packages, Advisor conversations (triage, /ask, /strategy).

**Limitation:** No direct access to Gmail/Calendar/Drive. Can trigger scripts that draft content, but can't execute external service calls itself.

**Key architecture:** vault-bot.py imports vault-lib.py for SDK streaming. For Advisor calls, it tries the SDK path first (progressive message edits in Telegram), then falls back to CLI subprocess (invoke-agent.sh → run-advisor.sh). All other agents always use CLI subprocess. See "LLM Invocation Layer" section below.

### Runtime 4: OpenAI Codex

**What it is:** OpenAI Codex can operate as a cloud coding agent via git workflows and also as a local CLI runtime on the Mac for selected scripted agents.

**Tools available:**
- Full code execution (Python, Node, Bash, etc.)
- Git (reads repo, can push branches/PRs)
- Web access (can fetch URLs, APIs)
- File creation and manipulation
- Can run tests, linters, build tools

**Best for:** Script improvements (fix run-retro.sh, harden build-manifest.sh), code-heavy vault tooling, parallel analytical passes (different model = different perspective), bulk data processing, prototype generation.

**Limitation:** No MCP tools. No Telegram access directly. Cloud Codex works asynchronously via git; local Codex CLI depends on the local machine being awake and having network plus writable local state.

**Integration pattern:** Codex can either work on a branch via git or be invoked locally through agent runner scripts for selected agents.

### Runtime 5: Vault MCP Server (NEW)

**What it is:** `vault-mcp-server.py` — a Model Context Protocol server exposing vault tools to Claude Desktop, ChatGPT, or any MCP-compatible client.

**Tools available:**
- Read: vault_grep, vault_read_note, vault_list_actions, vault_recent_changes, vault_check_status
- Write: vault_create_note, vault_update_action, vault_trigger_agent, vault_log_decision
- Interaction: vault_send_telegram, vault_advisor_ask

**Best for:** Voice-native interaction (Claude Desktop + TTS), programmatic vault access from any LLM client.

**Limitation:** Runs on localhost only (stdio transport). No streaming. Agent triggers are subprocess-based (waits for completion).

---

## The Agent Registry

Every agent has a defined role, runtime, schedule, and scope. No agent operates outside its scope.

| Agent | Runtime | Schedule | Scope | Status |
|---|---|---|---|---|
| **Extractor** | Claude CLI | On new inbox note | Deep extraction: people, events, concepts, actions, decisions, places | Active |
| **Reviewer** | Claude CLI | After Extractor (conditional) | QA: wikilinks, duplicates, locked fields, provenance, tags. Skipped when Extractor made 0 Canon changes. | Active |
| **Thinker** | Claude CLI | Weekly (Sun) + on-demand | Patterns, contradictions, connections, external research | Active |
| **Briefing** | Claude CLI | Daily 7:30 AM | Surface open/stale actions, recent entries, contextual questions | Active |
| **Retrospective** | Claude CLI | Daily 9:00 PM | Vault health, what worked/didn't, spec improvements | Active |
| **Task-Enricher** | Claude CLI (--scan) + Shell (--morning/--nudge) | Daily 8:30 AM (--morning) + on-demand | Break actions into steps, draft comms, nudge stale items, auto-flag research needs | Active |
| **Implementer** | Claude CLI | After Retro + after Reviewer | Read findings, apply safe fixes, queue dangerous ones for review | Active |
| **Mirror** | Claude CLI | Weekly (in weekly-maintenance.sh after Reviewer) + on-demand | Reflect Usman's patterns, strengths, weaknesses, growth/stagnation | Active |
| **Researcher** | Claude CLI | Daily 9:00 AM scan + on-demand (triggered by Task-Enricher or human) | Multi-perspective research → Thinking/Research/ articles | Active |
| **Operator** | Claude CLI + Telegram + Cowork | On-demand (`/email`, `/calendar`, auto-triage) | Draft deliverable → review gate → execute → done | Active (Email V1 live) |
| **Advisor** | Claude CLI + SDK (Telegram streaming) | Always-on via Telegram + `/ask` `/strategy` | Strategic consultant, triage, coaching, dot-connecting. Dynamic vault lookup via tool_use for /ask and /strategy. | Active |
| **Orchestrator** | Python (vault-bot.py job) | Every 5 min + on `/run` command | Iterative execution: decompose → execute → choice → research → re-enrich → done. State machine in orchestrator.py. | Active |

> **Runtime note (2026-04-06):** All agents run on Claude CLI, covered by Max subscription ($100/month). Per-agent token usage is tracked in `Meta/agent-token-usage.jsonl`. Once cost data is sufficient, cheaper tasks may be moved back to Codex. See `Meta/agent-runtimes.conf` for current routing and per-mode overrides (e.g., Advisor triage uses Haiku via API SDK for speed).

---

## How a Thought Becomes an Action Becomes Done

This is the full lifecycle. Every step has a defined agent and runtime.

```
CAPTURE                    PROCESS                     ENRICH                      RESEARCH (if needed)        EXECUTE                    DONE
───────                    ───────                     ──────                      ────────                   ───────                    ────
Voice memo ──┐
Quick text ──┤             Extractor                   Task-Enricher               Researcher                 Operator
Reflection ──┤──→ Inbox ──→ (Claude CLI, auto) ──→     (Claude CLI+TG, daily)     (Claude CLI, daily 9AM)    (Claude CLI+TG) ──→       Done
WhatsApp ────┤             Canon                  ──→  breaks into steps,     ──→  3 perspectives swarm, ──→ Review ──→
Email ───────┤             extracts entities,          finds contact info,         synthesis + verification,  drafts email/doc/event,    gate
Reading ─────┘             creates Canon entries,      scores priority,            writes to Thinking/        executes via MCP tools,    approved
                           links everything,           detects research needs,     Research/, links back      presents review package    by human
                           adds emoji headings         auto-flags research                                    via Telegram

                           ↓                           ↓                           ↓                          ↓
                           Reviewer (Claude CLI)       Mirror (Claude CLI, weekly) TG notify (non-blocking)   Implementer (Claude CLI)
                           QA pass on extraction       patterns in behavior        human can steer mid-run    fixes what Retro found
                           ↓
                           Retro (Claude CLI, nightly)
                           vault health check
                           ↓
                           Implementer (Claude CLI)
                           applies retro findings
```

### Voice Pipeline Reliability

The voice pipeline (`process-voice-memo.sh`) includes several hardening features:

- **MPS GPU acceleration:** Whisper uses `--device mps` (Apple Silicon Metal Performance Shaders) for 1.5-3x speedup over CPU. Configurable via `WHISPER_DEVICE` env var.
- **Timeout protection:** 30-minute hard timeout via `perl -e 'alarm 1800; exec @ARGV'` (macOS has no `timeout` command — see Engineering.md for details).
- **Progress tracking:** Each stage writes to `Meta/.voice-progress/<slug>.json`. The Telegram bot polls every 10s and edits the status message (transcribing → extracting → reviewing → complete/failed).
- **Conditional reviewer:** Reviewer is skipped when the Extractor made 0 Canon changes (trivial memos, test recordings). When it runs in voice-pipeline mode, it reviews only the specific new note (not all recent notes).
- **Step-level error reporting:** `PIPELINE_STEP` variable tracks the current stage (init → metadata → Whisper → extractor → reviewer → manifest → commit/archive). Errors report which step failed: "extractor failed (exit 1)" instead of generic "exit 1".
- **Note archival:** Extracted notes auto-move to `Inbox/Voice/_extracted/` after commit, keeping `Inbox/Voice/` clean for human scanning.
- **Lock retry:** Voice pipeline has opt-in lock retry (3 attempts, 30s apart) since voice memos are real-time user input and shouldn't silently fail on lock contention.

### The Critical Loop: Self-Healing

The system's biggest failure until now: agents observe problems but nothing fixes them. The **Implementer** closes this loop.

```
Retro finds bug ──→ writes to retro-log.md ──→ Implementer reads retro-log ──→ fixes the bug
                                                                               ├─ safe fix? → apply + commit
                                                                               └─ risky fix? → queue-review.sh → Telegram
```

```
Reviewer flags issue ──→ writes to review-log.md ──→ Implementer reads review-log ──→ fixes the issue
                                                                                     ├─ missing wikilink? → add it
                                                                                     ├─ missing stub entry? → create it
                                                                                     ├─ spec not enforced? → strengthen spec
                                                                                     └─ locked field conflict? → queue for human
```

### The Execution Layer: Workflow-Centric

The system's next frontier: moving from "know and surface" to "act in the world." The unit of value is a **commitment** — something Usman said he'd do or wants done. The core abstraction is a **workflow run**, not a bigger Operator agent.

**Strategy (Playing to Win):**

- **Winning aspiration:** Usman never drops a ball — not because he remembers, but because the system catches, processes, enriches, and executes on every spoken commitment. He only does what only a human can do: decide, relate, create.
- **Where to play:** Execution of commitments via email, calendar, research, and eventually multi-step concierge flows (restaurant booking, travel planning).
- **How to win:** Voice-first, approve-only. Multi-step workflow chains with the right review gate at each junction. The system knows when it's stuck and surfaces a concrete ask, not a vague review burden.

**Five workflow types (sequential rollout):**

| Workflow | Trigger | Steps | Status |
|----------|---------|-------|--------|
| A: Thought → Knowledge | Voice memo arrives | Transcribe → Extract → Review → Canon | ✅ Built |
| B: Knowledge → Awareness | Briefing schedule / Telegram | Canon → Briefing → Push to channels | ✅ Built |
| C: Knowledge → Research | Action tagged needs-research | Researcher → 3-perspective article → Enrichment scatters into vault | ✅ Built |
| D: Knowledge → Execution | `/email`, `/calendar`, or auto-triage | Draft → Review gate → Execute via MCP/SMTP → Done | ✅ Built (Email V1) |
| E: Execution → Learning | Post-execution feedback | System asks "how did it go?" → Feeds back to Canon | Planned |

**Workflow D detail — the execution pattern:**

```
Trigger (manual /email or auto-triage)
    ↓
run-<type>-workflow.sh reads Canon/Action + linked entities
    ↓
Claude CLI drafts deliverable (email body, event details, doc)
    ↓
Writes operation file to Meta/operations/pending/
    ↓
vault-bot.py detects → Telegram with ✅/❌ buttons
    ↓
Human approves → execute (send-email.sh, gcal MCP, etc.)
Human rejects → operation marked rejected, action untouched
    ↓
Action updated: operated_date, status: done, Evolution entry
```

**Key design decisions:**
- File-backed state: workflow progress is inspectable by Claude, Codex, and human via vault files
- Existing review tiers apply: email = Tier 2 (notify), calendar with externals = Tier 3 (gate)
- No generic workflow engine until 2+ specific workflows prove a shared pattern
- Manual trigger first (`/email` in Telegram), auto-triage later
- Researcher is a step type *inside* workflows, not a separate prerequisite

---

## Review Gates

Three tiers. Enforced by the script that runs the agent, not by the agent's own judgment.

### Tier 1: Silent (no review needed)
- Adding wikilinks
- Creating stub entries for mentioned people
- Fixing broken YAML
- Adding `## Extracted` sections to inbox notes
- Updating MANIFEST.md
- Fixing script bugs found by retro
- Updating agent specs based on retro findings

### Tier 2: Notify (do it, then tell Usman via Telegram)
- Creating new Canon entries from extraction
- Enriching existing entries with new data
- Changing action statuses
- Modifying agent specs
- Running wikilink sweeps

### Tier 3: Gate (present package, wait for approval)
- Sending any email
- Creating/modifying calendar events
- Posting to any external service
- Deleting any Canon entry
- Changing locked fields
- Any action involving money or commitments
- Publishing or deploying anything

**Implementation:** Review items go to `Meta/review-queue/`. Operator approvals go to `Meta/operations/pending/`. Both are surfaced via HOME.md Dataview queries and Telegram push notifications.

---

## Surfacing System — The Newspaper

The ADHD brain's enemy is "browse and discover." The vault must come to Usman, not the other way around. HOME.md is redesigned as a newspaper front page with three attention tiers:

### Tier 🔴 — Needs You (top of page)
Things that are BLOCKED on Usman's decision. Approval requests from Operator, Tier 3 review items, sprint proposals awaiting a call. These show up at the top of HOME.md and get pushed to Telegram.

**Sources:** `Meta/operations/pending/` (status: pending), `Meta/review-queue/` (status: pending), `Meta/sprint/proposals/` (status: proposed)

### Tier ✨ — What's New (middle)
Everything created in the last 48 hours. Auto-populated by Dataview. Each item shows emoji type, name, source, and linked context. Usman scans this when curious — no urgency, just awareness.

**Sources:** All notes in Canon/, Thinking/, Meta/AI-Reflections/ with `created` date within 2 days.

### Tier 🟢 — Just Happened (bottom)
No-brainers that auto-executed and sprint tasks that completed. These are FYI — no decision needed. Like a bank notification: "this happened." If something's wrong, Usman can undo.

**Sources:** `Meta/operations/completed/` (no_brainer: true OR status: executed, last 7 days), `Meta/sprint/done/` (last 7 days)

### Multi-Channel Delivery

The same tiers appear in three places, each serving a different moment:

| Channel | When | What it shows |
|---------|------|--------------|
| **HOME.md** | Opening Obsidian | Full newspaper: all three tiers, live Dataview |
| **Daily Briefing** | 7:30 AM push | Curated digest: Needs You + What's New + Open Actions |
| **Telegram** | Real-time | Push for 🔴 only. Quiet FYI for 🟢. |

---

## Operations Protocol

The Operator agent creates deliverables (emails, calendar events, documents) and presents them for approval. The approval system is file-based, bridging runtimes.

### Folder Structure

```
Meta/operations/
├── pending/           ← Operator writes approval requests here
├── executing/         ← vault-bot.py moves here during execution (atomicity guard)
├── completed/         ← final resting place after execute/approve/reject
└── TEMPLATE.md        ← reference format for operation files
```

### Flow

```
Operator prepares deliverable (e.g. email draft via Claude CLI)
    ↓
Writes .md file to Meta/operations/pending/ with notify: true
    ↓
vault-bot.py ops_watcher detects new file (every 30s) → sends Telegram message with context
    ↓
Human taps /approve <op_id> or /reject <op_id>
    ↓
/approve: move-based atomicity — pending/ → executing/ → send-email.sh → completed/
          (double-tap safe: mv is atomic, second /approve gets "Already processed")
          On failure: rolls back to pending/ with error message
/reject: pending/ → completed/ (status: rejected)
    ↓
HOME.md "Just Happened" section shows the result
```

### No-Brainers

Operations tagged `no_brainer: true` skip the approval gate entirely. The Operator executes immediately and logs to `Meta/operations/completed/`. These show up in the 🟢 tier — visible but not demanding attention.

**Criteria for no-brainer status:** Low stakes, no money, no external commitments to people outside the inner circle, reversible within 30 minutes. Usman opts in per operation TYPE, not per instance.

**Undo window:** 30 minutes. `/undo <op_id>` via Telegram reverses the operation (delete email, cancel event, remove doc).

---

## The Four Zones

The vault has four zones. Each has a different intent.

### Zone 1: Inbox — the voice recorder
Raw capture. Untouched transcripts. Source evidence. Nothing here gets edited except to add `status: extracted` and `## Extracted` section.

### Zone 2: Thinking — the whiteboard
Where ideas form. Reflections, emerging concepts, half-formed beliefs, journal entries, brain dumps. Notes here don't need a type. They can have one (`type: reflection`, `type: belief`, `type: emerging`) but they don't have to. Over time, some graduate to Canon or Articles. Some stay here forever — and that's fine.

**Key principle:** Wikilinks don't care about folders. A belief in `Thinking/` links to an action in `Canon/Actions/` just fine. The structure is in the links, not the location.

### Zone 3: Articles — the writing desk
Long-form intentional writing. Strategy docs, know-how guides, essays, original thinking meant to be shared or published. Each article spawns atomic concepts in `Thinking/` that link back to it — the article is the trunk, atomic ideas are branches.

```yaml
---
type: article
name: Strategy Workshop Guide
status: draft | in-progress | ready | published
tags: [strategy, facilitation]
published_at: ""
linked: []
changelog:
  - YYYY-MM-DD: created
---
```

### Zone 4: Canon — the filing cabinet
Crystallized knowledge with clear types. If it's a person, it's always a person. If it's an event, it always happened. These boxes earn their keep.

---

## Hubs and Navigation

**HOME.md** at vault root is the dashboard. Open vault → see HOME → pick a hub → explore.

A **hub** is a note with `hub: true` in frontmatter. Hubs are entry points that map a domain — linking to everything related, surfacing what matters now. Any note can be a hub. Hubs live wherever their type belongs (a project hub in `Canon/Projects/`, a concept hub in `Thinking/`).

**Tags** are cross-cutting themes that grow organically. The Thinker proposes new tags when it sees 3+ related notes without a common thread. The Implementer retroactively applies them. Tags + hubs replace the need for more folders.

**Rule:** New folder = new permanent type (almost never). New tag = new emerging theme (happens often). If a tag gets 10+ notes, the Thinker proposes a hub note.

---

## Note Types

### Canon Types (crystallized, clear box)
| Type | Folder | Purpose |
|---|---|---|
| person | Canon/People/ | Who they are, relationship to Usman, contact details |
| event | Canon/Events/ | What happened, when, who was there |
| action | Canon/Actions/ | Tasks, intentions, things to do |
| place | Canon/Places/ | Locations with context |
| organization | Canon/Organizations/ | Companies, groups, institutions |
| decision | Canon/Decisions/ | Clear choices made, why, what was traded off |
| project | Canon/Projects/ | Active initiatives with goals and status |

### Thinking Types (forming, flexible)
| Type | Folder | Purpose |
|---|---|---|
| reflection | Thinking/ | Brain dumps, journal entries, processing moments (stay whole) |
| belief | Thinking/ | What Usman holds to be true (anchors strategy) |
| concept | Thinking/ | Ideas, frameworks, mental models |
| emerging | Thinking/ | Doesn't fit a box yet — and that's fine |

**Note:** Canon/Concepts/ still exists for backward compatibility with existing concept entries. New concepts should go to `Thinking/` unless they're clearly crystallized and stable. The Thinker agent may propose moving mature Thinking/ notes to Canon/ when they've stabilized.

### Changelog Field

Notes that evolve over time should track their history:

```yaml
changelog:
  - 2026-03-23: created from voice memo
  - 2026-03-25: Thinker linked to [[Speed beats perfection]]
  - 2026-04-01: Mirror flagged contradiction with open actions
```

Agents append to this automatically. Git has full forensic detail.

---

#### Reflection (`Thinking/`)

Brain dumps, journal entries, processing moments. Not structured like concepts — these are *Usman thinking out loud*. The system cleans them up (grammar, structure, links) and learns from them (patterns feed the Mirror, insights feed the Thinker) but the original stays as a page.

```yaml
---
type: reflection
name: Thinking about what focus means
created: 2026-03-23
source: voice | human
mood: [scattered, energized, frustrated, calm, ...]  # optional
context: [morning, post-meeting, late-night, ...]     # optional
linked:
  - "[[relevant concept or person]]"
changelog:
  - 2026-03-23: created from voice memo [filename]
---
```

**Processing rule for Extractor:** When a reflection arrives, do BOTH:
1. Keep the whole thing in `Thinking/` — clean up grammar, add wikilinks, tag mood/context
2. Extract entities as usual — people, events, actions go to Canon
The reflection is the original painting. The Canon entries are prints in different rooms.

#### Belief (`Thinking/`)

What Usman holds to be true. These anchor strategy and decisions. They can be challenged, updated, or retired — but they're explicit.

```yaml
---
type: belief
name: Speed of execution beats perfection
created: 2026-03-23
source: voice | human | ai-extracted
confidence: high | medium | low
challenged_by: []           # links to reflections or events that test this
supported_by: []            # links to evidence
linked:
  - "[[relevant concepts, decisions, or reflections]]"
---
```

**Why this matters:** Beliefs → Objectives → Strategy → Decisions → Actions. This is the relational chain. Without explicit beliefs, the system can't tell you when your actions contradict your stated worldview.

---

## The Mirror Agent

**Purpose:** Hold up an honest reflection of Usman's patterns, strengths, weaknesses, and whether he's actually changing or just planning to change.

**Runtime:** Claude CLI (weekly) + Cowork (on-demand deep sessions)

**Spec: `Meta/Agents/Mirror.md`**

### What it reads:
- All Canon/Actions (status changes over time, recurring mentions, completion rates)
- All Canon/Reflections (mood patterns, recurring themes, what gets energy)
- Canon/Decisions (what was decided vs. what actually happened)
- Canon/Beliefs (are actions aligned with stated beliefs?)
- Retro-log + review-log (system health as proxy for personal engagement)
- Style guide (is the voice consistent or shifting?)
- Thinker reflections (patterns the Thinker already surfaced)

### What it writes:
A periodic `Meta/AI-Reflections/[DATE] - Mirror.md` that covers:

1. **Pattern Report** — "You've mentioned X five times without acting. You finished Y immediately. What's different?"
2. **Strength Evidence** — concrete examples from the vault of what Usman does well (crisis management, relationship maintenance, systems thinking)
3. **Growth Edges** — where the data shows stagnation or avoidance (not judgment — evidence)
4. **Belief-Action Alignment** — "You say you believe in speed of execution, but 4 of your 8 open actions are >14 days old"
5. **Energy Map** — when does Usman engage most? What topics get voice memos at 2 AM vs. what gets ignored?
6. **Delta Since Last Mirror** — what actually changed since the last reflection

### Tone:
Direct. Not cruel, not coddling. Like a good coach who's seen your tape. Uses Usman's own words back at him when they contradict his actions.

---

## The Implementer Agent

**Purpose:** Close the self-healing loop. Read what Retro and Reviewer found. Fix the safe things. Queue the rest.

**Runtime:** Claude CLI

**Schedule:** Runs after every Retro run AND after every Reviewer run.

**Spec: `Meta/Agents/Implementer.md`**

### Input:
- `Meta/AI-Reflections/retro-log.md` — latest entry
- `Meta/AI-Reflections/review-log.md` — latest entry
- All agent specs in `Meta/Agents/`
- All scripts in `Meta/scripts/`

### Rules:

**Safe to auto-fix (Tier 1 — just do it):**
- Script bugs (stats counting, grep patterns, awk issues)
- Missing `## Extracted` sections in inbox notes
- Broken wikilinks
- Missing stub entries for mentioned people
- YAML formatting errors
- Manifest inaccuracies
- Agent spec clarifications (strengthening existing rules)

**Requires review (Tier 3 — queue it):**
- Changing locked fields
- Resolving conflicting facts between sources
- Deleting or merging Canon entries
- Architectural changes (new folders, new note types)
- Anything the Retro flagged as "needs human decision"

### Output:
- Applied fixes are committed with clear messages: `[Implementer] fix: retro stats bug in run-retro.sh`
- Queued items go to `Meta/review-queue/` and Telegram notification
- Writes a brief log entry to `Meta/AI-Reflections/implementer-log.md`

---

## LLM Invocation Layer

All agent-to-LLM calls go through a unified routing layer. No script calls a specific LLM directly.

### Two Execution Paths

```
                    ┌──────────────────────────┐
                    │  agent-runtimes.conf      │
                    │  ADVISOR=claude            │
                    │  ADVISOR_TRIAGE=claude:haiku│
                    │  EXTRACTOR=claude           │
                    └──────────┬───────────────┘
                               │
              ┌────────────��───┼────────────────┐
              │                │                 │
    ┌───────��─▼──────┐  ┌─────▼──────┐  ┌──────▼───────┐
    │  invoke-agent.sh│  │ vault-lib.py│  │ vault-lib.py │
    │  (bash, batch)  │  │ (Python SDK)│  │ (subprocess)  │
    │                 │  │  streaming  │  │  fallback)    │
    │  Used by:       │  │             │  │               │
    │  - Mirror       │  │  Used by:   │  │  Used when:   │
    │  - Extractor    │  │  - Telegram │  │  - SDK fails  │
    │  - Enricher     │  │    bot for  │  │  - Runtime is │
    │  - Email        │  │    Advisor  │  │    codex      │
    │  - Researcher   │  │    streaming│  │  - No API key │
    └────────────────┘  └────────────┘  └──────────────┘
```

**invoke-agent.sh** (bash): Reads `agent-runtimes.conf`, resolves runtime (with mode overrides and fallback chains), calls the appropriate CLI (`claude` or `codex`). Used by all scheduled/batch agents.

**vault-lib.py** (Python): Same config parsing, same resolution logic. Calls the Anthropic Python SDK directly for streaming support. Used by `vault-bot.py` for the Advisor's Telegram path. Falls back to subprocess + invoke-agent.sh if SDK unavailable.

### Config Format: agent-runtimes.conf

```
AGENT=runtime                     # Single runtime
AGENT=runtime1,runtime2           # Fallback chain
AGENT_MODE=runtime                # Per-mode override
runtime = claude | claude:model | codex
model = opus | sonnet | haiku | <full-model-id>
```

Resolution order (both bash and Python):
1. `AGENT_MODE` (e.g., `ADVISOR_TRIAGE=claude:haiku`)
2. `AGENT` (e.g., `ADVISOR=claude`)
3. Default: `claude`

### Billing Model (current as of 2026-04-06)

- **Max subscription ($100/month):** Covers Claude CLI for ALL agents. No per-call cost.
- **API credits (~$5/month):** Covers Haiku triage in Telegram for fast streaming UX.
- **Codex:** Currently unused for agents (stdin pipe stalls under launchd).

To switch billing:
- API-only: Uncomment all `ADVISOR_*` overrides in config, drop Max to Pro ($20/month).
- CLI-only: Comment out `ADVISOR_TRIAGE` override. No API credits needed.
- The code automatically falls back to CLI if SDK fails (no credits, rate limit, etc.).

### Token Usage Tracking

Every Claude CLI call via `invoke-agent.sh` logs token usage to `Meta/agent-token-usage.jsonl`:

```json
{"ts": "2026-04-06T02:06:08", "agent": "task-enricher", "runtime": "claude", "input_tokens": 3, "output_tokens": 12, "cache_creation": 10909, "cache_read": 20767, "cost_usd": 0.04732785, "duration_ms": 2113, "num_turns": 1}
```

Fields: timestamp, agent name, runtime, input/output tokens, cache creation/read tokens, cost in USD, duration, number of API turns. Use this data to identify expensive agents and optimize routing.

### Key Files

| File | Role |
|------|------|
| `Meta/agent-runtimes.conf` | Runtime selection config (source of truth) |
| `Meta/scripts/invoke-agent.sh` | Bash runtime router for batch agents |
| `Meta/scripts/vault-lib.py` | Python SDK + shared utilities (streaming, config parsing, wikilinks) |
| `~/.anthropic/api_key` | API key for Anthropic SDK (chmod 600) |
| `Meta/agent-token-usage.jsonl` | Per-agent token usage + cost log (CLI calls via invoke-agent.sh) |

---

## The Advisor Agent

The Advisor is Usman's always-on strategic consultant. It's the only agent that talks directly to the user in Telegram (other agents communicate through notifications).

**Persona:** Roger Martin + Bezos + empathetic coach. Direct, warm, slightly informal. References specific vault notes. One question at a time. No walls of text (ADHD-aware).

**Spec:** `Meta/Agents/Advisor.md`
**Runner:** `Meta/scripts/run-advisor.sh`
**Knowledge file:** `Meta/Agents/advisor-knowledge.md` (persistent compressed memory, read on every call)

### Modes

| Mode | Trigger | Context loaded | Response style | Runtime |
|------|---------|---------------|----------------|---------|
| **triage** | Any substantial Telegram message | Knowledge + action list + recent notes (~2K tokens) | 1-4 sentences, warm, one question max | SDK streaming (Haiku) |
| **feedback** | Agent completes work (via JSONL queue) | Knowledge + agent summary | 1-3 sentences or empty (skip routine) | SDK or CLI |
| **ask** | `/ask` command | Knowledge + actions + decisions + beliefs + style guide | Direct answer + perspective | CLI (Sonnet) |
| **strategy** | `/strategy` command or deep reflection | Full context (same as ask) | Analysis with options + tradeoffs | CLI (Sonnet) |

### Structured Output

The Advisor returns structured output with delimiters:

```
---RESPONSE---
[conversational text — goes directly to Telegram]
---TRIGGERS---
EXTRACT: filepath
MODE_SWITCH: deep
RESEARCH: topic
UPDATE_KNOWLEDGE: section | learning
---END---
```

Parsing: `vault-lib.py:parse_advisor_output()` and `parse-advisor-output.py` (shell path).

### Streaming in Telegram

For triage (and optionally ask/strategy), vault-bot.py uses the Anthropic Python SDK:

1. Send "🧠 ..." placeholder immediately (0ms perceived latency)
2. Stream response via SDK, edit message every ~1s
3. Final edit with complete response + wikilinks converted to obsidian:// deep links

Falls back to CLI subprocess automatically if SDK unavailable.

---

## Claude + Codex Collaboration

Two AI runtimes. Different strengths. Clear roles.

Full protocol: `Meta/Collaboration.md`

### Role Assignment

| Task type | Lead | Support |
|-----------|------|---------|
| Vault ops (Extract, Review, Implement) | Codex | Claude reviews |
| Strategy, voice, relational analysis | Claude | Codex executes |
| Research perspective runs | Codex | Claude synthesizes |
| External services (email, calendar) | Claude | N/A (MCP only) |
| Bulk ops, scripts, tests | Codex | Claude reviews |

### The Handoff Protocol

When Claude runs low on tokens or a task suits Codex better:

```
Claude writes handoff file → Telegram pings you →
You run: ./Meta/scripts/run-handoff.sh Meta/handoffs/<file>
    → Codex executes → Validation checks diff → Telegram reports result
```

Handoff files live in `Meta/handoffs/`. They contain: what's done, what's left, what NOT to touch, and done criteria.

Scripts:
- `create-handoff.sh` — Claude calls this to write the handoff + notify
- `run-handoff.sh` — Executes the handoff via Codex with post-validation
- `pre-commit-guard.sh` — Git hook blocking dangerous deletions + agent control-file edits

### The Pre-Commit Guard

Install: `ln -sf ../../Meta/scripts/pre-commit-guard.sh .git/hooks/pre-commit`

Blocks:
- Deletions in protected dirs (Canon, Thinking/Research, AI-Reflections)
- Agent edits to control files (CLAUDE.md, Architecture, agent specs, scripts)
- Warns on bulk commits (>50 files)

Override with env vars when intentional: `VAULT_ALLOW_DELETE=1`, `VAULT_ALLOW_CONTROL_EDIT=1`

### What Codex should NOT do without review:
- Deep relational analysis (that's Opus territory — judgment, nuance, reading between lines)
- Anything requiring MCP tools (Gmail, Calendar, etc.)
- Modifying Canon entries that require understanding relationship context
- Writing in Usman's voice (use style-guide.md with Claude for that)
- Deleting files in protected directories
- Editing control files (agent specs, scripts, CLAUDE.md, Architecture.md)

---

## The Research Pipeline

When an action needs external knowledge before it can be enriched or executed, the Researcher agent handles it.

```
Task-Enricher detects: "this needs research"
    ↓ sets enrichment_status: needs-research
    ↓ sets research_question: "specific question"
    ↓
Researcher (Codex, highest model)
    ↓
    ├─ Phase 0: Telegram ping (non-blocking)
    │   "🔬 Starting research on X — reply to steer"
    │
    ├─ Phase 1: Context gathering (vault notes, linked entities, beliefs)
    │
    ├─ Phase 2: Multi-perspective swarm (3 parallel Codex runs)
    │   ┌─────────────┬──────────────┬──────────────┐
    │   │ Lens A      │ Lens B       │ 🔥 Contrarian│
    │   │ (topic-     │ (topic-      │ (always      │
    │   │  dependent) │  dependent)  │  present)    │
    │   └──────┬──────┴──────┬───────┴──────┬───────┘
    │          └─────────────┼──────────────┘
    │                        ↓
    ├─ Phase 3: Synthesis pass (merge perspectives + any Telegram reply)
    │
    ├─ Phase 4: Verification pass (fact-check, gap analysis)
    │   └─ Critical gaps? Loop back to Phase 2 (max 2x)
    │
    ├─ Phase 5: Write article → Thinking/Research/
    │   └─ Link back to action: research: "[[article]]"
    │
    ├─ Phase 5.5: ENRICHMENT — scatter findings into vault
    │   ├─ Create concept note in Thinking/ (distilled insight, 10-15 lines)
    │   ├─ Add Findings section + Evolution entry to triggering action
    │   └─ Wikilink related existing notes (both directions)
    │
    └─ Phase 6: Commit + Telegram notify
                 ↓
         Operator picks up (if action is now executable)
```

**Perspective selection is dynamic.** Business questions get Bezos/Martin/Contrarian. Personal questions get Expert/Philosopher/Contrarian. Technical questions get Builder/Analyst/Contrarian. The human can override via Telegram reply.

**Scan mode:** `run-researcher.sh --scan` finds all actions with `enrichment_status: needs-research` and processes them. Wired into `daily-briefing.sh` to run before the email digest. Flips `enrichment_status` to `researched` after completion.

**Enrichment is the key insight.** The article stays in `Thinking/Research/`, but the knowledge scatters into the vault via concept notes, findings summaries, and wikilinks. Obsidian's graph view connects them. Research is a river, not a lake.

**Spec:** `Meta/Agents/Researcher.md`
**Script:** `Meta/scripts/run-researcher.sh`

---

## Skills (Just-in-Time Context)

The system's biggest context-decay problem: CLAUDE.md is loaded at conversation start and forgotten by message 20. Skills solve this by injecting focused rules at the moment of action.

### How Skills Work

```
CLAUDE.md (always loaded, ~300 lines)     ← broad rules, safety, permissions
    ↓
Skill loaded on demand (~150 lines)       ← focused rules for THIS specific task
    ↓
Agent spec (if applicable)                ← role-specific behavior
```

Think of it as: CLAUDE.md is the constitution. Skills are the job-specific training manuals. You don't memorize the constitution before making coffee — you read the barista handbook.

### Available Skills

| Skill | Location | Purpose | Token cost |
|-------|----------|---------|-----------|
| `vault-writer` | `.claude/skills/vault-writer/SKILL.md` | Note format, frontmatter, emoji, provenance, wikilinks | ~200 lines |
| `vault-extractor` | `.claude/skills/vault-extractor/SKILL.md` | Full extraction rulebook, reflection detection, write-back | ~250 lines |

### Token Discipline

The lean prompt pattern (Session 10) showed that dumping full specs into CLI args wastes ~97% of tokens. Skills extend this principle to interactive sessions:

- **Cowork:** Skills auto-load when triggered. No wasted upfront context.
- **CLI agents:** Scripts tell the agent "read X skill file" instead of inlining the rules. Fresh context per run.
- **Codex agents:** Same — point to file path, let agent read at runtime.

**Rule of thumb:** Load the minimum context needed for excellent output. For note creation, that's vault-writer (~200 lines). For extraction, that's vault-extractor (~250 lines). For architecture work, that's this file. Don't load all three unless the task genuinely needs all three.

### Adding New Skills

When a new agent role or task pattern emerges that keeps losing context mid-conversation:
1. Create a new skill dir in `.claude/skills/<name>/`
2. Write a `SKILL.md` with frontmatter (name, description) and focused instructions
3. Add it to this section and to `CLAUDE.md`'s skill table
4. Update `SETUP.md` to document it

---

## Emoji Headings

Every note in the vault gets a type-appropriate emoji at the start of its H1 heading. This is for ADHD-friendly visual scanning in Obsidian.

| Type | Emoji | Type | Emoji |
|------|-------|------|-------|
| action | 🎯 | reflection | 💭 |
| person | 👤 | belief | 🪨 |
| event | 📅 | research | 🔬 |
| concept | 💡 | project | 📁 |
| decision | ⚖️ | place | 📍 |
| organization | 🏢 | emerging | 🌱 |
| ai-reflection | 🤖 | sprint-task | 🏗️ |
| sprint-proposal | 💡 | | |

Emojis go in H1 headings ONLY — filenames stay clean for wikilinks. All agents that create or update notes must apply the correct emoji. The Implementer can retroactively add missing emojis as a Tier 1 fix.

---

## The Reflection Pipeline

For Usman's brain dumps and personal reflections:

```
Voice memo / text ──→ Inbox (raw, untouched)
                          ↓
                     Extractor detects type: reflection
                          ↓
                     Light processing:
                     - Clean grammar (preserve voice)
                     - Add wikilinks
                     - Extract entity stubs (don't disassemble)
                     - Tag themes + mood
                          ↓
                     Canon/Reflections/[name].md
                          ↓
                     Mirror reads reflections weekly
                     Thinker reads reflections for patterns
                     Beliefs get challenged or supported
```

**Key difference from current pipeline:** Reflections stay whole. They're not broken into atoms. They're evidence of how Usman thinks, and the Mirror uses them as data.

---

## The Relational Model

Tasks don't live alone. Everything in the vault is connected relationally:

```
Beliefs ←──→ Objectives ←──→ Strategy ←──→ Decisions ←──→ Actions
   ↑              ↑              ↑              ↑             ↑
   └──────────────┴──────────────┴──────────────┴─────────────┘
                        Reflections feed all levels
                        Mirror reads all levels
                        People are connected to all levels
```

**This is NOT hierarchical.** An action can link to a belief without an objective in between. A decision can challenge a belief. A reflection can spawn a new objective. The wikilinks ARE the structure.

**For the Thinker and Mirror:** When analyzing the vault, traverse these links. "You decided X, which contradicts belief Y — is that intentional?" "Action Z has been open for 3 weeks and connects to your highest-priority objective — what's blocking it?"

---

## What Gets Built First

In priority order. Each unlocks the next.

### Phase 1: Self-Healing ✅ DONE (Sessions 7-15)
- [x] Write `Meta/Agents/Implementer.md` spec
- [x] Write `run-implementer.sh` script
- [x] Fix `run-retro.sh` stats bug — switched to `find`/`grep -rl` for macOS compat (Session 15)
- [x] Chain: run-retro.sh → run-implementer.sh (auto-run, passes ALLOW_DIRTY + LOCK_HELD)
- [x] Chain: run-reviewer.sh → run-implementer.sh (auto-run, passes ALLOW_DIRTY + LOCK_HELD)
- [x] **Root cause fixed (Session 15):** Implementer was locked out by dirty worktree + lock contention. Now receives env vars to bypass.
- [x] Heartbeat script rewritten for macOS bash 3.2 compat (no associative arrays)

### Phase 2: Mirror + Reflections ✅ DONE (Sessions 8-10)
- [x] Reflections live in `Thinking/` (not Canon/Reflections/)
- [x] Beliefs live in `Thinking/` (type: belief)
- [x] Write `Meta/Agents/Mirror.md` spec
- [x] Write `run-mirror.sh` script
- [x] Extractor detects reflections and keeps them whole
- [x] CLAUDE.md updated with reflection, belief, emerging types

### Phase 3: Execution Layer ✅ MOSTLY DONE (Sessions 12-15)
- [x] Task-Enricher spec + script
- [x] Review queue file format (`Meta/review-queue/`)
- [x] Telegram approval flow (`/approve`, `/reject`, inline buttons)
- [x] Operator agent spec + approval gate
- [x] Email workflow V1: `/email <action>` → draft → operation file → approve → send
- [x] Operations tracking: `Meta/operations/{pending,completed}/`
- [x] Sprint worker: async task runner with `depends_on:` dependency chaining
- [x] Enrichment commands: Extractor detects "look up X" → sets `ENRICH:` placeholders
- [x] Agent provenance: every AI action signed with `source_agent` + `source_date`
- [x] Voice pipeline emoji trail: 👂→📝→🔍→✅ with extraction summary to Telegram
- [x] **Email send live-tested (Session 16):** /approve executes send-email.sh with move-based atomicity
- [x] **Operations approve→execute wired (Session 16):** pending→executing→completed state machine
- [ ] **Not yet live-tested:** sprint worker execution

### Phase 4: Codex Integration ✅ DONE (Sessions 9-10)
- [x] Codex CLI path configured
- [x] `invoke-agent.sh` runtime router + `agent-runtimes.conf`
- [x] `lib-agent.sh` shared safety (locking, forbidden paths, scoped commits)
- [x] Lean prompt pattern (agents read files at runtime, not embedded in CLI args)
- [ ] Push vault to GitHub (private repo) — STILL BLOCKED

### Phase 5: External Integrations — PARTIAL
- [x] Readwise → 38 atomic notes imported to Thinking/
- [x] Researcher agent: multi-perspective swarm via Codex
- [ ] Email management agent (outgoing works, incoming not connected)
- [ ] Prototype pipeline (voice → HTML prototype) — not started

---

## File Map

```
Meta/
├── Architecture.md          ← YOU ARE HERE
├── CLAUDE.md                ← vault rules (for all agents)
├── MANIFEST.md              ← auto-generated vault index
├── style-guide.md           ← Usman's voice for AI drafting
├── Agents/
│   ├── Extractor.md         ← deep extraction from inbox notes
│   ├── Reviewer.md          ← QA after extraction
│   ├── Thinker.md           ← weekly thinking partner
│   ├── Briefing.md          ← daily morning briefing
│   ├── Retrospective.md     ← daily vault health check
│   ├── Task-Enricher.md     ← ADHD-friendly task breakdown
│   ├── Researcher.md        ← multi-perspective research swarm
│   ├── Implementer.md       ← self-healing loop
│   └── Mirror.md            ← personal pattern reflection
├── AI-Reflections/
│   ├── retro-log.md         ← retro findings (Implementer reads this)
│   ├── review-log.md        ← reviewer findings (Implementer reads this)
│   ├── implementer-log.md   ← NEW: what Implementer fixed
│   └── [DATE] - Mirror.md   ← NEW: periodic mirror reflections
├── review-queue/             ← NEW: items awaiting human approval
│   └── [timestamp]-[action].md
├── scripts/
│   ├── vault-bot.py          ← Telegram bot (persistent)
│   ├── run-extractor.sh
│   ├── run-reviewer.sh
│   ├── run-thinker.sh
│   ├── run-retro.sh
│   ├── daily-briefing.sh
│   ├── run-implementer.sh    ← NEW
│   ├── run-mirror.sh         ← personal pattern reflection (lock, validation, Telegram)
│   ├── run-researcher.sh     ← multi-perspective research swarm
│   ├── run-advisor.sh        ← Advisor agent (triage/ask/strategy/feedback modes)
│   ├── run-task-enricher.sh  ← --morning (shell scoring), --scan (AI), --nudge (stale)
│   ├── run-email-workflow.sh ← draft email → operation file → durable HTML body
│   ├── send-email.sh         ← Gmail SMTP sender (reads HTML from op file or standalone)
│   ├── run-handoff.sh        ← execute Claude→Codex handoff with validation
│   ├── create-handoff.sh     ← write handoff file + Telegram notify
│   ├── pre-commit-guard.sh   ← git hook: block dangerous deletes + control edits
│   ├── invoke-agent.sh       ← runtime router (bash: claude/codex, fallback chains, model variants)
│   ├── vault-lib.py          ← shared Python library (SDK streaming, config parsing, wikilinks, frontmatter)
│   ├── lib-agent.sh          ← shared safety (locking w/ opt-in retry, forbidden paths, scoped commits)
│   ├── test-vault-automation.sh ← smoke test script (21 tests)
│   ├── build-manifest.sh
│   ├── process-voice-memo.sh ← voice pipeline (lock retry, progress tracking, step-level errors)
│   ├── update-voice-progress.sh ← write progress JSON (bot polls to edit Telegram status)
│   ├── log-agent-feedback.sh ← append JSONL to agent-feedback.jsonl
│   ├── watch-voice-drop.sh
│   └── queue-review.sh
└── README/
    └── People Schema.md

├── sprint/
│   ├── SPRINT.md              ← hub: the board (Dataview renders it)
│   ├── active/                ← tasks in progress
│   ├── backlog/               ← tasks ready to pick up
│   ├── done/                  ← completed (audit trail)
│   └── proposals/             ← ideas from any agent or human
├── operations/
│   ├── pending/           ← Operator approval requests (vault-bot.py watches every 30s)
│   ├── executing/         ← in-flight operations (atomicity guard during send)
│   ├── completed/         ← approved/rejected/executed operations
│   └── TEMPLATE.md        ← operation file format reference
├── handoffs/              ← Claude→Codex handoff files (audit trail)
├── research/
│   ├── pending/            ← question files awaiting Telegram reply
│   ├── answers/            ← Telegram replies from Usman
│   └── temp/               ← perspective outputs (cleaned after synthesis)
└── README/
    └── People Schema.md

.claude/
└── skills/
    ├── vault-writer/SKILL.md       ← note format, frontmatter, emoji, provenance
    └── vault-extractor/SKILL.md    ← full extraction rulebook

Thinking/              ← the whiteboard (reflections, beliefs, concepts, emerging ideas)
└── Research/          ← multi-perspective research articles

Canon/
├── People/        (98 entries)
├── Events/        (31)
├── Actions/       (23)
├── Concepts/      (20 — legacy; new concepts go to Thinking/)
├── Decisions/     (7)
├── Projects/      (2)
├── Places/        (10)
└── Organizations/ (1)
```

---

## Sprint Board — Agent Coordination

The sprint board (`Meta/sprint/SPRINT.md`) is how Claude, Codex, and Usman coordinate work without Usman being the relay.

### Structure

```
Meta/sprint/
├── SPRINT.md              ← hub: Dataview renders the board
├── active/                ← tasks currently being worked on
├── backlog/               ← tasks ready to pick up
├── done/                  ← completed tasks (audit trail)
└── proposals/             ← ideas from ANY agent or human
```

### Strategic Anchors

Every task must pay into at least one anchor. If it doesn't, it doesn't get built.

| Anchor | What it means |
|--------|--------------|
| 🧠 Zero-friction capture | Talking is the only input |
| 🎯 Surface the next thing | Show one next action, not the full plan |
| 🔁 Self-healing system | System fixes itself, tells you when it can't |
| 🤝 AI collaboration | Agents work as a team, ideas flow from anyone |
| 🪨 Strategy-anchored | Beliefs → Decisions → Actions alignment |

### Task Contracts

Each task has machine-readable YAML: `assignee`, `reviewer`, `anchor`, `done_criteria`, `validate`. This is TDD for tasks — the acceptance test exists before the work starts.

### Proposals

Any agent can propose work by writing to `Meta/sprint/proposals/`. This is how AI becomes a thinking partner, not just an executor. Codex sees a pattern in the codebase → proposes a fix. Claude sees a strategic gap → proposes a feature. Usman reviews and decides what becomes a real task.

### Roles

| Role | Who | What they do |
|------|-----|-------------|
| Product owner | Usman | Decides what matters. Reviews. Approves. |
| Architect + reviewer | Claude | Creates tasks with contracts. Reviews completed work. |
| Builder + tester | Codex | Picks up tasks. Builds. Runs validation. |
| Proposer | Anyone | Writes proposals. Best ideas come from anywhere. |

---

## Decision Logging

Two levels of decision capture:

**Big decisions** (life, strategy, product direction): Create a full note in `Canon/Decisions/` with context, rationale, reversibility. These come from voice memos (Extractor routes them) or interactive sessions.

**Operational decisions** (architecture, implementation, tradeoffs): Append to `Meta/decisions-log.md`. These are the "why did we do X instead of Y" choices that compound into institutional knowledge. Both humans and AI agents should log here.

**When to log a decision:**
- You chose approach A over approach B and the choice has consequences
- You rejected a seemingly obvious approach for a non-obvious reason
- You made an assumption that should be checked later
- You corrected a prior decision or discovered a plan was wrong

**How:**
- CLI: `./Meta/scripts/log-decision.sh "Title" "What" "Why" "Rejected" "Check later" "Source"`
- Agents: call `log-decision.sh` after making consequential implementation choices
- Interactive sessions: Claude should log decisions made during the session before committing

**Format per entry:**
```
## YYYY-MM-DD — Title
- **Decided:** What was chosen
- **Why:** The rationale
- **Rejected:** What was considered and dismissed
- **Check later:** How we'd know if this was wrong
- **Source:** Session N, agent name, or voice memo
```

---

## Git Safety

The vault's history is its insurance policy. Three layers ensure no agent or accident can destroy it.

**Layer 1: GitHub Remote** — Push to a private repo. Branch protection on `main`: no force-pushes, no branch deletion. Even if local `.git` gets nuked, full history lives on GitHub.

**Layer 2: Local Guards** — `pre-commit-guard.sh` blocks dangerous deletes. `git config receive.denyNonFastForwards` and `receive.denyDeletes` reject force-pushes and branch deletion at the git level.

**Layer 3: Backup Bundle** — `Meta/scripts/backup-git.sh` creates a full git bundle daily (entire repo history in one file). Keeps 7 days. Recovery: `git clone vault-YYYY-MM-DD.bundle restored-vault`.

---

## Principles for Future Development

1. **Ship the loop, not the feature.** A self-improving system beats a perfect system. Build feedback loops first, polish later.
2. **Trust the system, keep the receipts.** No-brainers execute without asking. But everything is in git, everything has an undo window, and the Mirror watches for drift. Trust is earned by audit trails, not permission prompts.
3. **ADHD-aware design.** One step at a time. Lower activation energy. Surface the next action, not the full plan. Nudge, don't nag. The "decide whether to decide" tax is the enemy.
4. **Multi-model by design.** Don't lock into one provider. Claude for judgment, Codex for code, future models for whatever they're best at. The vault is the constant; the agents are interchangeable.
5. **Human-readable where it helps, machine-dense where it doesn't.** Canon entries are for Usman to read. Agent specs, manifests, and review queues are for agents. Both are valid.
6. **The strategy tool is born here.** This personal system is the prototype. What works for Usman's brain will work for others. But don't build "for the product" — build for yourself, and the product will emerge.
