---
type: architecture
name: VaultSandbox Product Specification
created: 2026-03-31
updated: 2026-04-03
source: ai-generated
source_agent: Implementer
source_date: 2026-03-31T11:30
---

# VaultSandbox — Product Specification

> This document captures **why** each piece exists, what feeling it should create, and how to rebuild the whole thing from scratch on any stack. Architecture.md tells you _what_. SETUP.md tells you _how_. This document tells you _why it matters_ and _what good looks like_.

---

## The Core Insight

People with ADHD have extraordinary pattern recognition, energy, and creativity — but their working memory is a leaky bucket. Every thought that isn't captured in the moment is gone. Every task that isn't surfaced at the right time doesn't exist. Every system that requires manual filing, tagging, or organizing is a system that will be abandoned within a week.

This system exists to be the working memory that the ADHD brain doesn't have. You talk, the system remembers. You forget, the system reminds. You avoid, the system nudges. You succeed, the system connects the dots you didn't see.

The human's only job: **think out loud** and **say yes or no**.

---

## Design Principles (with intent)

### 1. Voice-first, always

**Why:** Typing is a friction barrier. Voice is the lowest-energy way to externalize a thought. For ADHD, the gap between "I should write this down" and actually writing it is where 90% of ideas die.

**What it should feel like:** Talking to a trusted friend who has perfect memory. You ramble, they organize.

**Delight moment:** You mention someone's name once in a 3-minute voice memo, and 20 minutes later their Canon entry has been updated with what you said. You didn't ask. It just happened.

### 2. Zero-friction capture

**Why:** Every additional step between thought and capture is a dropout point. If capture requires opening an app, finding the right note, typing, and saving — you've lost 80% of ADHD users at step 2.

**What it should feel like:** Dropping a letter in a mailbox. You let go. It arrives.

**Delight moment:** You send a voice message while walking. Your phone buzzes with 🔥. Later you get "✅ Voice processed: 2 people updated, 1 new action created, 1 reflection saved." You never opened Obsidian.

### 3. The system works while you don't

**Why:** ADHD brains can't maintain systems. They can use systems that maintain themselves. The moment this system needs babysitting, it's dead.

**What it should feel like:** A garden that weeds itself. You plant seeds (voice memos), the garden grows.

**Delight moment:** The weekly Thinker says "You've mentioned 'strategy tool' in 4 memos this month but haven't created an action for it. Want me to?" — surfacing a pattern you didn't consciously notice.

### 4. Approve, don't operate

**Why:** ADHD brains are good at judgment calls ("yes/no/change this") and bad at execution sequences ("draft the email, find the address, attach the file, send it"). The system should present decisions, not to-do lists.

**What it should feel like:** Being a CEO who reviews and approves, not an assistant who does the legwork.

**Delight moment:** "⚡ Approve this action? → Email Lisa about the meeting. Draft ready. [Go ahead] [Don't do this] [Change...]" — you tap one button.

### 5. Feedback at every step, not silence

**Why:** If you drop something into a system and hear nothing back, your ADHD brain assumes it's broken. Silence = anxiety. Feedback = trust. This is not optional — it is the single most important design principle for ADHD. Every action by the human or the system MUST have visible progress.

**What it should feel like:** A restaurant where the waiter confirms your order, tells you it's being prepared, and brings it to the table — not one where your food appears 40 minutes later with no communication.

**The Feedback Protocol (emoji lifecycle):**

| Stage | Emoji | Meaning | Example |
|-------|-------|---------|---------|
| Received | 👀 | "I see your message" | Instant, on any input |
| Saved | 👌 | "Filed, waiting for agent" | Your answer to a review item |
| Working | ⚡ | "Agent is on it" | Decomposer running, advisor thinking |
| Done | 👍 | "Finished, here's what changed" | + summary of what changed and where |
| Failed | 👎 | "Something broke" | + reason and what to do |

**Rules:**
- No save without a reaction. If something was saved, the user sees 👌.
- No agent run without a notification on start AND finish. "Working..." is not enough — "Done: updated Rose of Sharon, queued GmbH structure for review" is.
- Completion notifications include WHAT changed and WHERE to look. Not "3 files fixed" — "Updated Lisa's email, fixed Rose of Sharon wikilink, queued tax structure for your review."
- Button clicks preserve the full original context. The ADHD brain forgets what it approved 3 seconds after tapping.

**Delight moment:** You answer a review question ("Rose von Sharon"). Your message gets 👌 instantly. An hour later: "🔧 Implementer done — updated Canon/Organizations/Rose von Sharon, fixed 2 wikilinks. Check in Obsidian." You never opened anything.

---

## ADHD Friendliness Audit

Rating: **8/10** — Strong foundation with strategic brain and auto-execution. Remaining gap: overwhelm mode (/pause, /focus) not yet built.

### What's working (the good stuff)

| Feature | ADHD Score | Why |
|---------|-----------|-----|
| Voice capture via Telegram | 9/10 | Literally one button press. Can't get lower friction. |
| 🔥 instant reaction on voice | 9/10 | Immediate feedback loop. Brain knows "it worked." |
| Pipeline progress notifications | 8/10 | 📝→🔍→✅ trail prevents the "did it work?" anxiety. |
| Morning briefing push | 8/10 | Information comes to you, not the other way around. |
| Review as approve/reject buttons | 8/10 | Binary decisions, not open-ended tasks. |
| Git safety net | 7/10 | Removes fear of breaking things. Enables experimentation. |
| Emoji headings in notes | 7/10 | Visual scanning is 3x faster than reading text for ADHD. |
| Natural language routing | 9/10 | No slash commands to remember. Text like you're texting a friend. |
| Advisor (strategic brain) | 8/10 | Context-aware answers without explaining backstory. 30s can feel slow. |
| Action decomposition | 9/10 | Kills "where do I start?" paralysis. One question at a time. |
| Auto-execution engine | 8/10 | Progress happens while you forget. Only interrupts for real decisions. |

### What needs work (be honest)

| Gap | ADHD Score | Problem | Fix |
|-----|-----------|---------|-----|
| 40 open actions | 3/10 | Overwhelm. ADHD brain sees 40 items and shuts down. | `/next` should show THE ONE thing. Hide the rest. |
| No completion dopamine | 4/10 | Marking something done has no celebration. | 🎉 reaction + streak counter + "3 done this week!" |
| Stale actions pile up | 4/10 | Things you keep avoiding become a wall of shame. | Auto-drop after 3 nudges with no response. Surface as "dropped — want to revive?" |
| Briefing is text-heavy | 5/10 | Morning briefing has good content but too many words. | Ruthlessly compress. 3 bullets max. Details behind commands. |
| No quick-win surfacing | 4/10 | System doesn't distinguish 2-min tasks from 2-hour tasks. | Tag actions with effort estimate. Surface quick wins when energy is low. |
| Review queue goes stale | 5/10 | Items sit in queue because Telegram notification was missed. | Escalating nudges: 1st quiet, 2nd bold, 3rd "I'm deciding for you in 24h." |
| No "I'm overwhelmed" mode | 3/10 | No way to tell the system "everything is too much right now." | `/pause` — mutes all nudges for N hours. `/focus X` — hides everything except X. |
| Setup requires technical skill | 2/10 | Current setup needs CLI, Python, launchd, git. | Installer script (see below). |

### The emotional arc we're designing for

```
CAPTURE:     "I just said something"           → 🔥 "It heard me"
PROCESSING:  (5 min pass)                      → ✅ "It understood me"
SURFACING:   (next morning)                    → 📋 "It remembered for me"
NUDGING:     (3 days later)                    → 🎯 "It won't let me forget"
EXECUTING:   (when I'm ready)                  → ⚡ "It did the work for me"
REFLECTING:  (weekly)                          → 🤖 "It sees patterns I missed"
```

Each step should produce a small dopamine hit. The system is a dopamine-positive feedback loop for productivity.

---

## Workflow Steps (complete pipeline)

### Workflow 1: Voice Capture → Knowledge

The core loop. Everything else is built on top of this.

#### Step 1: Voice Input

**What happens:** User sends voice message via Telegram (or iPhone Shortcut drops .m4a into _drop folder).

**Intent:** Capture the thought before it evaporates. The user should feel ZERO resistance.

**User feels:** "I can just talk. That's it."

**Technical:** `vault-bot.py` → downloads .ogg → saves to `Inbox/Voice/_drop/` → 🔥 reaction.

**Delight:** The 🔥 appears in under 1 second. No loading spinner, no "processing..." text. Just fire. You spoke, the system caught it.

**Failure mode:** If the bot is down, voice message sits unread. Fix: heartbeat detects bot down within 26 hours.

#### Step 2: Transcription

**What happens:** `watch-voice-drop.sh` (launchd) detects new file → `process-voice-memo.sh` runs Whisper locally.

**Intent:** Convert ephemeral audio into durable text. Locally, privately, free.

**User feels:** Nothing yet — this is invisible. But the 📝 notification tells them "your words are now text."

**Technical:** Whisper medium model, German language default. Creates markdown note in `Inbox/Voice/` with `## Raw` section (read-only). Sends Telegram: "📝 Voice transcribed (247 words)..."

**Delight:** The notification includes word count. Small detail, but it signals "I actually processed your content, not just filed it."

**Failure mode:** Whisper crashes on long audio. Fix: retry-failed.sh re-runs extraction on `status: failed` notes.

#### Step 3: Extraction

**What happens:** Extractor agent reads the transcript, creates/updates Canon entries (People, Events, Actions, Concepts, Decisions, Reflections, Beliefs).

**Intent:** This is the magic. The user rambled for 3 minutes; the system produced structured knowledge. Like having a personal researcher who listened to your meeting and wrote up the notes.

**User feels:** "It understood what I was actually saying, not just the words."

**Technical:** Claude/Codex reads the transcript + vault context. Creates new entries with wikilinks. Updates existing entries (checks aliases, locked fields). Writes `## Extracted` section into the inbox note listing everything it found.

**Delight:** You mentioned "Moyo" and the system linked it to `[[Moyo Akinola]]`, updated his Canon entry with the new context, and created an action for the thing you said you'd do together. All from a casual mention.

**Telegram:** "🔍 Extracting from: tg_2026-03-31_103012"

**Failure mode:** Extractor creates duplicates (e.g., "Jerry" vs "Jeremia"). Fix: Reviewer catches these. Also: aliases in frontmatter.

#### Step 4: Review (conditional)

**What happens:** Reviewer agent does QA — checks wikilinks point to real notes, locked fields are intact, provenance markers are present, no missed people. **Skipped entirely when the Extractor made 0 Canon changes** (trivial memos, test recordings).

**Intent:** Quality gate. The extraction is good but not perfect. Review catches the 10% of errors before they compound. But running a full AI QA call on a 5-word test memo is wasteful — so we skip it when there's nothing to review.

**User feels:** Nothing directly — this is invisible QA. But the absence of broken links and duplicate entries is felt as "this system just works."

**Technical:** `run-reviewer.sh` → writes findings to `Meta/AI-Reflections/review-log.md` → auto-triggers Implementer for Tier 1 fixes. In voice-pipeline mode, reviews only the specific new note (not 10 recent notes).

**Failure mode:** Reviewer misses a duplicate. Fix: Thinker (weekly) does a deeper pass.

#### Step 5: Progress Tracking + Notification

**What happens:** Pipeline stages update a progress JSON file (`Meta/.voice-progress/<slug>.json`). The Telegram bot polls every 10s and edits the status message in real-time: received → transcribing → extracting → reviewing → complete/failed.

**Intent:** Close the feedback loop at every stage. You dropped a voice memo — you see LIVE progress, not silence followed by a summary 5 minutes later. This is critical for ADHD trust: "something is happening."

**User feels:** "I can see it working. The system is alive."

**Technical:** `update-voice-progress.sh` writes JSON with stage, timestamp, and details. `vault-bot.py` polls `Meta/.voice-progress/` and edits Telegram messages. On completion, a final summary shows what was extracted. On failure, the error includes which step failed (e.g. "extractor failed (exit 1)").

**Delight:** The progress message updates from "Transcribing (15s)..." to "Extracting..." to "✅ Done: 2 people updated, 1 action created" — all in the same message. You watched it happen.

---

### Workflow 2: Morning Briefing

**Intent:** Replace "what should I do today?" anxiety with a clear, short, opinionated summary. The system tells you what matters, so your brain doesn't have to scan 40 items and freeze.

**User feels:** "I woke up and my day is already organized."

**Steps:**

1. **7:30 AM** — `daily-briefing.sh` runs
2. Reads: open actions, recent Canon entries, review queue, sprint status, heartbeat
3. Formats as 3-tier newspaper: 🔴 Needs You → ✨ What's New → 🟢 Just Happened
4. Pushes to Telegram + writes to Obsidian

**Delight:** The briefing arrives like a morning newspaper. You don't open it — it comes to you. The 🔴 section is never more than 3 items.

**ADHD score: 7/10.** Could be better: should auto-hide low-priority items and highlight quick wins.

---

### Workflow 3: Review & Approval

**Intent:** The system needs human judgment on some things. But asking "please review this" is too vague for an ADHD brain. Instead: frame every review item as a specific decision with clear options.

**User feels:** "I know exactly what you're asking and exactly how to respond."

**Steps:**

1. Agent queues item in `Meta/review-queue/`
2. `vault-bot.py` detects new item → pushes to Telegram with decision framing
3. 4 item types, each with specific buttons:
   - **Fact-check:** "❓ Is this right?" → [Looks right] [I'll correct it] [Later]
   - **Human-input:** "🎤 Only you know this" → [Type answer] [Voice answer] [Already handled]
   - **Approval:** "⚡ Approve?" → [Go ahead] [Don't do this] [Yes but change...] [Later]
   - **Generic:** "📋 Review needed" → [Got it] [Reply] [Later]
4. User taps button → review item resolved → Implementer picks up on next cycle

**Delight:** You never have to parse what the system wants from you. "Approve this email draft to Lisa" + [Go ahead] button. Two seconds.

**ADHD score: 8/10.** The clear framing is good. Gap: if you tap "Later," the item should re-surface, not disappear into the queue.

---

### Workflow 4: Self-Healing Loop

**Intent:** The system finds its own bugs and fixes them. No human intervention needed for 90% of issues.

**User feels:** "I never have to maintain this. It maintains itself."

**Steps:**

1. **9:00 PM** — Retrospective runs, audits vault health, writes findings
2. Implementer reads findings, classifies:
   - **Tier 1 (auto-fix):** broken wikilinks, missing stubs, YAML errors → fix silently
   - **Tier 2 (fix + notify):** missing fields, stale data → fix and tell the user
   - **Tier 3 (queue for human):** locked field conflicts, deletions, ambiguous merges → review queue
3. Heartbeat monitors agent health → surfaces "❌ Extractor hasn't run in 48h" in briefing

**Delight:** You open the vault after a week away. Everything works. Notes are linked. Actions are current. You didn't do anything.

**ADHD score: 9/10.** Self-maintenance is the ultimate ADHD feature. You shouldn't need to know this exists.

---

### Workflow 5: Weekly Reflection (Thinker + Mirror)

**Intent:** Surface patterns the human can't see because they're inside the day-to-day. Like having a therapist who read your journal and connects the dots.

**User feels:** "I didn't realize I was doing that. That's actually a useful insight."

**Steps:**

1. **Sunday** — Thinker reads the full vault, writes to `Meta/AI-Reflections/`
2. Looks for: recurring themes, stale actions, orphaned notes, contradictions between beliefs and actions
3. Mirror agent writes a direct, coach-like reflection: energy patterns, growth, blind spots
4. Surfaces in next morning briefing

**Delight:** "You've said 'I need to focus' in 6 memos this month, but your actions show you're starting new things every week. The pattern isn't lack of focus — it's that you haven't decided what to say no to."

**ADHD score: 8/10.** The insight is powerful. Gap: should be shorter. A long reflection note won't get read. Lead with one sentence, hide the rest.

---

### Workflow 6: Execution (Operator)

**Intent:** The system doesn't just remind you to do things — it does them for you, with your approval.

**User feels:** "I approved it. It happened. I didn't have to open Gmail."

**Steps:**

1. Task-Enricher identifies an action that needs execution (email, calendar event, document)
2. Operator drafts the deliverable
3. Writes approval request to `Meta/operations/pending/`
4. User approves via Telegram
5. Operator executes via MCP (Gmail, Calendar, etc.)

**Delight:** You said "email Lisa about the meeting" in a voice memo Tuesday. Wednesday morning your briefing shows "⚡ Draft email to Lisa — ready to send. [Go ahead]." You tap. It's sent.

**ADHD score: 7/10.** The flow is right but not yet battle-tested. Gap: needs the no-brainer fast path (skip approval for low-risk ops).

### Workflow 7: Advisor (Strategic Brain)

**Intent:** Have a smart friend who knows your entire context, available 24/7, who gives you strategic advice without you having to explain backstory.

**User feels:** "I texted a question. It already knew about my freelance pipeline, my upcoming meetings, my financial goals. The answer was *for me*."

**Steps:**

1. User asks a question in natural language ("Should I go to that AI meetup?")
2. Bot detects it's a question, routes to Advisor agent
3. Advisor loads vault context (beliefs, goals, active actions, decisions history)
4. Returns strategic answer + optional triggers (research, new action, decision log entry)
5. Session stays open for 30 min for follow-up conversation
6. Key decisions auto-logged to decisions-log.md

**Delight:** You ask "Should I take the Hamburg contract?" and the advisor knows your income goals, your existing pipeline, the person's history in your Canon, and your upcoming travel. It doesn't just answer — it shows you the trade-off you didn't see.

**ADHD score: 8/10.** No setup, no context-switching, just text a question. Gap: can be slow (30s for complex questions).

### Workflow 8: Action Decomposition + Auto-Execution

**Intent:** Turn a vague "Call Waqas about the GmbH" into a concrete step-by-step plan, then execute what can be automated and ask you only the questions that need your brain.

**User feels:** "I said 'break down the contract stuff' and it showed me 6 steps. Three happened automatically. It asked me one question. The rest is waiting for my answer."

**Steps:**

1. User says "break down [action]" or /decompose
2. System reads the action + all wikilinked context (people, projects, decisions)
3. AI decomposes into typed sub-steps: automated (AI does it), approval (creates op), input (asks you), manual (reminds you)
4. Sub-steps stored as separate files with DAG dependencies (depends_on frontmatter)
5. Execution engine runs every 15 min:
   - Finds steps whose dependencies are done
   - Auto-executes automated steps (3 per cycle, 5-min timeout)
   - Sends one input question at a time (no overwhelm)
   - Creates approval operations for human-gated steps
6. /steps shows visual progress: ✅ done, 🔄 running, ❓ waiting, ⏳ blocked

**Delight:** You decompose "Resolve Contracts" on Monday morning. By Monday evening, the system has researched the legal requirements, drafted the initial email, and is asking you one question: "Do you want the GmbH or UG structure?" You answer. The next step starts automatically.

**ADHD score: 9/10.** Peak ADHD design — removes the "where do I even start?" paralysis. One question at a time. Progress happens while you forget about it.

---

## Plug-and-Play Setup Vision

### The Goal

A person with ADHD, zero technical skill, sits down at a computer. 10 minutes later, they have a working system. They never see a terminal.

### What "Plug and Play" Means

```
1. Download the app               (30 seconds)
2. Sign in with Telegram           (20 seconds)
3. Choose your LLM provider        (API key paste — 30 seconds)
4. "Send me a test voice message"  (the app does the rest)
5. You're live                     (total: ~2 minutes)
```

### Architecture for Plug-and-Play

The current system is duct tape and shell scripts — powerful, but requires a developer to set up. To make it one-click:

#### Layer 1: The Installer (near-term, achievable now)

A single `setup.sh` that does everything:

```bash
curl -sL https://vault.example.com/install.sh | bash
```

What it does:
1. Checks prerequisites (Python 3, git, brew). Installs missing ones.
2. Creates vault folder structure
3. Installs Python dependencies (whisper, telegram-bot)
4. Installs ffmpeg via brew
5. Prompts for Telegram bot token (with step-by-step BotFather instructions)
6. Prompts for LLM API key (Claude or Codex)
7. Copies all scripts, sets permissions
8. Installs launchd agents
9. Installs git pre-commit hook
10. Sends test message via Telegram: "🎉 VaultSandbox is alive!"
11. Guides first voice memo: "Send me a voice message to test the pipeline"

**Estimated effort:** One solid afternoon of scripting.

**Limitation:** macOS only. Requires Homebrew. Requires terminal for the initial curl.

#### Layer 2: The Desktop App (medium-term)

Wrap the whole thing in an Electron/Tauri app:

- Menubar icon showing system health (green/yellow/red)
- Settings panel for Telegram token, LLM API key, vault location
- One-click start/stop for all agents
- Log viewer for debugging
- Auto-update for scripts

**Why Tauri over Electron:** Smaller binary, native performance, Rust backend can manage launchd agents directly.

**Limitation:** Significant engineering effort. But makes the system accessible to non-developers.

#### Layer 3: The Platform (long-term vision)

No local install at all:

- Cloud-hosted Whisper (or use cloud STT)
- Cloud-hosted agents (serverless functions)
- Telegram bot hosted centrally
- Vault synced via Obsidian Sync or git
- User just installs Obsidian + connects Telegram

**Trade-off:** Privacy. Local Whisper means your voice memos never leave your machine. Cloud means trusting a provider. For some users that's fine; for others it's a dealbreaker.

### Making It LLM-Agnostic

The system currently uses Claude CLI and Codex. To make it provider-independent:

1. **Abstract the LLM call.** `invoke-agent.sh` already routes agents to different runtimes. Extend this to support any provider: OpenAI API, Anthropic API, local Ollama, Google Gemini.

2. **Standard prompt format.** Agent prompts are already in markdown files (Meta/Agents/*.md). Any LLM that can read a system prompt and follow instructions works.

3. **Skill files are portable.** `.claude/skills/` contains the rules. These are just markdown. Any LLM can read them.

4. **The hard part is tool use.** Claude CLI has bash access. Other LLMs may need a wrapper that provides tool calling (file read/write, git, web search). This is the main portability barrier.

**Config file vision:**

```yaml
# vault-config.yml
llm:
  provider: anthropic          # anthropic | openai | ollama | google
  model: claude-sonnet-4-6     # any model string
  api_key_env: ANTHROPIC_API_KEY

transcription:
  provider: local-whisper       # local-whisper | openai-whisper | google-stt | deepgram
  model: medium
  language: de

messaging:
  provider: telegram            # telegram | signal | whatsapp | slack
  token_env: TELEGRAM_BOT_TOKEN

vault:
  path: ~/VaultSandbox
  sync: git                     # git | obsidian-sync | icloud
```

**What this enables:** Someone using GPT-4 + Signal + Google STT gets the same workflows. The soul of the system is in the prompts and the pipeline architecture, not in the specific tools.

---

## How to Rebuild This With Another LLM

If you're an AI reading this document: here's what matters.

### The non-negotiable patterns

1. **Capture must be instant.** Whatever the input method, the user must get acknowledgment within 1 second. No loading screens, no "please wait."

2. **Processing must be invisible.** The user doesn't care about your pipeline. They care about results. Notify at the start (🔥) and end (✅). Nothing in between unless it takes more than 5 minutes.

3. **Surfacing must be opinionated.** Don't show the user everything. Show them THE thing. One action, not forty. One insight, not a report.

4. **Approval must be binary.** "Yes" or "No." Not "please review this 500-word document and provide feedback." If you need nuance, offer "Yes but change..." as a third option.

5. **Self-healing is mandatory.** If an agent fails, another agent must notice and fix it. If a lock gets stuck, it must auto-expire. Silence is the enemy.

6. **Provenance is sacred.** Every piece of AI-generated content must say which agent created it and when. The human must be able to trace any fact back to the moment it was captured.

### The files that carry the soul

| File | What it contains | Why it matters |
|------|-----------------|---------------|
| `CLAUDE.md` | All rules for AI behavior in this vault | The constitution |
| `Meta/Architecture.md` | System blueprint: runtimes, agents, phases | The nervous system |
| `Meta/Product-Spec.md` | This file: intent, delight, ADHD audit | The soul |
| `.claude/skills/vault-writer/SKILL.md` | How to write notes correctly | The grammar |
| `.claude/skills/vault-extractor/SKILL.md` | How to extract knowledge from raw text | The comprehension |
| `Meta/Agents/*.md` | Each agent's specific mandate | The job descriptions |
| `Meta/scripts/SETUP.md` | Step-by-step recreation guide | The construction manual |

### The emotional design checklist

For every new feature, ask:

- [ ] Does this reduce friction or add it?
- [ ] Does the user get feedback within 1 second?
- [ ] Can the user respond with one tap?
- [ ] Does this work if the user ignores it for a week?
- [ ] Would someone with ADHD actually use this, or just intend to?
- [ ] Does this create a small dopamine hit?
- [ ] Does this fail gracefully and visibly?

---

## Version History

| Date | What changed | Why |
|------|-------------|-----|
| 2026-03-31 | Initial product spec | Capture the soul of the system for reproducibility |
| 2026-04-01 | Add Advisor, Decomposer, Execution Engine, natural language routing | Strategic brain + action breakdown + auto-execution. ADHD score 7→8/10. |
| 2026-04-03 | Voice pipeline reliability: progress tracking, conditional reviewer, step-level errors, note archival | Pipeline now shows live progress in Telegram, skips reviewer on trivial memos, reports which step failed. Vault moved to ~/VaultSandbox. |
