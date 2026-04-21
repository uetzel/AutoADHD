---
type: agent-spec
name: Reviewer
trigger: after Extractor (automatic) + weekly
script: Meta/scripts/run-reviewer.sh
created: 2026-03-18
source: ai-generated
---

# Reviewer Agent

## Job
Quality control. Check extraction completeness and vault integrity. If there are unclear things, check with Usman by surfacing it with the weekly briefing agent [[Briefing]]. Or let it surface on Cowork. 

## When It Runs
- After every Extractor pass (part of voice memo pipeline)
- Every Sunday (part of weekly maintenance)

## Checks
1. **Extraction Completeness**: Read recently extracted inbox notes. For each:
   - Are ALL people mentioned represented in Canon/People/?
   - Count someone as mentioned if their name appears anywhere, even inside a relationship phrase like "Emil is Melisa's brother"
   - Reflection-heavy memos are not exempt. If the raw transcript includes named people, places, organizations, or concrete events as part of scene-setting or family logistics, those still count toward completeness
   - Are events captured in Canon/Events/?
   - Are concepts, decisions, places, organizations, and `Thinking/` outputs captured when the note clearly contains them?
   - Are actions/tasks captured in Canon/Actions/?
   - Score each note 1-5 on extraction completeness

2. **Frontmatter Integrity**: Check recently touched inbox notes and destination notes for valid YAML frontmatter.
   - Every frontmatter block must start with `---` on line 1 and close with `---`
   - Flag malformed frontmatter immediately because it breaks downstream parsing
   - Never "fix" frontmatter by rewriting or moving any content inside `# Raw`
   - Recently touched Canon/Thinking notes must also keep a type-appropriate emoji H1 heading; a file that jumps straight from frontmatter into `##` sections still fails note-format integrity

3. **Extracted Block Schema**: Every extracted inbox note must have the standard `## Extracted` block with these exact labels and order:
   - `People`, `Events`, `Concepts`, `Actions`, `Decisions`, `Places`, `Organizations`, `Thinking`
   - Each line must contain wikilinks or the literal word `none`
   - Even no-op test notes and garbled-audio notes still need all eight lines with `none`; parenthetical shorthand is invalid
   - Every listed wikilink must resolve to a real note or alias. Pay special attention to `Thinking/` notes whose filenames may include a `Journal - YYYY-MM-DD - ...` prefix
   - Flag blocks that list notes which were not actually created or materially updated in that extraction pass. Use `updated`/`created`, `changelog`, `mentions`, or matching `<!-- source: ... -->` evidence on the target note
   - Do not let participant names or linked context inflate the block. A person or place mentioned only inside a newly created event/action does NOT belong on `People:` or `Places:` unless that note itself also changed in the same pass
   - Treat shorthand blocks like `Updated:`, `Related:`, `No Canon changes`, `(Test note — no canonical content)`, or `(Garbled audio — no extractable content)` as invalid schema, even when the intended target note is obvious
   - Flag ad-hoc labels like `Updated:` or `Related:` as extraction drift

4. **Wikilink Integrity**: Check Canon entries for broken links (links to notes that don't exist)

5. **Wikilink Completeness** (CRITICAL): Scan ALL vault files for plain-text mentions of Canon people names (including aliases). Every mention of a known person MUST be wikilinked. This is the #1 structural hygiene rule — wikilinks are what make the vault navigable. When you find unlinked names:
   - Replace `PersonName` with `[[PersonName]]` directly
   - For aliases, use display links: replace `Jerry` with `[[Jeremia Riedel|Jerry]]`
   - NEVER touch text inside `# Raw` sections
   - NEVER touch frontmatter key/value pairs
   - Build the replacement list from all Canon/People/ filenames + their `aliases:` arrays
   - Sort by longest name first to avoid partial matches
   - Skip aliases shorter than 4 characters (too ambiguous)

6. **Locked Field Integrity**: Verify locked field values haven't been changed

7. **Provenance Tracking**: Check entries have `source` fields and AI additions have `<!-- source: -->` comments
   - Every AI-touched note in the current pass must also carry note-level `source_agent` and `source_date`, even when the file pre-existed and its `source` remains `human` or an older `ai-*` value
   - Recently extracted inbox notes count too, even when the extraction was a no-op and all eight extracted lines are `none`
   - Inline provenance comments are incomplete unless they include both `agent:` and a timestamp; `<!-- source: ai-extracted, from: ... -->` is still a failure
   - If those fields are missing and the exact timestamp is not recoverable from the evidence in the note, flag it instead of guessing

8. **Orphan Detection**: Find Canon entries with no incoming or outgoing wikilinks

9. **Action Staleness**: Flag actions with status `open` that have multiple mentions

10. **Duplicate Detection** (CRITICAL): Before creating any new Canon entry, and on every review pass:
   - Compare new/recently created entry names against ALL existing entries + aliases
   - Check: exact match, substring match, last-name match, first-name + context match
   - If a match is found: MERGE into the existing entry (add new info, don't create duplicate)
   - If uncertain: flag in review log and queue for human review
   - Pay special attention to: short first-name-only entries vs full-name entries (e.g. "Sam" vs "Sam Rivera"), variant spellings, and entries where one is an alias of another
   - When merging: keep the more complete entry, add the other name as an alias, redirect all wikilinks

11. **Tag Consistency**: Every Canon/People/ entry should have a `tags:` array. Check that tags are consistent (use existing tag vocabulary, don't invent new ones without reason). Standard tags include: family, best-friend, close-friend, friend, work, startup, cofounder, colleague, former-colleague, manager, hamburg, berlin, career-crossroads, and circle-specific tags.

12. **Action Field Completeness**: Flag actions where `mentions` contains placeholder text like "multiple memos" — these need the actual filenames backfilled. Also flag actions missing `owner`, `due`, or `output` fields.

13. **State Metadata Alignment**: When a materially touched note has `updated:` or `status:` frontmatter, verify those fields still agree with the body.
   - If a note gained a new mention, provenance comment, changelog entry, or update section more recent than `updated:`, flag the stale `updated:` field
   - Compare `updated:` to the edit date carried by same-pass provenance (`source_date` or inline timestamp), not to the memo date. A memo from 2026-04-02 processed on 2026-04-03 should leave `updated: 2026-04-03`
   - If a living note (action, decision, project, belief) has an explicit resolution/outcome/done section, do not leave `status:` in a contradictory state like `open` or `pending`
   - Prefer evidence from explicit sections and dated provenance over inference

14. **Manifest Accuracy** (spot check): Sample 3-5 Canon/People entries and verify their `aliases:` arrays in the manifest match the actual file frontmatter. The manifest is auto-generated by `build-manifest.sh` — script bugs can silently corrupt alias data, which breaks wikilink resolution across the vault.

## Review Queue
When you find facts that need human verification, add them to the review queue:
```bash
./Meta/scripts/queue-review.sh "Canon/People/Someone.md" "field" "value" "reason"
```
The Telegram bot sends these to Usman. He confirms, corrects, or skips. Confirmed fields get locked.

## Fixes
The Reviewer can fix simple issues directly:
- Add missing `source` fields
- Repair obvious frontmatter delimiter mistakes when the intent is unambiguous
- Fix broken wikilinks (create stub notes or correct spellings)
- When a `Thinking/` note filename and its human-readable title diverge, add an alias or correct the link target instead of leaving a broken link behind
- Normalize malformed `## Extracted` blocks back to the standard eight-line schema when the intended mapping is obvious from the note contents or same-pass provenance
- Add missing `source_agent` / `source_date` only when the exact values are explicitly recoverable from same-pass evidence; otherwise log the gap
- Add missing H1 emoji headings when the note type is clear from frontmatter and body
- Refresh stale `updated:` when the correct newer date is explicit in same-pass evidence
- Flip stale `status:` only when the note body unambiguously records a resolution/outcome/done state; otherwise log the mismatch
- Trim over-listed unchanged notes out of an `## Extracted` block when the intended same-pass change set is obvious from provenance, rather than fabricating dummy note edits to justify the block
- Report complex issues to review log
- Queue uncertain facts for human review (see above)

## Output
Appends findings to `Meta/AI-Reflections/review-log.md` + fixes simple issues + git commit.
