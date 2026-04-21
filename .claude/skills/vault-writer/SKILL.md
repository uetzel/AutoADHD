---
name: vault-writer
description: "Rules and formats for creating or editing notes in the Obsidian vault. MUST be used whenever creating a new Canon entry, Thinking note, reflection, belief, action, event, person, place, organization, decision, or any vault note. Also use when updating existing notes, adding wikilinks, or fixing frontmatter. Triggers on: 'create a note', 'add a person', 'new action', 'update entry', 'fix frontmatter', 'add wikilinks', vault note editing of any kind. If you're touching a .md file in Canon/, Thinking/, or Inbox/ — use this skill."
---

# Vault Writer

You're writing notes in an Obsidian vault that serves as a personal operating system. Every note follows specific rules so that AI agents (Extractor, Reviewer, Implementer) can process them reliably, and so the human can scan them visually with ADHD-friendly formatting.

This skill contains everything you need. Don't rely on remembering CLAUDE.md — the rules are right here.

---

## The Golden Rules

1. **Provenance is sacred.** Every fact traces to a human moment or explicit source. Add `source:` to frontmatter. Add `<!-- source: ... -->` comments on AI-added content.
2. **Locked fields are untouchable.** If frontmatter has a `locked:` array, those fields cannot be changed by AI. Period. If new info contradicts a locked field, keep the locked value.
3. **Wikilinks are structure.** Every mention of a known person, event, concept, action, decision = a wikilink. Before linking, verify the target exists. If it doesn't, create a stub or note it's missing.
4. **Never touch `# Raw` sections.** Raw transcripts in Inbox notes are source evidence. Read-only.
5. **Never fabricate.** If unsure, say so.

---

## Frontmatter Template

Every note needs at minimum:

```yaml
---
type: person | event | concept | decision | project | action | place | organization | reflection | belief | emerging | ai-reflection
name: Human Readable Name
created: YYYY-MM-DD
updated: YYYY-MM-DD
source: voice | human | ai-extracted | ai-generated | ai-enriched
---
```

Additional fields are welcome when useful (aliases, status, tags, linked, locked, etc.) but not required except for specific types below.

### Source Values
- `voice` — spoken by human in a voice memo
- `human` — typed/written directly by human
- `ai-extracted` — AI pulled from a voice memo transcript
- `ai-generated` — AI created (research, enrichment, reflection)
- `ai-enriched` — AI added content to a human-created note

### Agent Attribution (MANDATORY)

Every AI action must identify WHICH agent did it and WHEN. Generic "ai-generated" is not enough.

**In frontmatter** — add `source_agent` and `source_date`:
```yaml
source: ai-extracted
source_agent: Extractor
source_date: 2026-03-31T14:30
```

**In inline comments** — include agent name and timestamp:
```markdown
<!-- source: ai-extracted, agent: Extractor, 2026-03-31T14:30, from: 2026-03-16 - Voice - mercado.md -->
```

**In Evolution entries** — agent name is already part of the format:
```markdown
**2026-03-31 14:30** — Priority bumped to high · Task-Enricher
```

This lets the human trace: "Who changed this? When? Why?" If you're an agent writing to the vault, always sign your work.

---

## Emoji Headings (MANDATORY)

Every note gets a type-appropriate emoji at the start of its `# H1` heading. This is non-negotiable — it's how the ADHD brain scans Obsidian.

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

Emoji in H1 ONLY — never in filenames (keeps wikilinks clean).

---

## Type-Specific Schemas

### Person (`Canon/People/`)
Read `Meta/README/People Schema.md` for the full schema with field ordering. Key fields: `born`, `phone`, `email`, `city`, `employer`, `relationship`, `relationship_to`, `aliases`, `tags`, `linked`, `locked`.

### Action (`Canon/Actions/`)
```yaml
---
type: action
name: Get driving license
status: open           # open | in-progress | done | dropped
priority: medium       # high | medium | low
source: voice
first_mentioned: 2026-03-16
due: 2026-04-30
start: 2026-03-20
owner: "[[Usman Kotwal]]"
output: "Having a valid German driving license"
mentions:
  - 2026-03-16 - Voice - mercado.md
linked:
  - "[[Usman Kotwal]]"
---
```

Field rules:
- `mentions`: MUST be actual filenames, never placeholders like "multiple memos"
- `owner`: defaults to `"[[Usman Kotwal]]"` unless someone else is explicitly responsible
- `due`: use approximate dates rather than blank ("by summer" → `2026-09-01`)
- `output`: one-sentence "done looks like" — prefer concrete over blank

### Reflection (`Thinking/`)
```yaml
---
type: reflection
name: Thinking about what focus means
created: 2026-03-23
source: voice | human
mood: [scattered, energized, frustrated, calm]
context: [morning, post-meeting, late-night]
linked:
  - "[[relevant concept or person]]"
changelog:
  - 2026-03-23: created from voice memo [filename]
---
```

Reflections stay WHOLE. Clean up grammar, add wikilinks, but don't disassemble into separate entries.

### Belief (`Thinking/`)
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

### Event (`Canon/Events/`)
Include: what happened, when, who was there, where. Link to all participants and related decisions/actions.

### Place (`Canon/Places/`)
Include: what it is, why it matters, who's connected to it.

### Emerging (`Thinking/`)
For ideas that don't fit a box yet:
```yaml
---
type: emerging
name: Half-formed idea about X
created: YYYY-MM-DD
source: ai-extracted
linked: []
changelog:
  - YYYY-MM-DD: created from [source]
---
```

---

## Folder Map

| Type | Folder |
|------|--------|
| person | `Canon/People/` |
| event | `Canon/Events/` |
| action | `Canon/Actions/` |
| decision | `Canon/Decisions/` |
| project | `Canon/Projects/` |
| place | `Canon/Places/` |
| organization | `Canon/Organizations/` |
| reflection | `Thinking/` |
| belief | `Thinking/` |
| concept | `Thinking/` (new) or `Canon/Concepts/` (legacy) |
| emerging | `Thinking/` |
| research | `Thinking/Research/` |
| ai-reflection | `Meta/AI-Reflections/` |

---

## Provenance on AI-Added Content

When AI adds content to an existing note, mark it:

```markdown
## Section Name
Human-written content stays unmarked.

AI-added content gets tagged. <!-- source: ai-extracted, from: 2026-03-16 - Voice - mercado.md -->

External research gets sourced too. <!-- source: ai-research, url: https://example.com -->
```

---

## Wikilink Rules

1. Every mention of a known person, event, concept, action = a `[[wikilink]]`
2. For aliases: `[[Jeremia Riedel|Jerry]]`
3. Never wikilink inside `# Raw` sections or frontmatter values
4. If target doesn't exist → create a stub or flag it
5. Before creating any new entry, search existing notes + aliases to avoid duplicates

---

## Evolution Sections (Living Notes)

Note types that change over time — **Actions, Decisions, Beliefs, Projects** — get a `## Evolution` section in their body. NOT People, Places, Organizations (those are reference data, not narratives).

This replaces the old `changelog` frontmatter field. Evolution lives in the body because it needs room to breathe.

### Format

```markdown
## Evolution

**2026-03-27** — Priority bumped to high · Task-Enricher
Mentioned 3rd time in voice memos without progress. Sub-steps added. Promoted.
← [[2026-03-27 - Voice - driving.md]]

**2026-03-25** — Created · Extractor
First mention of wanting to get a driving license. Open, medium priority.
← [[2026-03-25 - Voice - mercado.md]]
```

### Rules

1. **Reverse chronological** — newest on top
2. **One entry per meaningful change** — not every typo fix, but status changes, priority shifts, new information, superseded content
3. **Format**: `**YYYY-MM-DD** — [what changed] · [agent or human]`
4. **Body**: 1-2 sentences explaining *why* (not just what). What was the trigger? What did it replace?
5. **Source link**: `← [[source file]]` on its own line — what triggered this change
6. **Agent or human**: who made the change. Use agent name (Extractor, Task-Enricher, Operator, Thinker, Mirror) or "human" for manual edits
7. **Superseded content**: if a belief was revised or a decision was reversed, note what the old state was

### Which agents write Evolution entries

| Agent | When to write |
|-------|-------------|
| Extractor | On creation (first entry) or when adding new mentions/info |
| Task-Enricher | When enriching an action (adding sub-steps, changing priority) |
| Operator | When executing (status → executed, adding results) |
| Researcher | When research changes the understanding of an action/decision |
| Thinker | When connecting to new patterns or challenging a belief |
| Mirror | When flagging belief-action misalignment |
| Human | Any manual edit (agents should not write entries for humans) |

### Migration

Old notes with `changelog:` in frontmatter: leave them. New changes go in `## Evolution`. Don't backfill — the old changelog entries are fine where they are.

---

## Language

- Canon notes: English
- Raw transcripts: stay in original language
- Extracted/processed content: normalized to English

---

## Review Queue (uncertain facts)

When you're not confident about a fact (date, age, spelling, relationship), flag it:

```bash
./Meta/scripts/queue-review.sh "Canon/People/[[Name]].md" "field" "value" "reason"
```

Flag: birth dates, ages, relationship labels, ambiguous names, amounts, garbled transcript bits.
Don't flag: obvious things, well-known facts, clearly stated info.

---

## Common Mistakes to Avoid

- Forgetting emoji in H1 heading
- Writing `mentions: "multiple memos"` instead of actual filenames
- Creating a new person without checking aliases first
- Editing content under `# Raw`
- Leaving `source:` blank in frontmatter
- Creating notes without wikilinks to related entries
- Putting new concepts in `Canon/Concepts/` instead of `Thinking/`
