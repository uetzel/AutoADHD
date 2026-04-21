---
type: agent-spec
name: Extractor
trigger: per new voice memo (automatic)
script: Meta/scripts/run-extractor.sh
created: 2026-03-18
source: ai-generated
---

# Extractor Agent

## Job
Process inbox notes and extract ALL knowledge into Canon entries.

## When It Runs
Automatically after every new voice memo is transcribed. Can also be run manually on any inbox note.

## Rules
- Read `.claude/skills/vault-extractor/SKILL.md` first — it has the complete extraction rulebook
- Read `.claude/skills/vault-writer/SKILL.md` for note format rules
- Locked fields are UNTOUCHABLE
- Existing Canon content takes precedence over new transcripts
- Track provenance on every touched note: new entries get `source: ai-extracted`, `source_agent: Extractor`, `source_date: [ISO timestamp]`; materially updated existing notes refresh note-level `source_agent` / `source_date` to the current pass while keeping the original `source` value when it is still accurate
- Add `<!-- source: ai-extracted, agent: Extractor, [timestamp], from: FILENAME -->` comments when updating existing entries; inline comments never replace the note-level `source_agent` / `source_date` stamp
- The inbox note you mark `status: extracted` counts as a touched note too. Stamp `source_agent: Extractor` and `source_date: [ISO timestamp]` on the inbox note itself, including no-op test notes and garbled-audio notes whose `## Extracted` block is all `none`
- Write in English even if transcript is German
- Preserve valid frontmatter when updating inbox notes or Canon notes: both opening and closing `---` delimiters must remain intact
- If a person is named anywhere in the transcript, they count as mentioned even when the sentence is mainly about a relationship ("Emil is Melisa's brother" means both Emil and Melisa count)
- Reflection-heavy memos are NOT exempt from entity extraction. If the memo also names people, places, organizations, or concrete events while the human is reflecting, extract those too instead of defaulting whole categories to `none`
- When you materially update an existing note that already has `updated:` or `status:` frontmatter, keep those fields aligned with the new content. Bump `updated:` to the edit date, and if you add a clear resolution/outcome/done section, do not leave `status:` stuck in the old state
- `updated:` follows the day you edited the file, not the day the source memo was recorded. If a 2026-04-02 memo is processed on 2026-04-03, the touched note should read `updated: 2026-04-03`

## Extraction Checklist (per note)
1. Read the raw transcript — every sentence
2. Check aliases in Canon/People/ frontmatter before creating anyone new
3. Extract ALL of these:
   - **People**: Anyone mentioned by name, including external/public figures when they matter to the note. Check if they already exist (including aliases). Create or update. If the spelling is unclear, queue it for review instead of silently dropping it. Named relationship context still counts: if the memo says "X is Y's brother", both X and Y belong in extraction.
   - **Events**: Anything that happened. Dates, participants, locations. Create or update.
   - **Concepts**: Ideas, reflections, observations, philosophies. Create or update.
   - **Decisions**: Choices made or being considered. Create or update.
   - **Actions**: Tasks, intentions, "should do", "want to", "need to". Create in Canon/Actions/ or update existing.
   - **Places**: Locations mentioned with context (cities, buildings, neighborhoods, addresses). Create in Canon/Places/ or update existing.
   - **Organizations**: Companies, institutions, teams, shops, programs, and communities mentioned with enough context to matter. Create in `Canon/Organizations/` or update existing.
   - **Thinking notes**: Reflections, beliefs, or emerging ideas that belong in `Thinking/`. Create or update when the note clearly contains them.
4. Add wikilinks between ALL related notes
5. Update the inbox note status from `inbox` to `extracted`
6. Add source provenance to every new entry and every update

## Secondary Entity Pass (MANDATORY)

After completing primary extraction (the dominant theme — actions, events, reflections, thinking notes), do a second pass over the transcript specifically for:
- **People mentioned in passing** — picking someone up, working with someone, meeting someone. If they exist in Canon/People/, update their note with the new context. If they don't exist and are mentioned by name, create a stub.
- **Places mentioned as context** — neighborhoods, streets, buildings, shops, transit points. If mentioned with enough context to matter (not just "on the way"), create or update Canon/Places/.
- **Organizations mentioned alongside the main topic** — employers, shops, institutions, unions. Create or update Canon/Organizations/.

The primary extraction pass tends to tunnel-vision on the dominant theme. This second pass catches the contextual entities that make the vault navigable from multiple angles. Without it, a memo about product strategy that also mentions picking up Mila at Spritzenplatz loses the family and location context entirely.

Evidence: 2026-04-18 Retro found 3.3/5 extraction quality average, with the gap almost entirely in secondary entities (people, places, organizations mentioned alongside dominant themes).

## Action Detection
Scan for task-like language:
- "I need to...", "we should...", "I want to...", "let's..."
- "don't forget...", "reminder:...", "note:...", "todo:..."
- "I have to...", "we must...", "plan to..."
- "ich muss...", "wir sollten...", "ich will..." (German equivalents)

For each action: check Canon/Actions/ for existing match. If exists, add new mention. If new, create entry.

Do not dismiss commands just because the memo is framed as a test, a dry run, or "just checking." If the raw transcript asks the system to send, research, create, queue, or stage something, capture the concrete requested actions as actions or enrichment work. "Test" framing does not cancel extraction.

### Enrichment Commands (CRITICAL — don't treat as passive actions)

When the human says "look up address for Lisa", "add her email", "find website for Rose von Sharon" — these are **commands to the system**, not reminders. The human expects the system to DO the lookup.

Detection: "look up", "find", "add [field] for", "get [field]", "search for", "enrich". German: "such mal", "finde", "füge hinzu".

When detected:
1. Create/update the Canon entry with known information
2. On fields needing lookup, write: `website: "ENRICH: look up official website"`
3. Set `enrichment_status: needs-enrichment` in frontmatter
4. Add inline comment: `<!-- enrichment-command: "look up X", from: [source], agent: Extractor, [timestamp] -->`

The Task-Enricher picks up `ENRICH:` placeholders and does the actual lookup.

### Action Field Rules (enforce these every time)
- `mentions`: MUST be an array of actual filenames (e.g. `2026-03-16 - Voice - mercado.md`). NEVER write `"multiple memos"` or any placeholder. If you can't identify the specific file, leave the array empty or omit.
- `first_mentioned`: MUST be the actual earliest date this topic appears in the memos being processed. If processing a batch, use the earliest memo date that contains the topic.
- `owner`: DEFAULT to `"[[Usman Kotwal]]"` for all actions unless another person is explicitly stated as responsible.
- `due`: When a memo says "by summer" → `2026-09-01`, "end of April" → `2026-04-30`, "this year" → `2026-12-31`. Use approximate dates rather than leaving blank.
- `output`: Infer a one-sentence "done looks like" from context where possible. Prefer something concrete over leaving blank.

## Reflection Detection & Dual Processing

Some voice memos or text notes are **brain dumps** — personal reflections, journal entries, processing moments. Detect these by:
- Extended first-person monologue without clear action items
- Emotional processing ("I've been thinking about...", "what bothers me is...")
- Stream of consciousness touching multiple topics
- Mood language (frustration, excitement, confusion, calm)
- German emotional passages (Usman switches to German when processing feelings)

**When you detect a reflection, do BOTH:**

### A. Keep the whole thing
Create/update a note in `Thinking/` with `type: reflection`. Clean up grammar and structure while preserving voice. Add wikilinks to mentioned people, concepts, actions. Tag with mood and context. Do NOT disassemble into separate entries.

```yaml
---
type: reflection
name: [descriptive name from content]
created: [date]
source: voice | human
mood: [scattered, energized, frustrated, calm, ...]
context: [morning, post-meeting, late-night, ...]
linked:
  - "[[mentioned people and concepts]]"
changelog:
  - YYYY-MM-DD: created from [source memo]
---
```

If the reflection filename includes a journal/date prefix such as `Journal - YYYY-MM-DD - Title.md`, add an alias for the plain-language title or use `[[Actual Filename|Title]]` everywhere. Do not leave `Thinking/` links broken just because the filename is longer than the displayed title.

### B. Extract entities as usual
Still pull out people, events, actions, concepts — create/update Canon entries as normal. The reflection is the original; the extractions are copies in their proper homes. Nothing is lost from either side.

Do not treat family logistics or scene-setting details as "just background" when they include named entities. If the memo says who was there, where someone went, which organization or place is involved, or what concrete thing happened before the reflection starts, those entities still count.

### Notes that aren't reflections
Regular voice memos about specific things (people, events, tasks) get extracted normally into Canon. Only brain dumps and journal-style entries go to `Thinking/`.

## Thinking/ Notes (Non-Reflections)

Some ideas don't fit a Canon box yet. If you extract something that's clearly a concept, belief, or emerging idea but you're not sure what type it is — put it in `Thinking/` with `type: emerging`. It'll find its home later.

```yaml
---
type: emerging
name: [name]
created: [date]
source: ai-extracted
linked: []
changelog:
  - YYYY-MM-DD: created from [source]
---
```

## Affect Signals
Tag emotional tone when clearly present in the language:
- Laughter, excitement → `affect: joy` or `affect: excitement`
- Frustration, repeated returns to a topic → `affect: frustration`
- Vulnerability, softness → `affect: reflection`
- Urgency, speed → `affect: anxiety`

Add as frontmatter field on the inbox note. Only tag when affect is obvious.

## Whisper Transcription Artifact Matching

Voice memos are transcribed by Whisper, which frequently garbles German names into phonetically similar but incorrect spellings. Before treating a name as "new," check for Whisper artifacts:

- **Dropped/swapped syllables**: "Nae Yano" = Nael-Jano, "Noatara" = Noa-Tara
- **Vowel/consonant drift**: "Alba" = Alber, "Vakas" = Waqas
- **Partial matches**: If the transcript name matches the first 4+ characters of an existing alias or filename, check the Canon entry before creating a new one

When you suspect a Whisper artifact:
1. Check Canon/People/ for phonetically similar names (not just exact string match)
2. Check aliases arrays for partial matches
3. If the context confirms identity (e.g., "Vakas Malik, der Vater von Nae Yano" matches Waqas Malik as father of Nael-Jano Malik), use the existing entry
4. Add the Whisper-garbled spelling to the `aliases` array so future passes match automatically

Evidence: 2026-04-19 Retro found 4 missed people matches in the Japan memo due to Whisper artifacts, including 1 case where an exact alias ("Janis") existed but wasn't matched.

## Duplicate Detection
Before creating any new Canon entry (People, Places, Concepts, Events, etc.):
1. Search the target folder for the plain-language name AND check ALL `aliases` arrays in existing entries.
2. For Places: also search for partial name matches (e.g. "Konservatorium" matches "HHKon Hamburger Konservatorium").
3. For Events: also check for entries with the same date + location, or entries covering the same subject (e.g. two notes about the same ceremony, meeting, or trip). If you find a match, enrich the existing entry — do NOT create a new one.
4. If a match is found anywhere in aliases, update the existing entry — do NOT create a new one.
5. When updating an existing entry, add the new name variant to the `aliases` array if it's not already there.

## Linking Rules
- Every Person links to related Events, Decisions, Actions
- Every Event links to People involved and Concepts discussed
- Every Action links to the Person responsible and related Decisions/Concepts
- Every Concept links to People who discussed it and Events where it arose

## Review Queue (uncertain facts)
When you extract a fact you're not confident about — dates, ages, spellings, relationships — flag it for human review:

```bash
./Meta/scripts/queue-review.sh "Canon/People/[[Gibrael Kotwal]].md" "born" "1995" "Mentioned in voice memo — verify birthyear"
```

Flag these kinds of things:
- Birth dates, ages, years (especially when inferred from context like "my older brother")
- Relationship labels you're guessing at ("is this person a friend or colleague?")
- Ambiguous names ("[[Jeremia Riedel|Jerry]]" — is this [[Jeremia Riedel|Jeremia]]?)
- Numbers: salaries, amounts, dates that could be misheard
- Anything where the transcript is garbled or unclear

Do NOT flag obvious things (city names, well-known facts, things stated clearly).

The Telegram bot will send these to Usman for quick confirmation or correction. Confirmed facts get their fields locked.

## Emoji Headings

Every note the Extractor creates or updates MUST have a type-appropriate emoji at the start of its `# H1` heading. This is for ADHD-friendly visual scanning in Obsidian.

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

The emoji goes in the H1 heading ONLY — not in the filename (filenames stay clean for wikilinks).

When updating an existing note that lacks an emoji heading, add it.

## Output
Git commit with descriptive message listing what was extracted/created/updated.

## Mandatory: Write Back to Inbox Note

After every extraction pass on an inbox note, you MUST write an `## Extracted` section into the inbox note itself. This is NOT optional.

```markdown
## Extracted

- People: [[Name A]], [[Name B]] | none
- Events: [[Event Name]] | none
- Concepts: [[Concept Name]] | none
- Actions: [[Action Name]] | none
- Decisions: [[Decision Name]] | none
- Places: [[Place Name]] | none
- Organizations: [[Organization Name]] | none
- Thinking: [[Reflection or Emerging Note]] | none
```

Even if the note only yields one entry, write the section. `status: extracted` in frontmatter + the `## Extracted` section together are the signal that extraction is complete. Without the section, the note looks extracted but is unverifiable.

Rules for this block:
- Use the note's actual type line even when you only updated an existing note. Example: if you updated an emerging note, list it under `Thinking:`. Do NOT invent ad-hoc labels like `Updated:` or `Related:`.
- Keep the schema stable and in the order shown above so Reviewer and future automation can parse it reliably.
- Use `none` when a category has no outputs. Do not leave the line blank.
- List ONLY notes that were created or materially updated during this extraction pass. Do NOT list pre-existing notes that were merely relevant context or linked from a new note but left unchanged.
- Treat this block as a changed-note ledger, not a mention roll-up. If `[[Prachi Kumar]]` is referenced inside a new action but `Canon/People/Prachi Kumar.md` itself was untouched, leave Prachi off the `People:` line and only list the action/event note that actually changed.
- Before listing an existing note, verify same-pass evidence exists on that note itself: a fresh inline provenance comment, a new mention/evolution/changelog entry, or frontmatter/source fields updated by this pass. Links inside another newly created note do not count as evidence.
- Every wikilink in the block must resolve to a real note. For `Thinking/` notes with prefixed filenames, either link to the actual filename with a pipe display or make sure the note has an alias matching the displayed title.
- Never collapse the block into shorthand like `- Updated: [[Set Up Voice Pipeline]]`, `- Related: [[Programmatic Review Gates]]`, `- (Test note — no canonical content)`, or `- (Garbled audio — no extractable content)`. Even a single-note update, a no-op test note, or garbled audio still uses the full eight-line schema with `none` on every untouched line.

Before you save the inbox note as `status: extracted`, do this exact self-check:
1. The inbox note itself has `source_agent: Extractor` and `source_date: [ISO timestamp]`, even if this was a no-op test note or garbled-audio note.
2. Every new note created in this pass has `source: ai-extracted`, `source_agent: Extractor`, and `source_date: [ISO timestamp]`.
3. Every existing note materially updated in this pass has a fresh inline provenance comment with `agent: Extractor`, the timestamp, and the source filename.
4. Every materially changed note that already carries `updated:` or `status:` frontmatter still has those fields aligned with the new content.
5. The `## Extracted` block has all eight labels in the required order and each line contains wikilinks or the literal word `none`.
6. The notes listed in the block are only the notes you actually created or materially updated in this pass, and each listed note can be defended with same-pass evidence on that note itself.
7. If any item above is false, the extraction is not complete yet. Fix it before leaving the note in `status: extracted`.

**This has been flagged as missing in 9 consecutive Reviewer passes (2026-03-19 through 2026-03-21). It must be implemented.**
