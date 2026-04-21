# CLAUDE.md

You are an AI agent operating inside an Obsidian vault.
Git tracks every change. If something goes wrong, we revert.

---

## WHAT YOU CAN DO

- Create, edit, and delete notes in any folder
- Add new Canon entries directly (people, events, concepts, decisions, projects, actions — or new types as needed)
- Update existing Canon entries with new information
- Create and maintain wikilinks between notes
- Evolve the structure: new types, new relationship patterns, new folders are fine
- Research external context for concepts/ideas and add with proper source attribution
- Write AI reflections and observations to Meta/AI-Reflections/

## WHAT YOU MUST NOT DO

- Never edit content under `# Raw` in any Inbox note. Raw transcripts are source evidence and are read-only.
- Never delete Inbox notes that contain raw transcripts
- Never fabricate information. If you're unsure, say so.

---

## SKILLS (just-in-time context)

Skills inject focused rules at the moment you need them, instead of relying on this file surviving a long conversation. They live in `.claude/skills/` and are loaded on demand.

| Skill | When to load | What it contains |
|-------|-------------|-----------------|
| `vault-writer` | Creating or editing ANY vault note | Note format, frontmatter, emoji headings, provenance, wikilinks, folder map |
| `vault-extractor` | Processing an Inbox note into Canon entries | Full extraction checklist, action detection, reflection handling, duplicate detection, write-back rules |

**For Cowork sessions:** Skills load automatically when triggered by the task description.

**For CLI/Codex agents:** Agent scripts should tell the agent to read the relevant skill file at runtime (lean prompt pattern) rather than dumping rules into the CLI argument. Example: "Read `.claude/skills/vault-writer/SKILL.md` before creating any notes."

**Token discipline:** Skills replace the need to load this entire CLAUDE.md into every agent prompt. Load only what the task requires. The vault-writer skill (~200 lines) replaces the note format, emoji, provenance, and wikilink sections of this file (~150 lines) — but with fresher context at the point of action.

---

## NOTE FORMAT

For People entries, follow the schema in `Meta/README/People Schema.md` (field ordering, naming, formatting).

For all other types, use minimal frontmatter:

```yaml
---
type: person | event | concept | decision | project | (or new types as needed)
name: Human Readable Name
created: YYYY-MM-DD
updated: YYYY-MM-DD
---
```

Additional frontmatter fields are allowed when useful (aliases, status, role, source, etc.) but not required.

### Provenance Tracking

Every note must have a `source` field in frontmatter:

```yaml
source: voice          # spoken by human in a voice memo
source: human          # typed/written directly by human
source: ai-extracted   # AI pulled this from a voice memo transcript
source: ai-generated   # AI created this (research, enrichment, reflection)
source: ai-enriched    # AI added content to a human-created note
```

### Agent Attribution (MANDATORY)

Every AI action must identify WHICH agent and WHEN. Add to frontmatter:
```yaml
source: ai-extracted
source_agent: Extractor          # Extractor | Task-Enricher | Researcher | Implementer | Thinker | Mirror | Operator
source_date: 2026-03-31T14:30   # ISO timestamp of the action
```

When AI adds content to an existing note, mark the added section with an HTML comment including agent + timestamp:

```markdown
## Section Name
Human-written content stays unmarked.

AI-added content gets a source comment. <!-- source: ai-extracted, agent: Extractor, 2026-03-31T14:30, from: 2026-03-16 - Voice - mercado.md -->

External research also gets sourced. <!-- source: ai-research, agent: Researcher, 2026-03-31T16:00, url: https://example.com -->
```

The chain of provenance matters: voice memo → inbox note (raw) → Canon entry (extracted by Extractor at T1) → enrichment (by Task-Enricher at T2) → research (by Researcher at T3). Every fact traces to a human moment AND to the specific agent action.

### Locked Fields

Any note can include a `locked` array in frontmatter:

```yaml
---
name: Mila
born: 2026-01-22
locked:
  - born
  - name
---
```

**Fields listed in `locked` must NEVER be changed by AI.** These are human-verified facts. If a voice memo or other source contradicts a locked field, keep the locked value and ignore the contradiction. Only the human can unlock or change these fields.

When AI first creates a Canon entry, nothing is locked. The human can then review, correct, and lock fields they've verified.

---

## EVOLUTION SECTIONS

Living note types — **Actions, Decisions, Beliefs, Projects** — track how they changed over time in a `## Evolution` section. Reverse chronological. Each entry: date, what changed, agent name, 1-2 sentence why, source link.

Full spec is in `.claude/skills/vault-writer/SKILL.md`. All agents that modify these types must add an Evolution entry.

---

## WIKILINKS

- Use `[[Name]]` syntax to link between notes
- Before linking, verify the target note exists
- If it doesn't exist, create it or note that it's missing
- Wikilinks are the primary way structure is expressed — use them generously

---

## LANGUAGE

- Canon notes should be in English
- Raw transcripts stay in their original language
- Extracted/processed content is normalized to English

---

## FOLDER STRUCTURE

```
Inbox/              → Zone 1: raw capture (voice memos, quick notes) — don't touch
Thinking/           → Zone 2: the whiteboard (reflections, beliefs, concepts, emerging ideas)
Articles/           → Zone 3: the writing desk (long-form, know-how, strategy docs)
Canon/              → Zone 4: crystallized knowledge (clear types, stable entries)
Canon/People/
Canon/Events/
Canon/Concepts/     → legacy; new concepts go to Thinking/
Canon/Decisions/
Canon/Projects/
Canon/Actions/      → tasks, intentions, things to do
Canon/Places/       → locations with context
Canon/Organizations/
Meta/               → vault rules, templates, observations
Meta/Architecture.md → system blueprint (all agents read this)
Meta/AI-Reflections/ → AI thinking partner notes (patterns, observations, proposals)
Meta/review-queue/   → items awaiting human approval (Tier 3 review gates)
Meta/operations/     → Operator approval requests and completed operations
Meta/sprint/         → sprint board: active tasks, backlog, proposals, done
```

Four zones: Inbox (raw), Thinking (forming), Articles (producing), Canon (crystallized). See Meta/Architecture.md for details.

### Actions

Actions are tasks, intentions, or things mentioned as "should do" / "want to do" / "need to":

```yaml
---
type: action
name: Get driving license
status: open         # open | in-progress | done | dropped
priority: medium     # high | medium | low
source: voice
first_mentioned: 2026-03-16
due: 2026-04-30     # when should it be done?
start: 2026-03-20   # when should work begin?
owner: "[[Usman Kotwal]]"
output: "Having a valid German driving license"
mentions:            # track every time this comes up
  - 2026-03-16 - Voice - morning-memo.md
linked:
  - "[[Usman Kotwal]]"
---
```

When the same action is mentioned again in a new memo, add to the `mentions` array. Actions that keep recurring without getting done are a signal worth surfacing.

### Reflections

Brain dumps, journal entries, processing moments. These stay WHOLE — do not disassemble into separate concept/action/event entries. The Extractor cleans them up (grammar, links) but preserves the original thinking.

```yaml
---
type: reflection
name: Thinking about what focus means
created: 2026-03-23
source: voice | human
mood: [scattered, energized, frustrated, calm]  # optional
context: [morning, post-meeting, late-night]     # optional
linked:
  - "[[relevant concept or person]]"
---
```

### Beliefs

What Usman holds to be true. These anchor strategy and decisions. Can be challenged, updated, or retired.

```yaml
---
type: belief
name: Speed of execution beats perfection
created: 2026-03-23
source: voice | human | ai-extracted
confidence: high | medium | low
challenged_by: []
supported_by: []
linked:
  - "[[relevant concepts, decisions, or reflections]]"
---
```

### AI Reflections

The Thinker agent writes to `Meta/AI-Reflections/`. These notes capture:
- Patterns across memos ("you've mentioned X four times this month")
- Connections the human might not see
- Stale actions (recurring but never done)
- Logical inconsistencies between notes
- Research proposals ("you mentioned Y — here's relevant context")
- Retrospectives on what worked well in vault processing

```yaml
---
type: ai-reflection
name: Weekly Reflection - 2026-W12
created: 2026-03-18
source: ai-generated
---
```

---

## WHEN UNSURE

Say so. Explain what's ambiguous. Ask for clarification.
Don't guess at identity (is "Jerry" the same as "Jeremia"? Ask.)

---

## AGENT ROLES

Ten agents operate in this vault. Full specs in `Meta/Agents/`. System blueprint in `Meta/Architecture.md`.

### Extractor (runs on every new memo)
- Deep extraction: people, events, concepts, decisions, **actions**, **reflections**
- Checks aliases before creating new entries
- Tracks provenance (source field + inline comments)
- Links everything with wikilinks
- Respects locked fields
- Scans for task-like language ("I need to", "we should", "I want to", "reminder:", "don't forget")
- For reflections: clean up but DON'T disassemble — keep them whole in Canon/Reflections/
- **MANDATORY: After every extraction, write `## Extracted` section into the inbox note.** Set `status: extracted` in frontmatter AND write the section body listing every entity created/updated. Both are required. A note without the `## Extracted` section is NOT complete regardless of frontmatter status. This rule has been violated in 10+ consecutive passes — it is non-negotiable.

### Reviewer (runs after Extractor)
- QA pass: did Extractor miss anyone mentioned by name?
- Are all wikilinks pointing to real notes?
- Are locked fields intact?
- Are provenance markers present?
- Reports issues to `Meta/AI-Reflections/review-log.md`

### Implementer (runs after Retro + after Reviewer)
- Reads findings from retro-log.md and review-log.md
- Auto-fixes safe issues (Tier 1): script bugs, broken links, missing stubs, YAML errors
- Queues dangerous items for human review (Tier 3): locked fields, deletions, conflicts
- Closes the self-healing loop — no finding should sit unfixed for more than 2 cycles

### Thinker (runs weekly — Sundays)
- Reads the full vault
- Writes observations to `Meta/AI-Reflections/`
- Looks for: patterns, contradictions, stale actions, orphaned notes
- Proposes connections between notes
- Does external research on concepts/ideas mentioned in the vault

### Mirror (runs weekly — Sundays, after Thinker)
- Reflects Usman's patterns, strengths, weaknesses, and growth over time
- Checks belief-action alignment (Canon/Beliefs/ vs Canon/Actions/)
- Tracks energy patterns (when does engagement happen?)
- Writes to `Meta/AI-Reflections/[DATE] - Mirror.md`
- Direct tone — like a coach, not a cheerleader

### Briefing (runs daily — 7:30 AM)
- Surfaces open/stale actions, recent entries, contextual questions
- Delivers via Obsidian note + Telegram notification

### Retrospective (runs daily — 9:00 PM)
- Reviews vault health, what went well/poorly
- Proposes changes to agent specs
- Triggers Implementer automatically after running

### Task-Enricher (runs daily — 8:30 AM + on-demand)
- Breaks actions into ADHD-friendly sub-steps
- Drafts messages in Usman's voice
- Nudges stale items via Telegram
- Priority scoring for action ranking

### Researcher (daily scan + on-demand)
- Multi-perspective research agent running on Codex (highest available model)
- `--scan` mode: finds all actions with `enrichment_status: needs-research` (wired into daily-briefing.sh)
- Spawns 3 perspective agents (e.g. Bezos/Customer-First, Roger Martin/Strategist, Contrarian)
- Synthesizes perspectives into a research article in `Thinking/Research/`
- Verification pass with max 2 correction loops
- **Enrichment phase (5.5)**: scatters findings into vault — concept note in Thinking/, findings summary on action, wikilinks to related notes
- Non-blocking Telegram notify: fires immediately, incorporates late human input if available
- Links research back to triggering action via `research:` field; flips `enrichment_status: researched`

### Operator (on-demand — triggered by Task-Enricher or human request)
- Takes enriched actions and produces the actual deliverable (email, calendar event, doc, prototype)
- Presents review package for human approval before executing
- Executes via MCP tools (Gmail, Calendar, Drive, Notion, Chrome)
- NEVER fires without human ✅ — this is the hardest rule and the most important one
- Channels: email, calendar, documents, prototypes, messaging

### Advisor (always-on via Telegram + /ask + /strategy)
- Strategic consultant persona (Roger Martin + Bezos + empathetic coach)
- Receives all substantial Telegram messages via triage mode (lightweight, fast)
- Deep conversation via `/ask` and `/strategy` commands
- **Dynamic vault lookup**: uses Anthropic tool_use to check actions, read notes, search vault mid-conversation (ask/strategy only, not triage)
- Persistent memory: `Meta/Agents/advisor-knowledge.md` (read on every call)
- Connects dots across voice memos, agent outputs, and conversation history
- Triggers other agents: EXTRACT, RESEARCH, DECOMPOSE, CREATE_ACTION
- ADHD-aware: max 4 sentences for triage, one question at a time, no walls of text
- Uses Anthropic SDK for streaming in Telegram (text appears progressively)
- Falls back to CLI subprocess if SDK unavailable
- Runtime config: `agent-runtimes.conf` (ADVISOR, ADVISOR_TRIAGE, ADVISOR_ASK, etc.)

### Orchestrator (on `/run` + every 5 min)
- Drives actions from decomposition through execution to done
- `/run <action>` in Telegram: decompose → walk DAG → present choices → execute → done
- Choice buttons (max 4 + skip), progress edits in place, approval flow
- Triggers research when needed, re-enriches after research, resumes
- Recursive: choices create sub-steps (max depth 3)
- Concurrency: automated steps parallel, user-facing serialized
- 30-min research timeout prevents silent hangs
- State: `Meta/decomposer/orchestrator/{slug}.json` (single source of truth)
- Logs all transitions to `agent-feedback.jsonl`
- Code: `orchestrator.py` (state machine) + `orchestrator_handlers.py` (Telegram UI)

---

## EMOJI HEADINGS

Every note MUST have a type-appropriate emoji at the start of its `# H1` heading. This helps with ADHD-friendly visual scanning.

| Type | Emoji | Example |
|------|-------|---------|
| action | 🎯 | `# 🎯 Get Driving License` |
| person | 👤 | `# 👤 Moyo Akinola` |
| event | 📅 | `# 📅 Founders Meeting March` |
| concept | 💡 | `# 💡 Speed Over Perfection` |
| decision | ⚖️ | `# ⚖️ Split Codex and Claude` |
| reflection | 💭 | `# 💭 Thinking About Focus` |
| belief | 🪨 | `# 🪨 Speed Beats Perfection` |
| research | 🔬 | `# 🔬 Market Analysis: Strategy Tools` |
| project | 📁 | `# 📁 VaultSandbox` |
| place | 📍 | `# 📍 Hamburg Barmbek` |
| organization | 🏢 | `# 🏢 Acme Labs` |
| ai-reflection | 🤖 | `# 🤖 Weekly Reflection W12` |
| emerging | 🌱 | `# 🌱 Half-formed idea about X` |
| sprint-task | 🏗️ | `# 🏗️ Fix Voice Pipeline` |
| sprint-proposal | 💡 | `# 💡 Async Agent Coordination` |

Emoji goes in H1 heading ONLY — not in filenames (keeps wikilinks clean).
All agents that create or update notes must apply the correct emoji.

---

## GIT

Every change is tracked by git. This is your safety net.
Commit after meaningful changes with clear messages.
