# AutoADHD

A personal operating system for the ADHD brain. You talk, the system remembers. You forget, the system reminds. You avoid, the system nudges. You succeed, the system connects the dots you didn't see.

Your only job: **think out loud** and **say yes or no**.

---

## What This Is

AutoADHD is an [Obsidian](https://obsidian.md) vault wired with 12 AI agents that turn voice memos into structured knowledge, surface what matters, and execute tasks on your behalf — with your approval.

Built by someone with ADHD, for someone with ADHD. Every design decision optimizes for one thing: **reducing the gap between thinking and doing to zero friction**.

You send a voice memo via Telegram. The system transcribes it locally with Whisper (nothing leaves your machine), extracts people, actions, events, decisions, and reflections, links everything with wikilinks, and files it into a structured knowledge base. The next morning, it tells you what matters. When you're ready, it drafts the email, schedules the meeting, or runs multi-perspective research — and asks you to approve before anything goes out.

~16,500 lines of bash and Python. 59 scripts. 12 agents. One leaky ADHD brain that finally stops dropping things.

---

## The Pipeline

```
Voice memo (Telegram or iPhone Shortcut)
    ↓  🔥 instant acknowledgment
Whisper transcription (local, private, Apple Silicon GPU)
    ↓  📝 "transcribed, 247 words"
AI Extraction → Canon entries (people, actions, events, concepts, decisions, beliefs, places)
    ↓  ✅ "2 people updated, 1 action created, 1 reflection saved"
QA Review → catches duplicates, broken links, missing data
    ↓  (invisible — you never see this)
Morning Briefing → Telegram push
    ↓  📋 "here's what needs you today"
Task Decomposition → ADHD-friendly sub-steps
    ↓  🎯 one question at a time
Research (if needed) → 3 perspectives, synthesis, verification
    ↓  🔬 article written, findings scattered into vault
Execution → email, calendar, documents
    ↓  ⚡ "approve this?" → one tap
Done.
```

Every step gives you feedback. Silence is the enemy of the ADHD brain — this system never goes quiet on you.

---

## Architecture

### 12 AI Agents

| Agent | What it does | When |
|-------|-------------|------|
| **Extractor** | Pulls people, events, actions, decisions, places from voice memos. Checks aliases before creating duplicates. Updates existing entries. | On every new memo |
| **Reviewer** | QA pass — catches duplicates, broken wikilinks, missing provenance. Fixes simple stuff, flags the rest. Skipped on trivial memos to save tokens. | After extraction (conditional) |
| **Implementer** | The self-healing agent. Reads what Retro and Reviewer found, auto-fixes safe issues, queues dangerous ones for approval. | After Reviewer + Retro |
| **Thinker** | Reads the full vault. Finds patterns, contradictions, stale actions, orphaned notes. Proposes connections. Does external research. | Weekly (Sunday) |
| **Mirror** | Reflects behavioral patterns back. Checks belief-action alignment. Tracks energy. Direct tone — like a coach, not a cheerleader. | Weekly (Sunday) |
| **Briefing** | Morning push: 🔴 what needs you, ✨ what's new, 🟢 what just happened. Pushed to Telegram + written to Obsidian. | Daily 7:30 AM |
| **Retrospective** | Vault health check — what worked, what broke, what agents did that day. Triggers Implementer when it finds issues. | Daily 9:00 PM |
| **Task-Enricher** | Breaks vague actions into ADHD-friendly sub-steps. Drafts messages in your voice. Nudges stale items. Flags actions that need research. Priority scoring. | Daily 8:30 AM + on-demand |
| **Researcher** | Spawns 3 perspective agents (e.g. customer-first, strategist, contrarian). Synthesizes findings. Verification pass with max 2 correction loops. Scatters results back into vault. | Daily 9:00 AM scan + on-demand |
| **Operator** | Drafts deliverables (email, calendar event, document). Presents review package with approve/reject buttons. Executes via Gmail SMTP or MCP tools. **Never fires without explicit human approval.** | On-demand |
| **Advisor** | Strategic brain on Telegram. Knows your full vault context — goals, beliefs, actions, decision history. Streams responses progressively. Three modes: quick triage, deep `/ask`, multi-perspective `/strategy`. | Always-on |
| **Orchestrator** | Takes a decomposed action and walks a DAG: automated steps run in parallel, user-facing steps come one at a time, research triggers when needed. State machine backed by JSON. | On `/run` + every 5 min |

### 5 Runtimes

| Runtime | What it is | Best for |
|---------|-----------|----------|
| **Claude Code CLI** | Scheduled agents on local Mac via launchd | Extraction, review, research, self-healing |
| **Telegram Bot** (Python) | Persistent process, two-way messaging, Advisor streaming via Anthropic SDK | Voice capture, approvals, Advisor conversations |
| **Cowork (Claude Desktop)** | Interactive sessions with MCP tools (Gmail, Calendar, Drive, Notion, Figma, Chrome) | Complex multi-tool workflows requiring human presence |
| **Vault MCP Server** (Python) | Model Context Protocol server for structured vault access | Any MCP-compatible client can query the vault |
| **OpenAI Codex** | Cloud coding agent via git workflows | Code-heavy tasks, parallel analytical passes |

All agents currently route through Claude CLI (Max subscription). Runtime routing is configurable — swap providers without changing agent logic.

### Self-Healing Loop

```
Retro finds bug ──→ writes to retro-log.md ──→ Implementer reads ──→ fixes the bug
                                                                     ├─ safe fix? → apply + commit silently
                                                                     └─ risky fix? → queue for human review via Telegram
```

```
Reviewer flags issue ──→ writes to review-log.md ──→ Implementer reads ──→ fixes it
                                                                          ├─ missing wikilink? → add it
                                                                          ├─ missing stub? → create it
                                                                          └─ locked field conflict? → queue for human
```

The system finds its own problems and fixes them. You don't maintain it. It maintains itself.

### Review Gates (3 Tiers, Code-Enforced)

| Tier | What happens | Examples |
|------|-------------|----------|
| **Tier 1: Silent** | Auto-fix, no notification | Wikilinks, stubs, YAML fixes, manifest updates |
| **Tier 2: Notify** | Fix it, then tell you | New Canon entries, enrichment, status changes |
| **Tier 3: Gate** | Must approve before execution | Emails, calendar events, deletions, locked fields, money |

---

## ADHD Design Principles

These aren't features. They're the architecture.

**1. Voice-first.** The gap between "I should write this down" and actually writing it is where 90% of ideas die. Voice kills that gap. You send a memo while walking. Your phone buzzes with 🔥. Later: "2 people updated, 1 action created." You never opened Obsidian.

**2. Zero-friction capture.** Every step between thought and capture is a dropout point. You drop a voice memo. You let go. It arrives. Like dropping a letter in a mailbox.

**3. The system works while you don't.** ADHD brains can't maintain systems. They can use systems that maintain themselves. Like a garden that weeds itself — you plant seeds (voice memos), the garden grows.

**4. Approve, don't operate.** You're good at "yes/no" — bad at "draft the email, find the address, attach the file, send it." The system presents decisions, not to-do lists. "Approve this email to Lisa?" → one button.

**5. Feedback at every step.** If you drop something into a system and hear nothing back, your ADHD brain assumes it's broken. Silence = anxiety. This system shows live progress in Telegram — same message gets edited as each pipeline stage completes.

| Stage | Emoji | Meaning |
|-------|-------|---------|
| Received | 👀 | "I see your message" |
| Saved | 👌 | "Filed, waiting for agent" |
| Working | ⚡ | "Agent is on it" |
| Done | 👍 | "Finished — here's what changed" |
| Failed | 👎 | "Something broke — here's what and why" |

**6. Self-healing.** When an agent breaks something, another agent finds it and fixes it. No human maintenance. I opened the vault after a week away. Everything worked.

### The Emotional Arc

```
CAPTURE:     "I just said something"           → 🔥 "It heard me"
PROCESSING:  (5 min pass)                      → ✅ "It understood me"
SURFACING:   (next morning)                    → 📋 "It remembered for me"
NUDGING:     (3 days later)                    → 🎯 "It won't let me forget"
EXECUTING:   (when I'm ready)                  → ⚡ "It did the work for me"
REFLECTING:  (weekly)                          → 🤖 "It sees patterns I missed"
```

Each step produces a small dopamine hit. The system is a dopamine-positive feedback loop for productivity.

### ADHD-Friendly Design Checklist

For every new feature, ask:

- Does this reduce friction or add it?
- Does the user get feedback within 1 second?
- Can the user respond with one tap?
- Does this work if the user ignores it for a week?
- Would someone with ADHD actually use this, or just intend to?
- Does this create a small dopamine hit?
- Does this fail gracefully and visibly?

---

## Vault Structure

Four zones. Raw → Forming → Producing → Crystallized.

```
Inbox/                  → Zone 1: raw capture (voice memos, quick notes)
  Inbox/Voice/          → transcribed voice memos with # Raw sections (read-only)
  Inbox/Voice/_drop/    → audio files land here, pipeline picks them up

Thinking/               → Zone 2: the whiteboard
  Thinking/Research/    → multi-perspective research articles from Researcher agent
  (reflections, beliefs, emerging ideas, concepts live here)

Articles/               → Zone 3: the writing desk (long-form, strategy docs, know-how)

Canon/                  → Zone 4: crystallized knowledge
  Canon/People/         → 👤 everyone mentioned in voice memos
  Canon/Events/         → 📅 things that happened
  Canon/Actions/        → 🎯 tasks, intentions, things to do
  Canon/Decisions/      → ⚖️ choices made
  Canon/Beliefs/        → 🪨 what you hold to be true
  Canon/Projects/       → 📁 larger efforts
  Canon/Places/         → 📍 locations with context
  Canon/Organizations/  → 🏢 companies, groups

Meta/                   → system rules, agent specs, scripts, logs
  Meta/Agents/          → 12 agent specification files
  Meta/scripts/         → 59 shell/Python scripts (the plumbing)
  Meta/AI-Reflections/  → agent observations, review logs, retro logs
  Meta/sprint/          → sprint board (active tasks, backlog, proposals)
  Meta/operations/      → operator approval queue (pending/completed)
  Meta/decomposer/      → orchestrator state files (DAG execution)
```

### Note Types

Every note has typed frontmatter and an emoji heading for fast visual scanning:

```yaml
---
type: action
name: Get driving license
status: open
priority: medium
source: voice
owner: "[[Usman Kotwal]]"
first_mentioned: 2026-03-16
mentions:
  - 2026-03-16 - Voice - morning-memo.md
  - 2026-03-22 - Voice - car-stuff.md
linked:
  - "[[Usman Kotwal]]"
---

# 🎯 Get Driving License

...
```

Supported types: `person`, `event`, `action`, `concept`, `decision`, `reflection`, `belief`, `project`, `place`, `organization`, `ai-reflection`, `research`, `emerging`.

Every note tracks provenance — where each fact came from and which agent touched it:

```yaml
source: voice              # spoken by human
source: ai-extracted       # AI pulled from a transcript
source_agent: Extractor    # which agent
source_date: 2026-03-31    # when
```

Human-verified facts can be locked so no agent can change them:

```yaml
locked:
  - born
  - name
```

---

## Five Workflows

### A: Thought → Knowledge ✅

Voice memo → Whisper transcription → Extractor creates/updates Canon entries → Reviewer QA → wikilinks everything → committed to git.

**Cycle time:** ~5-10 minutes from voice memo to structured knowledge.

### B: Knowledge → Awareness ✅

Canon + open actions + review queue → morning Briefing agent → pushed to Telegram at 7:30 AM.

Three tiers: 🔴 Needs You → ✨ What's New → 🟢 Just Happened.

### C: Knowledge → Research ✅

Action tagged `enrichment_status: needs-research` → Researcher spawns 3 perspective agents → synthesis with verification → article in Thinking/Research/ → findings scattered back into action notes and concept entries.

### D: Knowledge → Execution ✅ (Email V1)

Action ready for execution → Operator drafts deliverable → writes to operations/pending/ → Telegram with ✅/❌ buttons → human approves → executed via Gmail SMTP or MCP tools → action marked done.

### E: Execution → Learning 🚧

Post-execution feedback → "how did it go?" → feeds back into Canon. Planned, not built yet.

---

## What's Working

- Voice capture via Telegram — one button, instant 🔥 feedback, live progress tracking
- Full extraction pipeline: voice → transcript → Canon entries with wikilinks
- Self-healing loop: Retro → Implementer → auto-fix (Tier 1 issues handled silently)
- Morning briefing pushed to Telegram at 7:30 AM
- Review gates with approve/reject buttons in Telegram
- Action decomposition into ADHD-friendly sub-steps (one question at a time)
- Multi-perspective Researcher (3 viewpoints + synthesis + verification)
- Advisor with full vault context, streaming responses in Telegram
- Email execution workflow (draft → approve → send via SMTP)
- Orchestrator state machine for multi-step action execution
- Per-agent token usage tracking
- Conditional Reviewer (skips trivial memos — saves tokens)
- iPhone Shortcut capture with automatic location-based naming
- Pre-commit guards preventing dangerous deletes
- Concurrency locks with stale-detection (15-min auto-break)

## What's Still Rough

I'm an amateur building this for myself. Here's what's not solved yet:

- **Setup requires technical skill.** CLI, Python, launchd, git, Whisper, Telegram bot token, API keys. There's a detailed setup guide but it's not plug-and-play. You will need to tinker.
- **macOS only.** Launchd for scheduling, Homebrew for dependencies, Apple Silicon for Whisper GPU acceleration. No Windows or Linux support yet.
- **40+ open actions = overwhelm.** The system needs a `/next` that shows THE ONE thing, not everything.
- **No completion dopamine.** Marking something done should feel like something. No celebration, no streak, no confetti.
- **Stale actions become a wall of shame** instead of auto-dropping after 3 ignored nudges.
- **No "I'm overwhelmed" mode.** Can't tell the system "pause everything for 2 hours."
- **Morning briefing too text-heavy.** Should be 3 bullets max, not a newspaper.
- **Codex integration paused.** Stdin pipe stalls under launchd on macOS — all agents on Claude CLI for now.

---

## Tech Stack

| Component | What | Why |
|-----------|------|-----|
| **Obsidian** | The vault — markdown files + wikilinks + Dataview queries | Plain text = portable, inspectable, git-friendly |
| **Whisper** | Local voice transcription on Apple Silicon GPU | Private (nothing leaves your machine), free, fast |
| **Claude CLI + Anthropic API** | Primary LLM runtime for all 12 agents | Max subscription covers unlimited agent runs |
| **Python** | Telegram bot, orchestrator, MCP server, shared vault library | Anthropic SDK for streaming, Telegram API |
| **Bash** | 59 scripts: agent runners, voice pipeline, scheduling, git ops | Glue between everything, runs everywhere on Mac |
| **launchd** | macOS scheduler — 8 scheduled agent jobs | Persistent, survives reboots, native Mac |
| **Telegram Bot API** | Two-way: voice input, push notifications, approval buttons, Advisor chat | Already on your phone, voice messages built in |
| **Git** | Every change tracked, pre-commit guards, full safety net | Mistakes are revertable. Always. |
| **Gmail SMTP** | Email execution via app password | Simple, reliable, no OAuth complexity |
| **MCP** | Model Context Protocol server for structured vault access | Any MCP-compatible tool can query the vault |

### Cost

Currently running on Claude Max subscription ($100/month) which covers all agent runs. Advisor triage can optionally use Haiku via API (~$0.003/call) for fast Telegram responses. Whisper is free (local). Telegram is free. Total running cost: **$100/month**.

---

## Getting Started

> **You don't need to be a developer.** You need a Mac, some patience, and an AI assistant (Claude, ChatGPT, or similar) to help you through the steps. Each step below is written so you can paste it into Claude or ChatGPT and say "help me do this."

### What You Need

- **A Mac** (macOS 13+, Apple Silicon recommended for fast Whisper transcription)
- **An AI assistant** to help with setup — Claude (via [claude.ai](https://claude.ai), Claude Code, or Cowork), ChatGPT, or similar
- **30-60 minutes** for initial setup

### Step 1: Install the Basics

Open Terminal (search for "Terminal" in Spotlight) and run these one at a time:

```bash
# Install Homebrew (macOS package manager)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install git, python, node, ffmpeg
brew install git python node ffmpeg

# Install Obsidian (the vault app)
brew install --cask obsidian
```

> 💡 **Stuck?** Paste the error message into your AI assistant and ask "what went wrong?"

### Step 2: Clone the Repo

```bash
cd ~
git clone https://github.com/uetzel/AutoADHD.git
cd AutoADHD
```

Open Obsidian → "Open folder as vault" → select `~/AutoADHD`.

### Step 3: Set Up Your Environment

```bash
cp .env.example .env
```

Now open `.env` in a text editor and fill in the values. You'll need:

**Telegram Bot Token:**
1. Open Telegram, search for `@BotFather`
2. Send `/newbot`, follow the prompts
3. Copy the token into `.env` as `TELEGRAM_BOT_TOKEN`

**Anthropic API Key:**
1. Go to [console.anthropic.com](https://console.anthropic.com)
2. Create an API key
3. Copy it into `.env` as `ANTHROPIC_API_KEY`

> 💡 If you have a Claude Max subscription ($100/month), you can use Claude CLI for all agents at no extra API cost. Otherwise, API calls cost ~$5-15/month depending on usage.

### Step 4: Install Dependencies

```bash
# Python dependencies
pip install openai-whisper python-telegram-bot anthropic --break-system-packages

# Claude CLI (for running agents)
npm install -g @anthropic-ai/claude-code

# Verify Whisper works
python -c "import whisper; print('Whisper OK')"
```

### Step 5: Configure Whisper

Test transcription with any audio file:

```bash
whisper test-audio.m4a --model medium --language en --device mps
```

Edit your `.env` to set your language:
- `WHISPER_LANGUAGE="en"` for English
- `WHISPER_LANGUAGE="de"` for German
- `WHISPER_DEVICE="mps"` for Apple Silicon (fast), `"cpu"` for Intel Macs (slower)

### Step 6: Start the Telegram Bot

```bash
python Meta/scripts/vault-bot.py
```

Send `/start` to your bot on Telegram. It should respond and tell you your chat ID. Copy that into `.env` as `VAULT_BOT_CHAT_ID`.

**Test it:** Send a voice memo to the bot. You should see 🔥 immediately, then processing messages.

### Step 7: Install Scheduled Agents

This sets up the agents that run automatically (morning briefing, nightly retro, etc.):

```bash
# Edit the plist files to use YOUR home directory
# (replace HOME_DIR_PLACEHOLDER with your actual home path)
find Meta/scripts -name "*.plist" -exec sed -i '' "s|HOME_DIR_PLACEHOLDER|$HOME|g" {} +

# Install launchd agents
Meta/scripts/install-launchd.sh
```

### Step 8: Personalize

The system comes with example content and my name ("Usman") in the agent prompts. Make it yours:

```bash
# Replace the owner name in agent specs and scripts
# Use your AI assistant: "Help me search and replace 'Usman Kotwal' with 'YOUR NAME'
# and 'Usman' with 'YOUR FIRST NAME' across all .md and .sh files in this repo"
```

Files to personalize:
- `Meta/Agents/*.md` — agent prompts reference you by name
- `Meta/scripts/run-advisor.sh` — Advisor personality is tuned to the owner
- `CLAUDE.md` — vault rules reference the owner
- `Meta/style-guide.md` — fill in YOUR writing voice (agents use this to draft in your style)
- `Meta/Agents/advisor-knowledge.md` — starts empty, the Advisor fills it in over time

> 💡 **Ask your AI assistant:** "I cloned VaultSandbox. Help me personalize all the agent specs and scripts to use my name and context instead of the example ones."

### Step 9: Delete Mock Content, Start Fresh

The repo comes with mock people (Alex Chen, Sam Rivera, Jordan Park) and sample actions to show what the system produces. Once you've seen how it works:

```bash
# Remove mock content
rm Canon/People/*.md Canon/Actions/*.md Canon/Events/*.md
rm Canon/Decisions/*.md Canon/Organizations/*.md
rm Thinking/*.md Inbox/Voice/*.md
rm Meta/AI-Reflections/2026-W04*.md

# Keep the log files (they'll be appended to)
# Keep Canon/README.md (it explains the structure)
```

Now send your first real voice memo. The system takes it from here.

### Step 10: Verify

```bash
make check
```

This runs tests, linting, and verification. If something fails, paste the output into your AI assistant.

### Optional: Gmail Integration

For the email execution workflow (system drafts and sends emails on your behalf):

1. Go to [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)
2. Generate an app password for "Mail"
3. Add to `.env`: `GMAIL_USER` and `GMAIL_APP_PASSWORD`

### Optional: iPhone Voice Capture

Set up an iOS Shortcut that records audio, names it based on your location, and drops it into the vault's `Inbox/Voice/_drop/` folder (via iCloud or ssh). The detailed setup is in `Meta/scripts/SETUP.md`.

---

## LLM Configuration

`Meta/agent-runtimes.conf` controls which LLM provider runs which agent:

```bash
# Default: all agents on Claude CLI
EXTRACTOR=claude
REVIEWER=claude
RESEARCHER=claude
ADVISOR=claude

# Optional: fast + cheap Advisor triage via API
ADVISOR_TRIAGE=claude:haiku

# Future: swap individual agents to other providers
# EXTRACTOR=codex
# RESEARCHER=openai
```

The soul of the system lives in the prompts and pipeline architecture, not in any specific LLM. Agent specifications are markdown files. Skills are markdown files. Swap providers without rewriting logic.

---

## Key Files

| File | What it is |
|------|-----------|
| `CLAUDE.md` | The constitution — all rules for AI behavior in the vault |
| `AGENTS.md` | Quick-start guide for any AI agent operating in the vault |
| `Meta/Architecture.md` | System blueprint — runtimes, agents, workflows, review gates, execution layer |
| `Meta/Product-Spec.md` | The soul — intent behind every feature, ADHD audit scores, emotional design, delight moments |
| `Meta/Engineering.md` | Working agreement — TDD, macOS compatibility traps, shared libraries, CI rules |
| `Meta/scripts/SETUP.md` | Complete step-by-step recreation guide from zero |
| `Meta/Agents/*.md` | 12 agent specifications (scope, triggers, inputs, outputs, tone, constraints) |
| `Meta/scripts/` | 59 scripts — the plumbing (agent runners, voice pipeline, scheduling, git ops) |
| `.claude/skills/` | Just-in-time context rules loaded by agents at runtime (vault-writer, vault-extractor) |
| `agent-runtimes.conf` | LLM routing config — which provider runs which agent |
| `Makefile` | `make test`, `make lint`, `make check` — CI verification |

---

## macOS Compatibility Notes

Learned these the hard way:

- **No `\s` in sed.** BSD sed doesn't support it. Use `[[:space:]]` instead. This bug broke YAML parsing in 3 scripts (71 instances).
- **No `timeout` command.** Use `perl -e 'alarm N; exec @ARGV'` instead.
- **Whisper needs `--device mps`** explicitly for Apple Silicon GPU acceleration.
- **launchd needs a TCC-safe wrapper** in `~/bin/` for proper path resolution.
- **No backticks in double-quoted prompt strings** passed to Claude CLI.

---

## Privacy

Whisper runs locally — voice memos never leave your machine. The only external calls are to your LLM provider (Anthropic/OpenAI) for agent processing.

This repo ships with **mock content** (fictional people, actions, events) to show what the system produces. Your real data stays on your machine. If you fork and push your own vault: make sure to `.gitignore` or remove personal content before pushing.

---

## Status

This is an active personal project. I use it every day. It's not a product — it's a system I built because nothing else worked for my brain.

If you have ADHD and you've ever built the perfect Notion system only to abandon it two weeks later — I get it. This system is designed around the assumption that you *won't* maintain it. That's the whole point.

The `Meta/Product-Spec.md` file is probably the most useful thing in this repo even if you don't use any of the code. It's a detailed breakdown of ADHD-friendly design — what works, what doesn't, and why silence is the enemy.

---

## Contributing

Issues and PRs welcome. I'm learning as I go.

If you fork it and build something cool, I'd love to hear about it.

---

## License

MIT — use it, fork it, make it yours.

---

Built by [Usman Kotwal](https://github.com/uetzel) — an amateur with ADHD who got tired of forgetting everything.
