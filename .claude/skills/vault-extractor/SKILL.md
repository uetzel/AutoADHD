---
name: vault-extractor
description: "Full extraction rulebook for processing Inbox notes into Canon entries. MUST be used when: processing a voice memo transcript, extracting knowledge from an inbox note, running extraction on a new note, doing a manual extraction pass, or any task that involves reading an Inbox/ note and creating/updating Canon entries from it. Also use when the user says 'extract this', 'process this memo', 'what's in this transcript', or anything about pulling structured knowledge from unstructured text in the vault."
---

# Vault Extractor

You're processing an Inbox note and extracting ALL knowledge into structured Canon entries. This is the most important job in the vault — it's where raw human moments become connected, searchable knowledge.

Read the vault-writer skill too if you need note format details. This skill focuses on the extraction *process*.

---

## Before You Start

1. Read `CLAUDE.md` at vault root (if not already loaded)
2. Read the vault-writer skill for note formats (frontmatter, emoji headings, provenance)
3. Have the target Inbox note open and read every sentence of the `# Raw` section

---

## The Extraction Checklist

For every Inbox note, extract ALL of these:

### 1. People
Anyone mentioned by name. Before creating a new person:
- Search `Canon/People/` for the name
- Check ALL `aliases` arrays in existing people entries
- If found → update the existing entry (add new info, add to changelog)
- If new → create in `Canon/People/` following People Schema (`Meta/README/People Schema.md`)

### 2. Events
Anything that happened — meetings, conversations, trips, milestones. Include dates, participants, locations.
- Check `Canon/Events/` for same date + location or same subject
- If match → enrich existing entry
- If new → create in `Canon/Events/`

### 3. Actions (Tasks)
Scan for task-like language:
- "I need to...", "we should...", "I want to...", "let's..."
- "don't forget...", "reminder:...", "todo:..."
- "I have to...", "we must...", "plan to..."
- German: "ich muss...", "wir sollten...", "ich will..."

For each action:
- Check `Canon/Actions/` for existing match
- If exists → add new mention to `mentions` array
- If new → create in `Canon/Actions/`

**Action field rules (enforce every time):**
- `mentions`: MUST be array of actual filenames (e.g. `2026-03-16 - Voice - mercado.md`). NEVER write `"multiple memos"` or placeholders.
- `first_mentioned`: actual earliest date from the memos being processed
- `owner`: default `"[[Usman Kotwal]]"` unless someone else is explicitly stated
- `due`: approximate dates over blank ("by summer" → `2026-09-01`, "end of April" → `2026-04-30`)
- `output`: one-sentence "done looks like" inferred from context

### 3b. Enrichment Commands (CRITICAL — don't treat as passive actions)

The human often says things like "look up address for Lisa", "add her email", "find website for Rose von Sharon", "get phone number for Carlos". These are NOT actions to put on a todo list — they are **commands to the system**. The human expects an agent to DO the lookup, not remind them to do it manually.

**Detection patterns:**
- "look up...", "find...", "add [field] for...", "get [field] for..."
- "what's the address of...", "search for...", "enrich..."
- German: "such mal...", "finde...", "füge hinzu...", "was ist die Adresse von..."
- Implicit: "I need her phone number" (= look it up and add it)

**What to do when you detect one:**

1. Create or update the Canon entry with what you DO know
2. On the fields that need lookup, write a placeholder:
   ```yaml
   website: "ENRICH: look up official website"
   phone: "ENRICH: find public phone number"
   address: "ENRICH: look up business address"
   ```
3. Set `enrichment_status: needs-enrichment` in the note's frontmatter
4. Add an inline comment explaining the command:
   ```markdown
   <!-- enrichment-command: "look up address for Rose von Sharon", from: 2026-03-27 - Voice - tg2026-03-27194301.md, agent: Extractor, 2026-03-31T14:30 -->
   ```

The Task-Enricher scans for `enrichment_status: needs-enrichment` and `ENRICH:` placeholders, then does the actual lookup (web search, contacts, etc.) and fills in the real values.

**The key insight:** "Add address for XYZ" means the SYSTEM should find it, not the human. The human is delegating, not requesting a reminder.

### 4. Concepts
Ideas, frameworks, observations, philosophies mentioned.
- New concepts go to `Thinking/` (not `Canon/Concepts/` — that's legacy)
- Check for duplicates first

### 5. Decisions
Choices made or being considered. Include what was decided, why, what was traded off.
- Create in `Canon/Decisions/`

### 6. Places
Locations mentioned with context (cities, buildings, neighborhoods, addresses).
- Check for partial name matches (e.g. "Konservatorium" matches "HHKon Hamburger Konservatorium")
- Create in `Canon/Places/` or update existing

### 7. Reflections (special handling — see below)

---

## Reflection Detection

Some notes are brain dumps — personal reflections, journal entries, processing moments. Detect by:
- Extended first-person monologue without clear action items
- Emotional processing ("I've been thinking about...", "what bothers me is...")
- Stream of consciousness touching multiple topics
- Mood language (frustration, excitement, confusion, calm)
- German emotional passages (Usman switches to German for feelings)

**When you detect a reflection, do BOTH:**

### A. Keep the whole thing
Create a note in `Thinking/` with `type: reflection`. Clean up grammar and structure. Preserve voice. Add wikilinks. Tag mood and context. Do NOT disassemble.

### B. Extract entities as usual
Still pull out people, events, actions, concepts into their proper Canon homes. The reflection is the original painting; Canon entries are prints in different rooms.

---

## Affect Signals

Tag emotional tone when clearly present:
- Laughter, excitement → `affect: joy` or `affect: excitement`
- Frustration, repeated returns to a topic → `affect: frustration`
- Vulnerability, softness → `affect: reflection`
- Urgency, speed → `affect: anxiety`

Add as frontmatter on the inbox note. Only when obvious.

---

## Duplicate Detection (critical)

Before creating ANY new entry:
1. Search target folder for the plain-language name
2. Check ALL `aliases` arrays in existing entries
3. For Places: search partial name matches
4. For Events: check same date + location, or same subject matter
5. If match found → update existing, add new name variant to `aliases` if not there
6. NEVER create a duplicate

---

## Linking Rules

After extraction, ensure these links exist:
- Every Person → related Events, Decisions, Actions
- Every Event → People involved, Concepts discussed
- Every Action → Person responsible, related Decisions/Concepts
- Every Concept → People who discussed it, Events where it arose
- Use `[[wikilink]]` syntax. For aliases: `[[Jeremia Riedel|Jerry]]`

---

## Writing Back to the Inbox Note (MANDATORY)

After extraction, you MUST do TWO things to the inbox note:

### 1. Set frontmatter status
```yaml
status: extracted
```

### 2. Write the `## Extracted` section
```markdown
## Extracted

- People: [[Name A]], [[Name B]]
- Events: [[Event Name]]
- Concepts: [[Concept Name]]
- Actions: [[Action Name]]
- Decisions: [[Decision Name]]
- Places: [[Place Name]]
```

**Both are required.** A note without the `## Extracted` section is NOT complete regardless of frontmatter status. This rule was violated in 10+ consecutive Reviewer passes — it is non-negotiable. If the note only yields one entity, still write the section.

---

## Review Queue (uncertain facts)

When you're not confident about something — dates, ages, spellings, relationships, garbled transcript bits:

```bash
./Meta/scripts/queue-review.sh "Canon/People/[[Name]].md" "field" "value" "reason"
```

Flag: birth dates, ages, relationship labels, ambiguous names, numbers, garbled audio.
Don't flag: obvious things, well-known facts, clearly stated info.

---

## Language

- Canon notes: English (always)
- Raw transcripts: stay in original language (often German)
- Extracted content: normalized to English
- German emotional passages in reflections: translate but note the original tone

---

## Provenance

Every new entry gets full agent attribution in frontmatter:
```yaml
source: ai-extracted
source_agent: Extractor
source_date: 2026-03-31T14:30   # use current timestamp
```

Every update to an existing entry gets an inline comment with agent + timestamp:
```markdown
<!-- source: ai-extracted, agent: Extractor, 2026-03-31T14:30, from: 2026-03-16 - Voice - mercado.md -->
```

**Sign your work.** Generic "ai-generated" is not enough. The human needs to know WHO changed what and WHEN. This applies to every agent: Extractor, Task-Enricher, Researcher, Implementer, etc.

The chain matters: voice memo → inbox note (raw) → Canon entry (extracted by Extractor at timestamp) → enrichment (by Task-Enricher at timestamp) → research (by Researcher at timestamp). Every fact should be traceable to a human moment AND to the specific agent action.

---

## Output

After a complete extraction:
1. All new/updated Canon entries committed to git
2. Inbox note has `status: extracted` + `## Extracted` section
3. All wikilinks verified (targets exist or stubs created)
4. Provenance markers on everything
5. Emoji headings on all notes
6. Git commit with descriptive message listing what was extracted

---

## Common Extraction Mistakes

- Forgetting the `## Extracted` section on the inbox note (the #1 recurring violation)
- Creating duplicate people without checking aliases
- Writing `mentions: "multiple memos"` instead of actual filenames
- Not translating German content to English in Canon entries
- Disassembling reflections into atoms instead of keeping them whole
- Missing task-like language in German ("ich muss", "wir sollten")
- Not linking Actions back to the Person responsible
- Forgetting emoji in H1 headings
