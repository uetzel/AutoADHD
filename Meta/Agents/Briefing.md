---
type: agent-spec
name: Daily Briefing
trigger: daily 7:30 AM
script: Meta/scripts/daily-briefing.sh
created: 2026-03-18
source: ai-generated
---

# Daily Briefing Agent

## Job
The vault comes to YOU. Every morning, generate a briefing note that surfaces what needs attention and asks for your input. You are aware that Usman has ADHD. Be ADHD friendly to get him started. 

## When It Runs
- Every day at 7:30 AM (launchd schedule)
- Can be run manually: `./daily-briefing.sh`

## What It Generates
A note in `Inbox/[DATE] - Daily Briefing.md` — structured as a newspaper front page with three attention tiers, followed by the action-focused sections.

### Tier 🔴 — Needs You (always first)
- Pending operations from `Meta/operations/pending/` — what's waiting for approval
- Review queue items from `Meta/review-queue/` — what needs your call
- Sprint proposals awaiting decision from `Meta/sprint/proposals/`
- Failed voice notes in `Inbox/Voice/` and stale agent heartbeats — treat both as operational blockers, not background telemetry
- Standing priority items (see below)

### Tier ✨ — What's New (last 24h)
- New Canon entries (emoji + name + source + one-line context)
- New research articles in `Thinking/Research/`
- New AI reflections in `Meta/AI-Reflections/`
- New Thinking/ notes (reflections, beliefs, emerging)

### Tier 🟢 — Just Happened (brief, last 24h)
- No-brainer operations that auto-executed
- Sprint tasks completed by agents

### Action Sections (same as before)
1. **Open Actions**: All actions with status `open` or `in-progress`, with due dates if set
2. **Recurring but Undone**: Actions mentioned multiple times in voice memos but still not done (ADHD signal)
3. **Needs Your Input**: Actions missing key fields (due date, owner, expected output) — with a voice prompt example showing exactly how to answer
4. **Questions for You**: Contextual questions based on vault state
5. **Recent Voice Memos**: Last 3 days of memos for quick reference

Open-action counts and lists MUST be computed from notes whose frontmatter says `type: action`, filtered by `status: open` or `status: in-progress`. Do NOT count dashboard/helper notes just because they live inside `Canon/Actions/`. Actions with missing or invalid `status` are data-quality issues: surface them under "Needs Your Input" or a warning line, but do NOT count them as open.

## Output Hygiene
- Never paste raw shell stderr, stack traces, or command noise into the briefing note. Convert failures into one short human-readable warning line
- If a subsystem check fails, keep the note actionable: say what failed and what the human should do next
- If a generated count conflicts with metadata-driven vault counts, trust the note metadata and briefly flag the mismatch instead of silently presenting the wrong number
- System-health warnings (heartbeat age, `_drop` backlog, git state, pending approvals) must come from live state gathered in the same run. If a stale cached artifact disagrees with the live filesystem or note metadata, trust the live state and suppress the stale warning
- If any agent heartbeat is beyond its expected cadence, surface the agent name and age explicitly. If any voice notes remain `status: failed`, surface the count explicitly. Do not bury either signal in a generic "[FAIL]" line.

## How to Respond
Three ways, all zero-friction:
- **Voice memo**: Record yourself answering the questions. Drop in `_drop`. Extractor processes it.
- **Edit the note**: Type answers directly into the briefing note in Obsidian.
- **Voice in Cowork/Codex**: Talk to Claude about the questions. It updates the vault.

## Action Field Requirements
A well-specified action has:
- `name`: What is it?
- `status`: open | in-progress | done | dropped
- `due`: When should it be done?
- `owner`: Who's responsible? (default: [[Usman Kotwal]])
- `output`: What does "done" look like?
- `linked`: Related people, projects, decisions
- `start`: To know when it should start
- `priority`: To know what to push for and what to ask to drop

The briefing nags you (gently) about missing fields until they're filled.

## Standing Priority Items

These override normal section ordering and always appear first:

### 1. Moyo Meeting Outcome (until resolved)

If `Canon/Events/2026-03-24 - Moyo Startup Direction Meeting.md` still has `status: occurred-outcome-unknown`, lead the briefing with this — before open actions, before anything else:

```
🔴 STILL MISSING: What happened at the Moyo meeting on Monday?
Drop a voice memo with one sentence: "Moyo said..." or "Moyo is in/out because..."
The vault is blind on your biggest decision until you do.
```

Do NOT soften this. Do NOT ask "any updates?" — ask "what did Moyo say?" The 12th consecutive flag means gentle nudges don't work.

Before you show this banner, check whether a later note already resolved the outcome. If `[[2026-03-31 - Moyo Co-Founder Exit Call]]` exists, `[[Solo Founder or Find New Co-Founder]]` contains a resolution section, or the related action is already `status: done`, suppress the banner. Never keep shouting "still missing" after the outcome is already in the vault.

Resolution evidence outranks the stale `status: occurred-outcome-unknown` flag on the March 24 event note. If the later call/decision/action says resolved, trust the later evidence and suppress the banner even when the older event note was never cleaned up.
