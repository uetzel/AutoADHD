# Vault System — Complete Setup & Recreation Guide

> If you're an AI reading this: you have everything you need to rebuild this system from scratch. If you're a human: follow the steps in order and you'll have a working voice-first knowledge vault in under an hour.

## What This System Is

A personal knowledge management system built on Obsidian, powered by AI agents. The core loop:

1. **You speak** (voice memo from iPhone or Telegram)
2. **AI transcribes** (Whisper, local, free, private)
3. **AI extracts** knowledge into structured Canon entries and `Thinking/` notes (people, events, actions, decisions, places, organizations, reflections, beliefs, emerging ideas)
4. **AI reviews** extraction quality, enforces wikilinks, detects duplicates
5. **AI reflects** periodically — finding patterns, surfacing stale tasks, proposing connections
6. **You get briefed** every morning via Telegram or Obsidian
7. **Git tracks everything** — if something breaks, revert

The human talks. The system listens, remembers, connects, and surfaces what matters. Zero friction, ADHD-friendly.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│  INPUTS                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ iPhone   │  │ Telegram │  │ Obsidian (text)  │  │
│  │ Shortcut │  │ Bot      │  │                  │  │
│  └────┬─────┘  └────┬─────┘  └────────┬─────────┘  │
│       │              │                 │            │
│       ▼              ▼                 │            │
│  ┌──────────────────────┐              │            │
│  │  Inbox/Voice/_drop/  │              │            │
│  │  (audio files land)  │              │            │
│  └──────────┬───────────┘              │            │
│             ▼                          │            │
│  ┌──────────────────┐                  │            │
│  │  Whisper (local)  │                 │            │
│  │  transcription    │                 │            │
│  └──────────┬───────┘                  │            │
│             ▼                          ▼            │
│  ┌──────────────────────────────────────────────┐   │
│  │  EXTRACTOR AGENT                             │   │
│  │  Deep extraction → Canon + Thinking          │   │
│  │  People, Events, Actions, Orgs, Thinking     │   │
│  └──────────────────────┬───────────────────────┘   │
│                         ▼                           │
│  ┌──────────────────────────────────────────────┐   │
│  │  REVIEWER AGENT                              │   │
│  │  QA: wikilinks, duplicates, locked fields,   │   │
│  │  provenance, tags, completeness              │   │
│  └──────────────────────┬───────────────────────┘   │
│                         ▼                           │
│  ┌──────────────────────────────────────────────┐   │
│  │  Git commit + Changelog entry                │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  PERIODIC AGENTS                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ Briefing │  │ Thinker  │  │ Retrospective    │  │
│  │ Daily AM │  │ Weekly   │  │ Daily PM         │  │
│  └──────────┘  └──────────┘  └────────┬─────────┘  │
│  ┌──────────────────────────────────────────────┐   │
│  │  IMPLEMENTER AGENT (auto after Retro+Review) │   │
│  │  Self-healing: reads findings, applies fixes  │   │
│  │  Tier 1=auto, Tier 2=notify, Tier 3=queue    │   │
│  └──────────────────────────────────────────────┘   │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │
│  │ Task     │  │ Mirror   │  │ Researcher       │  │
│  │ Enricher │  │ Weekly   │  │ --scan daily +   │  │
│  │ Daily AM │  │ Sun PM   │  │ on-demand        │  │
│  └──────────┘  └──────────┘  └──────────────────┘  │
│                                                     │
│  OUTPUT: Telegram + Obsidian + Email + review-queue │
└─────────────────────────────────────────────────────┘
```

---

## Folder Structure

```
VaultSandbox/
├── Inbox/                    # Raw capture
│   ├── Voice/                # Voice memo transcripts
│   │   ├── _drop/           # Audio landing zone (Telegram/iPhone write here)
│   │   ├── _processing/     # Watcher-owned queue claim area
│   │   ├── _processed/      # Audio files after transcription succeeds (gitignored)
│   │   └── _extracted/      # Extracted notes archived here (keeps Voice/ clean)
│   ├── Quick/                # Quick text captures
│   └── Text/                 # Longer text notes
├── Canon/                    # Stable, structured knowledge
│   ├── People/               # Every person mentioned (with tags, aliases, relationships)
│   ├── Events/               # Things that happened
│   ├── Concepts/             # Legacy concept notes (new concept work lands in Thinking/)
│   ├── Decisions/            # Choices made or pending
│   ├── Projects/             # Ongoing projects
│   ├── Actions/              # Tasks, intentions, todos
│   ├── Places/               # Locations with context
│   └── Organizations/        # Companies, groups, institutions
├── Thinking/                 # Reflections, beliefs, concepts, and emerging notes
│   └── Research/             # Deep-dive research outputs
├── Meta/                     # System files
│   ├── Agents/               # Agent specifications (Extractor, Reviewer, Thinker, etc.)
│   ├── AI-Reflections/       # Thinker output, retro logs, review logs
│   ├── scripts/              # All automation scripts + this SETUP.md
│   ├── Templates/            # Note templates
│   ├── Architecture.md       # System blueprint (all agents read this)
│   ├── changelog.md          # Timeline of all agent activity
│   └── review-queue/         # Items awaiting human approval (Tier 3 gate)
├── Usman/                    # Personal notes, journals
├── Readwise/                 # Readwise synced highlights
├── 🚀 Startup/              # Startup-related notes
├── 🧠 On Strategy/          # Strategy thinking
├── .claude/
│   └── skills/               # Just-in-time context for AI agents
│       ├── vault-writer/     # Note format, frontmatter, emoji, provenance
│       └── vault-extractor/  # Full extraction rulebook
├── CLAUDE.md                 # AI agent behavior rules (READ THIS FIRST)
└── AGENTS.md                 # Agent overview
```

---

## Design Principles

1. **Voice-first**: The primary input is speech. Everything else is secondary.
2. **Zero friction**: ADHD-optimized. No manual filing, no tagging by hand. AI does the work.
3. **Provenance always**: Every fact traces back to a human moment or an explicit source.
4. **Wikilinks are structure**: No folders-as-taxonomy. Links between notes ARE the structure. Every name mention = a wikilink.
5. **Locked fields = human truth**: AI can write anything, but humans lock what they've verified.
6. **Git = safety net**: Every change committed. If something breaks, revert.
7. **Canon = stable knowledge**: Inbox is ephemeral capture. Canon is the refined, linked, evolving knowledge base.

---

## Step-by-Step Setup

### Prerequisites

- macOS (Apple Silicon recommended for Whisper MPS GPU acceleration)
- Obsidian installed, Dataview plugin enabled
- Python 3.x
- Git
- Claude CLI (`claude` command available) — all agents use this (Max subscription $100/month)
- ffmpeg (for Telegram voice messages: `brew install ffmpeg`)
- Optional: Codex CLI (`/Applications/Codex.app/Contents/Resources/codex`) — currently unused, stdin pipe stalls under launchd

### Step 1: Initialize the Vault

```bash
mkdir -p ~/VaultSandbox
cd ~/VaultSandbox
git init
```

Create the folder structure:
```bash
mkdir -p Inbox/Voice/_drop Inbox/Quick Inbox/Text
mkdir -p Canon/People Canon/Events Canon/Concepts Canon/Decisions Canon/Projects Canon/Actions Canon/Places Canon/Organizations
mkdir -p Meta/Agents Meta/AI-Reflections Meta/scripts Meta/Templates Meta/review-queue Meta/handoffs
mkdir -p Meta/research/pending Meta/research/answers Meta/research/temp
mkdir -p Thinking Thinking/Research
mkdir -p Meta/operations/pending Meta/operations/executing Meta/operations/completed
mkdir -p Meta/sprint/active Meta/sprint/backlog Meta/sprint/done Meta/sprint/proposals
```

### Step 1.5: Install Working Agreement Files

These are part of the recreated system now:

- `AGENTS.md`
- `CLAUDE.md`
- `Meta/Architecture.md`
- `Meta/Engineering.md`
- `Makefile`
- `.github/workflows/ci.yml`

For code and tooling changes, `make check` is the default verification command.

### Step 2: Install Dependencies

```bash
# Whisper (local transcription — free, private, runs on your Mac)
pip3 install openai-whisper --break-system-packages

# Telegram bot (job-queue extra required for operations watcher)
pip3 install "python-telegram-bot[job-queue]" --break-system-packages

# Anthropic Python SDK (for Advisor streaming in Telegram)
# Optional: only needed if you want fast streaming responses.
# Without it, Advisor falls back to Claude CLI (slower but works).
pip3 install anthropic --break-system-packages

# ffmpeg (for .ogg voice messages from Telegram)
brew install ffmpeg
```

**Anthropic API key (optional, for streaming):**

```bash
# Get a key from console.anthropic.com > API Keys
# Add $5+ credits at console.anthropic.com > Plans & Billing
mkdir -p ~/.anthropic
echo "sk-ant-your-key-here" > ~/.anthropic/api_key
chmod 600 ~/.anthropic/api_key
```

vault-lib.py reads this key automatically. If missing, vault-bot.py falls back to CLI subprocess (no streaming). See `Meta/agent-runtimes.conf` for which modes use SDK vs CLI.

### Step 3: Copy Core Files

The vault needs these files from Meta/scripts/:

| Script | Purpose | When |
|--------|---------|------|
| `process-voice-memo.sh` | Worker: transcribe claimed audio → create inbox note → extract → review → commit | Called by watcher |
| `retry-failed.sh` | Re-run extraction on inbox notes marked `status: failed` | On-demand recovery |
| `invoke-agent.sh` | Route each agent to Claude (or Codex) based on config; fallback chains, model variants, JSON output, token tracking | Called by agent runners |
| `vault-lib.py` | Shared Python library: Anthropic SDK streaming, config parsing, wikilinks, frontmatter | Imported by vault-bot.py |
| `lib-agent.sh` | Shared safety: clean-tree checks, git lock cleanup, locking with opt-in retry (3x, 30s, Telegram alert), scoped commits | Called by agent runners |
| `clear-stale-git-locks.sh` | Manually remove stale `.git/index.lock` / `.git/HEAD.lock` when no live git process exists | On-demand recovery |
| `vault-health.sh` | Green/red health check for bot, watcher, backlog, git, Codex CLI, and last pipeline run | On-demand + before daily briefing |
| `run-extractor.sh` | Deep extraction of people/events/concepts/actions | Part of pipeline |
| `run-reviewer.sh` | QA: wikilinks, duplicates, locked fields, tags | Part of pipeline |
| `run-implementer.sh` | Reads retro/reviewer findings and applies safe fixes | After reviewer/retro |
| `run-advisor.sh` | Advisor agent: triage, ask, strategy, feedback modes | Always-on via Telegram |
| `run-task-enricher.sh` | Break actions into steps, decompose, execute DAG | Daily + on-demand |
| `run-thinker.sh [topic]` | AI thinking partner: patterns, reflections | Weekly or on-demand |
| `daily-briefing.sh` | Morning briefing + Telegram push | Daily 7:30 AM |
| `run-retro.sh` | Agent retrospective: review day, improve specs | Daily 9:00 PM |
| `weekly-maintenance.sh` | Temperature + manifest + thinker + reviewer | Sunday 10 AM |
| `build-manifest.sh` | Rebuilds vault index for AI navigation | Part of pipeline |
| `build-canvas.sh [focus]` | Generates Obsidian Canvas from wikilinks | On-demand |
| `update-temperature.sh` | Ebbinghaus note temperature scoring | Part of weekly |
| `watch-voice-drop.sh` | Queue owner: claims `_drop` audio into `_processing/`, runs pipeline, re-queues transient failures | Always running |
| `run-task-enricher.sh` | Enriches open actions: next steps, contact lookup, Telegram nudges | On new action + daily 8:30 AM |
| `log-change.sh` | Appends to Meta/changelog.md | Called by all agents |
| `log-decision.sh` | Appends to Meta/decisions-log.md (operational/architectural decisions) | Called by agents + interactive sessions |
| `vault-bot.py` | Telegram bot: saves voice into `_drop`, handles text/commands/review queue | Always running |
| `send-telegram.sh` | Push message to Telegram | Called by briefing |
| `queue-review.sh` | Add item to review queue | Called by agents |
| `run-researcher.sh` | Multi-perspective research swarm via Claude CLI; `--scan` mode processes all `needs-research` actions | Daily 9:00 AM scan (launchd) + on-demand |
| `daily-approval-email.sh` | Strategy-consultant-quality HTML email digest with smart context-dependent buttons | Called by daily-briefing.sh |
| `run-sprint-worker.sh` | Async task runner: picks up ready sprint tasks, runs via invoke-agent.sh, supports `depends_on:` task chaining | Every 30 min (launchd) |
| `run-email-workflow.sh` | Email workflow: fuzzy-match action → draft via Claude → operation file with durable HTML body | Via `/email` command in Telegram |
| `send-email.sh` | Gmail SMTP sender; reads HTML from op file (`## Email Body HTML` section) or standalone file | Called by vault-bot.py on /approve |
| `test-vault-automation.sh` | Smoke test: 21 tests covering syntax, lock retry, HTML extraction, config, dirs | On-demand: `--quick` skips AI tests |
| `heartbeat-check.sh` | Agent health monitoring: checks each agent's last run time vs expected schedule | Called by daily-briefing.sh |
| `update-voice-progress.sh` | Update voice pipeline progress JSON (bot polls this to edit Telegram status) | Called by process-voice-memo.sh |
| `log-agent-feedback.sh` | Append structured JSONL entry to Meta/agent-feedback.jsonl | Called by all agent runners |
| `create-handoff.sh` | Write Claude→Codex handoff file + Telegram notify | Called by Claude on token limit |
| `run-handoff.sh` | Execute handoff: Codex runs, validation, commit | Human-triggered after handoff |
| `pre-commit-guard.sh` | Git hook: block dangerous deletes + agent control edits | Always active (git hook) |

Make all shell scripts executable:
```bash
chmod +x Meta/scripts/*.sh
```

Runtime routing is configured in:

```bash
Meta/agent-runtimes.conf
```

Current pattern (2026-04-06 — all on Claude CLI, covered by Max subscription):
- `EXTRACTOR=claude`
- `REVIEWER=claude`
- `IMPLEMENTER=claude`
- `RETROSPECTIVE=claude`
- `RESEARCHER=claude`
- `HANDOFF=claude`
- `TASK_ENRICHER=claude`
- `THINKER=claude`
- `MIRROR=claude`
- `ADVISOR=claude`
- `EMAIL_WORKFLOW=claude`
- `ADVISOR_TRIAGE=claude:haiku` (per-mode override: fast/cheap for Telegram triage)

Token usage is tracked per-agent in `Meta/agent-token-usage.jsonl`. Once we have enough cost data, cheaper agents may move back to Codex.

### Step 3.5: Skills (Just-in-Time Context for AI Agents)

Skills inject focused rules at the moment of action, replacing the need to load all of CLAUDE.md into every prompt. They live in `.claude/skills/`.

```
.claude/skills/
├── vault-writer/SKILL.md       # Note format, frontmatter, emoji, provenance, wikilinks
└── vault-extractor/SKILL.md    # Full extraction checklist, reflection handling, write-back rules
```

**For Cowork sessions:** Skills auto-trigger based on task description.

**For CLI/Codex agents:** Agent scripts should include "Read `.claude/skills/<skill>/SKILL.md` before starting" in the agent prompt instead of inlining rules. This is the lean prompt pattern — ~97% token reduction vs dumping specs into CLI args.

**Adding new skills:** Create a dir in `.claude/skills/<name>/`, write `SKILL.md` with YAML frontmatter (`name`, `description`) and markdown instructions. Update `CLAUDE.md` skill table and `Architecture.md`.

### Step 3.7: Install Pre-Commit Guard

This git hook prevents dangerous deletions and blocks agents from editing control files:

```bash
cd ~/VaultSandbox
ln -sf ../../Meta/scripts/pre-commit-guard.sh .git/hooks/pre-commit
```

What it blocks:
- Deletions in protected dirs (Canon, Thinking/Research, AI-Reflections) unless `VAULT_ALLOW_DELETE=1`
- Agent edits to control files (CLAUDE.md, Architecture.md, agent specs, scripts) unless `VAULT_ALLOW_CONTROL_EDIT=1`
- Warns on bulk commits (>50 files)

Agent runners also auto-clear stale git lock files before clean-tree checks, `git add`, and `git commit`. If a lock remains stuck, run:

```bash
./Meta/scripts/clear-stale-git-locks.sh
```

Voice notes now move through explicit states:
- `status: transcribed` — transcript note created, extraction not started yet
- `status: extracting` — extractor currently running
- `status: extracted` — extraction completed; note auto-archived to `Inbox/Voice/_extracted/`
- `status: failed` — extraction failed and should be retried with `./Meta/scripts/retry-failed.sh`

Pipeline errors now include which step failed (e.g. "extractor failed (exit 1)") via `PIPELINE_STEP` tracking in `process-voice-memo.sh`. Steps: init → metadata → Whisper → extractor → reviewer → manifest → commit/archive.

Also create the handoffs directory:

```bash
mkdir -p Meta/handoffs
```

Full collaboration protocol: `Meta/Collaboration.md`

### Step 4: Set Up the Telegram Bot

1. Open Telegram → search `@BotFather` → `/newbot` → pick a name → copy the token
2. Save the token:
   ```bash
   echo "YOUR_BOT_TOKEN" > ~/.vault-bot-token
   ```
3. Install/reload the launch agents from the repo copy:
   ```bash
   cd ~/VaultSandbox
   ./Meta/scripts/install-launchd.sh
   ```
4. Open Telegram → send `/start` to your bot → it saves your chat ID automatically
5. Test: send `/help` to see all commands

**Important**: This now runs via launchd. Grant Full Disk Access to the runtimes involved in automation:
- `Terminal.app`
- `python3`
- `claude` (Claude CLI — used by all agents)

Restart those apps after toggling Full Disk Access, then run `./Meta/scripts/install-launchd.sh` again.

For one-off debugging, you can still run the bot directly from Terminal:
```bash
cd ~/VaultSandbox
python3 Meta/scripts/vault-bot.py
```

Bot commands:
- `/briefing` — today's briefing
- `/actions` — list open actions (grouped by priority)
- `/review` — items needing human verification
- `/changelog` — recent vault changes
- `/think [topic]` — run the Thinker agent
- `/help` — all commands + quick action syntax

Quick actions (no slash needed):
- `add call dentist` — create a new action
- `add fix taxes - due 2026-04-15 - priority high` — with details
- `done driving license` — mark action as done
- `drop family holiday` — drop an action
- `driving license - due 2026-04-30` — update a field

Review responses: `confirm`, `correct [field] [value]`, `skip`

### Step 5: Set Up iPhone Voice Capture

1. Open **Shortcuts** on iPhone
2. Create shortcut:
   - **Record Audio**
   - **Get Current Location**
   - **Text**: `loc_[Latitude]_[Longitude]_[Current Date]`
   - **Save File**: File = Recording, Destination = `_drop`, Subpath = `[Text].m4a`
3. Turn OFF "Ask where to save"
4. Add to home screen as widget

The `_drop` folder is watched by launchd. The watcher claims each file into `_processing/`, runs Whisper and the agent pipeline automatically, then moves successful audio into `_processed/`. You do not need to invoke anything manually in the normal flow.

### Step 6: Install Scheduled Agents

#### The LaunchAgent Architecture

All vault agents run via macOS launchd. The architecture has 3 layers:

```
launchd → ~/bin/vault-agent-run → Meta/scripts/<agent>.sh → invoke-agent.sh → Claude CLI
```

**Why `vault-agent-run`?** macOS TCC (Transparency, Consent, and Control) applies `com.apple.provenance` restrictions to files in `~/Documents/`. The vault used to be there, and scripts would fail under launchd. `vault-agent-run` lives in `~/bin/` (outside TCC-restricted directories) and sets `HOME`, `PATH`, `VAULT_DIR` before exec-ing the target script.

**Why not just call scripts directly from plists?** launchd doesn't inherit your shell profile. Without explicit `HOME` and `PATH`, agents can't find `python3`, `git`, `whisper`, `claude`, or anything in `/opt/homebrew/bin`.

```bash
# Create the entry point wrapper
mkdir -p ~/bin
cat > ~/bin/vault-agent-run << 'WRAPPER'
#!/bin/bash
export HOME="$HOME"
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
export VAULT_DIR="$HOME/VaultSandbox"
cd "$VAULT_DIR" || exit 1
SCRIPT="$1"; shift
exec /bin/bash "$SCRIPT" "$@"
WRAPPER
chmod +x ~/bin/vault-agent-run
```

#### Install LaunchAgents

```bash
# Install/reload all vault launch agents from the repo copy
./Meta/scripts/install-launchd.sh
```

Verify:
```bash
launchctl list | grep vault
```

Expected output (8 agents):
```
-       0       com.vault.daily-briefing
-       0       com.vault.task-enricher
-       0       com.vault.researcher
-       0       com.vault.daily-retro
-       0       com.vault.weekly-thinker
-       0       com.vault.sprint-worker
31511   0       com.vault.telegram-bot
-       0       com.vault.voice-watcher
```

The telegram bot shows a PID (always-on). Other agents show `-` (scheduled, not currently running).

### Step 7: Configure Whisper

```bash
WHISPER_MODEL=medium   # Options: tiny, base, small, medium, large
WHISPER_LANG=de        # Primary language of voice memos
WHISPER_DEVICE=mps     # Apple Silicon GPU (1.5-3x faster). Options: mps, cpu
```

These are set in `process-voice-memo.sh`.

**Apple Silicon GPU (MPS):** Whisper does NOT auto-detect Apple Silicon GPU. The `--device mps` flag is required for GPU acceleration. Without it, the medium model takes 3+ hours for a 9-minute memo on CPU. With MPS, it takes minutes.

**Timeout:** macOS has no `timeout` command. The pipeline uses `perl -e 'alarm 1800; exec @ARGV'` for a 30-minute hard timeout. See `Meta/Engineering.md` for details.

**Future speedup options:** `mlx-whisper` (3-5x, Apple MLX framework, drop-in), `whisper.cpp` (5-10x, requires compilation).

### Step 7.5: Set Up Email Delivery

The vault can send emails on your behalf (daily briefing, operator-drafted emails). This uses Gmail SMTP with an app password.

1. **Create a Gmail App Password:**
   - Go to myaccount.google.com → Security → 2-Step Verification → App passwords
   - Create one for "Mail" on "Mac"
   - Save the 16-character password

2. **Store credentials:**
   ```bash
   echo "your-app-password-here" > ~/.vault-gmail-app-password
   chmod 600 ~/.vault-gmail-app-password
   echo "your@gmail.com" > ~/.vault-owner-email
   chmod 600 ~/.vault-owner-email
   ```

3. **Test delivery:**
   ```bash
   cd ~/VaultSandbox
   ./Meta/scripts/send-email.sh "your@gmail.com" "Test from vault" /dev/null
   ```

Scripts that use this: `send-email.sh`, `daily-approval-email.sh`, `run-email-workflow.sh`.

`send-email.sh` now supports reading HTML from an operation file's `## Email Body HTML` section. When `/approve` is tapped in Telegram, `vault-bot.py` calls `send-email.sh <to> <subject> <op-file-path>` and the script extracts the HTML automatically.

The daily email is strategy-consultant-quality: each pending item becomes a card with full context (goal, due date, recommendation), a deliverable preview, and smart pre-filled buttons. Blocked items show candidate email addresses from Canon/People/. Design principle: enough context to act without opening anything else.

### Step 8: Verify Engineering Checks

```bash
cd ~/VaultSandbox
make check
```

This runs the local verification path used for script and CI changes.

---

## Agent Specifications

Full agent specs live in `Meta/Agents/`. Summary:

### Extractor
- Triggered by: every new voice memo or substantial Telegram text
- Does: deep extraction of people, events, concepts, decisions, actions
- Rules: checks aliases before creating new entries, respects locked fields, tracks provenance, scans for task-like language
- Output: new/updated Canon entries + git commit
- Default runtime: Claude CLI via `invoke-agent.sh`

### Reviewer
- Triggered by: after every Extractor pass (conditionally) + weekly
- Does: QA on extraction quality
- Key checks: wikilink completeness (EVERY name mention must be linked), duplicate detection, locked field integrity, provenance markers, tag consistency, broken link repair, action field completeness
- **Optimization:** In voice pipeline mode, skips entirely when the Extractor made 0 Canon changes (trivial memos). When it does run, reviews only the specific new note (not the last 10).
- Output: fixes simple issues directly, flags complex ones in review-log.md, queues uncertain facts for human review via Telegram
- Default runtime: Claude CLI via `invoke-agent.sh`

### Thinker
- Triggered by: weekly + on-demand via `/think [topic]`
- Does: reads full vault, finds patterns, surfaces stale actions, proposes connections, does external research
- Output: reflection notes in Meta/AI-Reflections/
- Default runtime: Claude CLI via `invoke-agent.sh`

### Retrospective
- Triggered by: daily 9 PM
- Does: reviews what agents did today, logs learnings, improves agent specs, checks SETUP.md accuracy
- Skips if no changes since last run
- Output: entries in Meta/AI-Reflections/retro-log.md
- Default runtime: Claude CLI via `invoke-agent.sh`

### Briefing
- Triggered by: daily 7:30 AM
- Does: generates morning briefing with open actions, review items, upcoming events
- Output: Inbox note + Telegram push

### Task-Enricher
- Triggered by: daily 8:30 AM + on new action creation
- Does: breaks actions into ADHD-friendly sub-steps, drafts messages in Usman's voice, nudges stale items via Telegram, priority scoring
- Output: enriched action notes + Telegram nudges

### Researcher
- Triggered by: daily scan (`--scan` mode in `daily-briefing.sh`) + on-demand via `/research <topic>` or Cowork
- Does: multi-perspective research (3 lenses, always includes Contrarian), synthesis, verification (max 2 loops), then enrichment
- 7-phase pipeline: notify → context → 3-perspective swarm → synthesis → verification → **enrichment** → commit+notify
- Enrichment phase (5.5): creates concept note in Thinking/, adds Findings section to triggering action, wikilinks related notes
- Trigger signal: actions with `enrichment_status: needs-research`; flips to `researched` when done
- Output: research article in `Thinking/Research/`, concept note in `Thinking/`, enriched action in Canon/Actions/
- Default runtime: Claude CLI via `invoke-agent.sh` (requires `RESEARCHER_WEB_RUNTIME_VERIFIED=1` in agent-runtimes.conf)
- Schedule: Daily 9:00 AM via launchd (`com.vault.researcher.plist`), 30 min after Task-Enricher's morning mode auto-flags research needs
- Full spec: `Meta/Agents/Researcher.md`

### Operator
- Triggered by: after Task-Enricher enriches an action (on-demand or scheduled via `operator-dispatch` Cowork task)
- Does: takes enriched actions and creates the actual deliverable — Gmail drafts, calendar events, documents, messages
- Key constraint: **NEVER fires without human approval.** Writes `Meta/operations/pending/op-XXXX.md`; vault-bot.py sends Telegram with approve/reject buttons; human must press ✅
- Output: deliverable (e.g. Gmail draft) + pending op file → Telegram notification → moved to `Meta/operations/completed/` on approval
- Script: `operator-dispatch` Cowork scheduled task at `$HOME/Documents/Claude/Scheduled/operator-dispatch/SKILL.md`
- Bot commands: `/ops`, `/approve OP_ID`, `/reject OP_ID`

---

## Note Format (Canon Entries)

```yaml
---
type: person | event | concept | decision | project | action | place
name: "Full Display Name"       # e.g. Jeremia "Jerry" Riedel
created: 2026-03-20
updated: 2026-03-20
source: voice | human | ai-extracted | ai-generated | ai-enriched
source_agent: Extractor          # which AI agent made this change
source_date: 2026-03-31T14:30   # when the agent acted
aliases:                         # alternative names/spellings
  - Jerry
  - Jeremia
tags:                            # for quick scanning/clustering
  - best-friend
  - work
  - hamburg
linked:                          # explicit relationships
  - "[[Usman Kotwal]]"
locked:                          # human-verified fields AI must not change
  - born
---
```

People entries additionally use: `born`, `phone`, `email`, `city`, `employer`, `relationship`, `relationship_to`.

Action entries use: `status` (open/in-progress/done/dropped), `priority` (high/medium/low), `due`, `start`, `owner`, `output`, `mentions`.

---

## Wikilink Rules

Wikilinks are the vault's nervous system. Rules:

1. **Every mention of a known person = a wikilink.** No exceptions.
2. For aliases, use display links: `[[Jeremia Riedel|Jerry]]`
3. Never wikilink inside `# Raw` sections or frontmatter
4. If a target note doesn't exist, create a stub or flag it
5. The Reviewer agent enforces this on every pass
6. When renaming a file, update all incoming links (use Obsidian's rename or the Reviewer)

---

## Tag Vocabulary (Canon/People/)

Standard tags for people entries:

**Relationship**: `family`, `best-friend`, `close-friend`, `friend`, `partner`, `colleague`, `former-colleague`, `manager`, `former-manager`, `cofounder`, `ex-cofounder`

**Context**: `work`, `startup`, `hamburg`, `berlin`, `career-crossroads`

**Role**: `child-of-friend`, `partner-of-friend`, `sibling-of-friend`, `in-law`, `family-of-friend`

**Work**: employer names as tags (e.g. `porsche`, `valeo`, `otto-group`)

---

## Review Queue

When agents find uncertain facts (ambiguous dates, garbled names, conflicting info), they add review items under `Meta/review-queue/`. The Telegram bot pushes these to the human. Flow:

```
Agent flags uncertain fact → queue-review.sh → Meta/review-queue/[timestamp]-[slug].md (status: pending)
  → Telegram bot sends to user (status tracked on the review item)
  → User replies: confirm / correct / skip
  → Confirmed fields get locked in the Canon entry
```

---

## Changelog

Every agent logs what it did to `Meta/changelog.md`. It reads like a timeline of vault activity. Git is the forensic trail; the changelog is the executive summary.

Operational note:
- `.obsidian/workspace.json` is intentionally ignored and no longer tracked. It is local UI state, not vault content.
- Main workhorse runners now write the changelog entry before the runner-owned final commit, so one agent run usually lands as one clean commit instead of a main commit plus a tiny changelog follow-up.

## Extractor Fixture Test

A lightweight extractor fixture lives in:

```bash
tests/test-extractor/
```

It creates a temporary mini-vault, runs `run-extractor.sh` against a realistic sample inbox note, and checks:
- `# Raw` remains untouched
- `## Extracted` exists
- `source:` appears in created notes
- H1 headings include emoji
- duplicate people are not created when aliases already exist
- wikilinks resolve to real files

---

## Logs

All launchd agents log to `/tmp/vault-*.{log,err}`. See "Monitoring & Debugging" section below for full list.

Key log files:
```bash
/tmp/vault-telegram-bot.log           # Telegram bot (combined stdout+stderr, always-on)
/tmp/vault-voice-watcher.log          # Voice pipeline processing
/tmp/vault-daily-briefing.log         # Morning briefing
/tmp/vault-task-enricher.log          # Task enrichment
/tmp/vault-researcher.log             # Research agent
/tmp/vault-daily-retro.log            # Retrospective
/tmp/vault-weekly-thinker.log         # Weekly maintenance
/tmp/vault-sprint-worker.log          # Sprint worker

# Structured logs (JSONL, machine-readable)
Meta/agent-token-usage.jsonl          # Per-agent token/cost tracking
Meta/agent-feedback.jsonl             # Structured agent events (completion, errors, etc.)

# Human-readable logs (Markdown)
Meta/changelog.md                     # Timeline of all vault changes
Meta/AI-Reflections/retro-log.md      # Retrospective findings
Meta/AI-Reflections/review-log.md     # Reviewer findings
Meta/AI-Reflections/implementer-log.md # Implementer actions
```

---

## Manual Usage

```bash
cd ~/VaultSandbox

# Verify repo/tooling health
make check

# Process a specific audio file
./Meta/scripts/process-voice-memo.sh path/to/audio.m4a

# Meeting recording (multi-speaker)
./Meta/scripts/process-voice-memo.sh path/to/meeting.m4a --meeting

# Run thinker on a specific topic
./Meta/scripts/run-thinker.sh "co-founder decision"

# Generate Canvas views
./Meta/scripts/build-canvas.sh overview
./Meta/scripts/build-canvas.sh actions
./Meta/scripts/build-canvas.sh people

# Manual daily briefing
./Meta/scripts/daily-briefing.sh

# Manual retrospective
./Meta/scripts/run-retro.sh

# Inspect or change agent runtime routing
cat Meta/agent-runtimes.conf
```

---

## Stopping Agents

```bash
# Stop individual agents
launchctl unload ~/Library/LaunchAgents/com.vault.voice-watcher.plist
launchctl unload ~/Library/LaunchAgents/com.vault.daily-briefing.plist
launchctl unload ~/Library/LaunchAgents/com.vault.task-enricher.plist
launchctl unload ~/Library/LaunchAgents/com.vault.researcher.plist
launchctl unload ~/Library/LaunchAgents/com.vault.daily-retro.plist
launchctl unload ~/Library/LaunchAgents/com.vault.weekly-thinker.plist
launchctl unload ~/Library/LaunchAgents/com.vault.sprint-worker.plist
launchctl unload ~/Library/LaunchAgents/com.vault.telegram-bot.plist

# Stop everything
launchctl list | grep vault | awk '{print $3}' | xargs -I{} launchctl unload ~/Library/LaunchAgents/{}.plist

# Check what's running
launchctl list | grep vault
```

## Monitoring & Debugging

```bash
# Check agent health (which agents ran recently, which are stale)
./Meta/scripts/heartbeat-check.sh

# View agent logs
cat /tmp/vault-daily-briefing.log      # Morning briefing
cat /tmp/vault-task-enricher.log       # Task enricher
cat /tmp/vault-researcher.log          # Researcher
cat /tmp/vault-daily-retro.log         # Retrospective
cat /tmp/vault-weekly-thinker.log      # Weekly maintenance
cat /tmp/vault-sprint-worker.log       # Sprint worker
cat /tmp/vault-telegram-bot.log        # Telegram bot (combined stdout+stderr)
cat /tmp/vault-voice-watcher.log       # Voice watcher

# View token usage per agent
cat Meta/agent-token-usage.jsonl | python3 -c "
import json, sys
from collections import defaultdict
costs = defaultdict(float)
for line in sys.stdin:
    d = json.loads(line)
    costs[d['agent']] += d.get('cost_usd', 0)
for agent, cost in sorted(costs.items(), key=lambda x: -x[1]):
    print(f'  {agent:20s} \${cost:.4f}')
"

# View recent agent feedback events
tail -20 Meta/agent-feedback.jsonl | python3 -m json.tool

# View vault health
./Meta/scripts/vault-health.sh

# Check git status (filtered to ignore operational noise)
source Meta/scripts/lib-agent.sh && agent_filtered_worktree_status
```

---

## Known Issues & Workarounds

### macOS Portability (CRITICAL — read before writing any shell script)

These bit us hard. All three caused silent, weeks-long failures.

**A. macOS `sed` does NOT support `\s`** — use `[[:space:]]` instead. BSD sed treats `\s` as literal backslash+s. This broke ALL YAML field parsing in 3 scripts (71 instances) for weeks. Every status comparison silently failed.
```bash
# WRONG on macOS: produces " open" (backslash-s not matched)
sed 's/^status:\s*//'
# CORRECT: POSIX character class, works everywhere
sed 's/^status:[[:space:]]*//'
```

**B. macOS has no `timeout` command** — use `perl -e 'alarm N; exec @ARGV'`. The `timeout` command silently fails (especially when stderr is suppressed).
```bash
# WRONG: timeout doesn't exist on macOS
timeout 1800 whisper "$AUDIO"
# CORRECT: perl alarm is POSIX-compatible
perl -e 'alarm 1800; exec @ARGV' whisper "$AUDIO"
```

**C. Never use backticks in double-quoted prompt strings** — backticks trigger command substitution. Bash tries to execute the backtick content as a shell command.
```bash
# WRONG: bash executes `status: extracted` as a command
PROMPT="Set \`status: extracted\` in frontmatter"
# CORRECT: just use plain text
PROMPT="Set status: extracted in frontmatter"
```

**D. Whisper requires explicit `--device mps`** for Apple Silicon GPU. Without it, medium model on CPU takes 3+ hours for a 9-minute memo.

See `Meta/Engineering.md` for full details.

### Infrastructure Issues

1. **macOS FDA (Full Disk Access)**: if a launch agent reports `Operation not permitted`, make sure Full Disk Access is enabled for `Terminal.app`, `python3`, and `claude` as applicable, then rerun `./Meta/scripts/install-launchd.sh`.
2. **Codex CLI under launchd**: Codex stdin pipe stalls on complex prompts under launchd. All agents currently use Claude CLI instead. When Codex pipe issue is resolved, cheaper agents can move back.
3. **Telegram voice .ogg files**: Whisper needs ffmpeg for .ogg decoding. Install: `brew install ffmpeg`
4. **Retro skips**: The retrospective agent skips if no git commits happened since the last retro. This is intentional.
5. **Computer asleep or shut**: local launchd jobs do not run while the machine is asleep or powered off. For always-on automation, use an always-on Mac or a remote worker.
6. **Stale agent locks**: If an agent crashes, its lock may persist. `heartbeat-check.sh` auto-detects and clears these. Manual fix: `rm -f .agent-locks/*`
7. **Voice pipeline lock contention**: The voice pipeline (`process-voice-memo.sh`) now has opt-in lock retry (3 attempts, 30s apart). If another agent holds the lock, voice memos wait up to 90s instead of failing. On final failure, a Telegram alert is sent. To enable retry in other scripts: `export AGENT_LOCK_RETRY=true` before calling `agent_acquire_lock`.
8. **Voice watcher stuck**: The voice watcher no longer uses locks (mv is atomic). If files sit in `_drop/` without processing, check `launchctl list | grep vault` and restart the watcher.
9. **build-manifest.sh `pipefail` sensitivity**: Any new `grep` or `ls` in this script MUST have `|| true` guards because `set -euo pipefail` kills the process on zero-match exit codes. This crashed the entire voice pipeline post-extraction until fixed (2026-04-03).
10. **Researcher needs web access**: `run-researcher.sh` requires `RESEARCHER_WEB_RUNTIME_VERIFIED=1` in `agent-runtimes.conf`. Without this, the researcher exits immediately as a safety gate.
11. **Email workflow routing**: `run-email-workflow.sh` currently treats all actions as email tasks. Research actions should be flagged `enrichment_status: needs-research` instead. The Task-Enricher should classify actions before routing.
12. **Dirty worktree blocks agents**: Agents call `agent_assert_clean_worktree` and refuse to run if there are uncommitted changes. Commit or stash before triggering agents, or set `VAULT_AGENT_ALLOW_DIRTY=1` to override.

---

## Recreating This From Scratch

If you're an AI agent tasked with rebuilding this system:

1. Read `CLAUDE.md` first — it defines all behavior rules
2. Read `AGENTS.md`, `Meta/Architecture.md`, and `Meta/Engineering.md`
3. Read each agent spec in `Meta/Agents/` — they define the extraction, review, and thinking logic
4. Load `.claude/skills/` for task-specific rules — vault-writer for note creation, vault-extractor for extraction
5. The scripts in `Meta/scripts/` are the glue — agent runners call `invoke-agent.sh`, which routes each agent to Claude CLI (all agents on Claude as of 2026-04-06)
6. The Telegram bot (`vault-bot.py`) is the user interface + always-on service; the voice watcher (`watch-voice-drop.sh`) owns audio processing
7. The review queue pattern (`Meta/review-queue/` + bot) is how uncertain facts get human-verified
8. Tags and wikilinks are enforced by the Reviewer — not optional, structural
9. The Retrospective agent is self-improving — it reviews what worked and updates agent specs
10. All launchd plists route through `~/bin/vault-agent-run` — a tiny wrapper that sets HOME, PATH, VAULT_DIR and execs the target script

### Reading order for full system understanding:
```
CLAUDE.md                          → Agent behavior rules
Meta/Architecture.md               → System blueprint + agent registry + lifecycle
Meta/Engineering.md                → macOS portability rules + coding standards
Meta/scripts/SETUP.md              → This file: setup, config, all scripts
Meta/agent-runtimes.conf           → Which runtime each agent uses
Meta/decisions-log.md              → Why things are the way they are
Meta/changelog.md                  → What changed when
Meta/AI-Reflections/*Handoff*.md   → Per-session detailed records
Meta/Agents/*.md                   → Individual agent specs
```

### Key infrastructure files:
```
~/bin/vault-agent-run              → LaunchAgent entry point (sets env, execs script)
Meta/scripts/invoke-agent.sh       → LLM dispatch (reads runtimes.conf, calls Claude/Codex)
Meta/scripts/lib-agent.sh          → Shared bash helpers (locks, git safety, worktree checks)
Meta/scripts/vault-lib.py          → Shared Python library (SDK streaming, config parsing)
Meta/scripts/vault-bot.py          → Telegram bot (always-on, 159KB, main user interface)
Meta/agent-runtimes.conf           → Runtime routing config (source of truth)
Meta/agent-token-usage.jsonl       → Per-agent cost tracking
Meta/agent-feedback.jsonl          → Structured agent event log
```

### Active launchd schedule (8 agents):
```
07:30  daily-briefing.sh            Morning briefing → Telegram + email
08:30  run-task-enricher.sh --morning  Score actions → chain into enrichment scan
09:00  run-researcher.sh --scan     Research flagged actions → Thinking/Research/
21:00  run-retro.sh                 Retrospective → spec improvements
Sun 10:00  weekly-maintenance.sh    Temperature + manifest + thinker + reviewer + mirror
Every 30min  run-sprint-worker.sh   Sprint task runner
Always-on  vault-bot.py             Telegram bot (KeepAlive)
WatchPaths  watch-voice-drop.sh     Voice memo processor (triggered by _drop/ changes)
```

### Secret files (all must exist for full operation):
```
~/.vault-bot-token                 Telegram Bot API token
~/.vault-bot-chat-id               Allowed Telegram chat ID
~/.vault-gmail-app-password        Gmail App Password for SMTP
~/.vault-owner-email               Owner's Gmail address
~/.anthropic/api_key               Anthropic API key (for SDK streaming; optional)
```

The intent: a system where one person can talk freely and have their knowledge automatically organized, linked, and surfaced without any manual work. The vault should feel alive — not like a filing cabinet.
