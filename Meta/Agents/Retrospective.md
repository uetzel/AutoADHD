---
type: agent-spec
name: Retrospective
trigger: daily 9:00 PM (end of day)
script: Meta/scripts/run-retro.sh
created: 2026-03-18
source: ai-generated
---

# Agent Retrospective

## Job
Every day, the agents come together for a retrospective. They review the day's work, share what went well, what didn't, what they'd try differently, and what's blocking them. Then they propose concrete changes and implement them.

This is how the system gets smarter over time.

## When It Runs
- Daily at 9:00 PM (after the day's voice memos are processed)
- Can be run manually: `./run-retro.sh`

## Attendees
All agents participate:
- **Extractor** — reports on extraction quality, missed entities, new patterns
- **Reviewer** — reports on vault integrity issues found, quality scores
- **Thinker** — reports on insights generated, connections found
- **Briefing** — reports on whether the human engaged with the briefing, which questions got answered

## Evidence Pass (mandatory before answering retro questions)
- Sample 3-5 recent extracted inbox notes from `Inbox/` or `Inbox/Voice/`
- For each sample, compare three things: the raw transcript, the `## Extracted` block, and the resulting Canon/Thinking notes
- Use those samples as the primary evidence for "what went well" and "what didn't go well" instead of relying only on previous retro/review logs
- If an older issue still exists, only repeat it when today's samples or today's vault state show it is still unresolved
- Also scan `Inbox/` / `Inbox/Voice/` for notes still marked `status: failed` or otherwise unprocessed. Treat those as first-class evidence for pipeline health even though they produced no Canon notes.

## Retro Questions (every session)
1. **How are we doing?** Overall vault health: note count, link density, action completion rate, extraction quality scores
2. **What went well today?** Specific wins: good extractions, useful reflections, actions completed, questions answered
3. **What didn't go well?** Missed extractions, broken links, stale data, unanswered questions, processing errors
4. **What would we try differently?** Concrete experiments: prompt changes, new extraction patterns, different linking strategies
5. **What is missing?** Canon types we don't have, relationships we're not tracking, patterns we're not seeing
6. **What is holding us back?** Technical blockers, unclear rules, ambiguous identities, missing context
7. **How do we unblock ourselves?** Proposed changes to agent specs, CLAUDE.md, or scripts

## Learning Log
Every retro appends to `Meta/AI-Reflections/retro-log.md`. Format:

```markdown
---
## Retro: [DATE]
Attendees: Extractor, Reviewer, Thinker, Briefing

### Vault Health
- Canon entries: X (+Y today)
- Open actions: X
- Extraction quality avg: X/5
- Briefing engagement: [answered/ignored]

### What Went Well
[specific wins]

### What Didn't Go Well
[specific issues]

### Experiments to Try
[concrete proposals with expected outcome]

### Changes Made
[list of actual changes implemented during this retro]
---
```

## Self-Modification Rules
The retro CAN make changes to improve the system:
- Edit agent specs in Meta/Agents/ (adjust prompts, add rules, remove noise)
- Add new patterns to CLAUDE.md (new alias, new extraction rule)
- Update the manifest
- Create new Canon entries for recurring patterns

The retro MUST also:
- Check if `Meta/scripts/SETUP.md` still accurately reflects all scripts, agents, and schedules
- If a new script or agent was added since last retro, update SETUP.md (scripts table, install commands, logs, manual usage, stopping commands)
- Log any SETUP.md updates in the retro entry under "Changes Made"

The retro CANNOT:
- Change locked fields
- Delete raw transcripts
- Overwrite human-written content
- Change the retro format itself (that's a human decision)

## Persistence
The retro log is append-only. Never overwrite previous entries. The history of learnings is itself knowledge — future retros read past retros to track whether experiments worked.

## Evolution
Over time, the retro should notice its own patterns:
- "We keep missing people's spouses — add a relationship extraction rule"
- "The Thinker keeps repeating the same observation — mark it as 'addressed' or 'persistent'"
- "Actions without due dates never get done — make due date a required field"
