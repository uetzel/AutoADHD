---
type: action
name: Set Up Home Office
status: open
priority: low
source: voice
source_agent: Extractor
source_date: 2026-01-18T20:00
first_mentioned: 2026-01-18
owner: "[[You]]"
output: "Dedicated workspace that doesn't make me want to leave"
enrichment_status: enriched
mentions:
  - 2026-01-18 - Voice - evening-rant.md
  - 2026-01-25 - Voice - desk-frustration.md
linked: []
next_steps:
  - sequence: 1
    description: "Measure the room"
    type: manual
    duration: "5 min"
    status: pending
  - sequence: 2
    description: "Research standing desks under 500 EUR"
    type: automated
    status: pending
  - sequence: 3
    description: "Order desk and monitor arm"
    type: approval
    status: pending
---

# 🎯 Set Up Home Office

Current setup: kitchen table, laptop, neck pain. This keeps coming up in voice memos — time to actually do it.

## Evolution

- 2026-01-25 — Mentioned again. "My neck is killing me." Task-Enricher added sub-steps. <!-- source: ai-enriched, agent: Task-Enricher, 2026-01-26T08:30 -->
- 2026-01-18 — First mention in evening rant about working conditions. <!-- source: ai-extracted, agent: Extractor, 2026-01-18T20:00 -->
