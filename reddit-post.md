# I built a personal OS for my ADHD brain — 12 AI agents that turn voice memos into structured knowledge, research, and execution. Sharing the repo.

Some of you asked me to share what I've been building. So here it is.

I have ADHD. My working memory is a leaky bucket. Every thought that isn't captured the moment it happens is gone. Every task that isn't surfaced at the right time doesn't exist. And every system that requires manual filing, tagging, or organizing? Abandoned within a week. You know the drill.

So I built a system where my only job is to **think out loud** and **say yes or no**.

## How it works

I send a voice memo via Telegram. That's it. That's the input.

The system transcribes it locally with Whisper on my Mac (nothing leaves my machine — Apple Silicon GPU, runs in seconds), then 12 AI agents take over. An Extractor pulls out every person, action, event, decision, and reflection. A Reviewer catches mistakes. An Implementer auto-fixes what other agents broke. Everything gets filed into an Obsidian vault with wikilinks connecting it all.

The next morning at 7:30 AM, I get a briefing on Telegram: what needs me, what's new, what just happened. When I'm ready to act, the system drafts the email or schedules the meeting and asks me to approve with one tap. I don't open Obsidian to file things. I don't tag anything. I don't organize. I talk. The system does the rest.

## What's actually running

12 agents, each with a specific job. ~16,500 lines of bash and Python. 59 scripts. Here's the lineup:

**Extractor** — pulls knowledge from every voice memo. People, events, actions, decisions, places, reflections. Checks aliases before creating duplicates. Updates existing entries.

**Reviewer** — QA pass after every extraction. Catches broken wikilinks, missing provenance, duplicate people. Fixes simple stuff, flags the rest.

**Implementer** — the self-healing agent. Reads what Retro and Reviewer found, auto-fixes safe issues, queues dangerous ones for my approval. The system maintains itself.

**Task-Enricher** — breaks vague actions into ADHD-friendly sub-steps. "Resolve contracts" becomes 6 concrete steps, three of which the system can do automatically. Flags actions that need research.

**Researcher** — spawns 3 perspective agents (e.g., customer-first, strategist, contrarian), synthesizes their findings, runs a verification pass, then scatters the results back into the vault. I get an article in Thinking/Research/ and enriched action notes.

**Advisor** — my strategic brain on Telegram. Knows my entire vault context — goals, beliefs, active actions, decision history. I text a question, it gives me an answer that's *for me*, not generic. Uses streaming so the response appears progressively, like a real conversation.

**Orchestrator** — the newest one. Takes a decomposed action and walks a DAG: automated steps run in parallel, user-facing steps come one at a time, research triggers when needed. State machine backed by JSON files.

Plus: **Thinker** (weekly pattern analysis), **Mirror** (behavioral coach), **Briefing** (morning digest), **Retrospective** (nightly vault health check), **Operator** (email/calendar execution with mandatory approval gates).

## The ADHD design decisions that actually matter

I wrote a whole product spec for this (`Meta/Product-Spec.md` in the repo — probably the most useful file if you're building something similar). But the core principles:

**Voice-first.** The gap between "I should write this down" and actually writing it is where 90% of my ideas die. Voice kills that gap. I send a memo while walking. My phone buzzes with a fire emoji. Later: "2 people updated, 1 action created." I never opened Obsidian.

**Feedback at every step.** The pipeline shows live progress in Telegram — same message gets edited as each stage completes. Transcribing... Extracting... Done. Silence is what makes the ADHD brain assume the system is broken. This one never goes silent.

**Approve, don't operate.** I'm good at "yes" or "no." I'm terrible at "draft the email, find the address, attach the file, send it." The system presents decisions, not to-do lists. "Approve this email to Lisa?" with a Go Ahead button. Two seconds.

**Self-healing.** Every night a Retrospective agent checks vault health. Every finding goes to the Implementer, who auto-fixes safe issues and queues dangerous ones for me. I don't maintain the system. The system maintains itself. I opened the vault after a week away once. Everything worked.

**Three review tiers, enforced by code.** Tier 1 (silent auto-fix): broken links, YAML errors. Tier 2 (fix and notify): new Canon entries, enrichment. Tier 3 (hard gate): emails, calendar events, money, anything that touches the real world. The Operator *never* fires without my explicit approval. That's the hardest rule and the most important one.

## The emotional arc

This is what I'm actually designing for:

```
CAPTURE:     "I just said something"           -> "It heard me"
PROCESSING:  (5 min pass)                      -> "It understood me"
SURFACING:   (next morning)                    -> "It remembered for me"
NUDGING:     (3 days later)                    -> "It won't let me forget"
EXECUTING:   (when I'm ready)                  -> "It did the work for me"
REFLECTING:  (weekly)                          -> "It sees patterns I missed"
```

Each step should produce a small dopamine hit. The system is a dopamine-positive feedback loop for productivity.

## What's still broken (being honest)

I'm an amateur. I'm not a developer by trade. This thing works for me, but it's duct tape in a lot of places.

- **Setup is hard.** You need CLI, Python, git, launchd, Whisper, a Telegram bot token, API keys. There's a detailed SETUP.md but it's not plug-and-play. You'll need to tinker.
- **macOS only.** Launchd for scheduling, Homebrew for dependencies, Apple Silicon for Whisper GPU. No Windows or Linux support yet.
- **40+ open actions = overwhelm.** The system doesn't yet know how to show me just THE ONE thing. That's the exact problem I'm building this to solve and I haven't cracked it.
- **No completion dopamine.** Marking something done has no celebration, no streak, no confetti. It should feel like something.
- **Stale actions become a wall of shame** instead of auto-dropping after 3 ignored nudges. Working on it.
- **No "I'm overwhelmed" mode.** Can't tell the system "pause everything for 2 hours." Need a `/pause` command.
- **Codex integration is paused.** Stdin pipe stalls under launchd on macOS. All agents run on Claude CLI for now.
- **The morning briefing is too long.** Should be 3 bullets, not a newspaper. ADHD brain doesn't read walls of text. I know this. Haven't fixed it yet.

## The tech

- **Obsidian** — the vault (markdown files + wikilinks + Dataview)
- **Whisper** (local, Apple Silicon) — transcription, private, free
- **Claude CLI + Anthropic API** — all 12 agents route through Claude right now
- **Python** — Telegram bot, orchestrator, MCP server, shared vault library
- **Bash** — 59 scripts for agent running, voice pipeline, scheduling, git automation
- **launchd** — macOS scheduling for 8 agent schedules
- **Telegram Bot API** — voice input, push notifications, approval buttons, Advisor chat
- **Git** — every change tracked, pre-commit guards

## What you get in the repo

It's a **ready-to-clone template** with mock content so you can see what the system actually produces before putting your own life into it:

- All 12 agent specifications
- 59 scripts — the full plumbing
- Architecture blueprint, product spec with ADHD design principles, engineering docs
- **Step-by-step setup guide** — written so you can follow along with Claude or ChatGPT helping you. You don't need to be a developer.
- **Mock vault content**: sample people, actions, events, reflections, a voice transcript, AI reflections — so you see what a running system looks like before you commit
- Configurable LLM routing (swap Claude for GPT or anything else)

The product spec (`Meta/Product-Spec.md`) is probably the most useful file even if you don't use any of the code. It's a love letter to ADHD-friendly system design — what works, what doesn't, and why silence is the enemy.

## Why I'm sharing this

Because when I was looking for something like this, it didn't exist. Every productivity system I found assumed I could maintain it. I can't. My brain doesn't work that way.

If you have ADHD and you've ever built the perfect Notion system only to abandon it two weeks later — this is for you. Not because this system is perfect, but because it's designed around the assumption that you *won't* maintain it. That's the whole point.

**Repo:** [https://github.com/uetzel/AutoADHD](https://github.com/uetzel/AutoADHD)

MIT licensed. Fork it, break it, make it yours.

---

*Built by Usman Kotwal on Obsidian + Whisper + Claude + Telegram + 59 shell scripts and one very stubborn ADHD brain. [LinkedIn](https://www.linkedin.com/in/usman-kotwal/) if you want to connect. AMA in the comments.*
