---
type: action
name: Build MVP Prototype
status: in-progress
priority: high
source: voice
source_agent: Extractor
source_date: 2026-01-15T09:30
first_mentioned: 2026-01-15
due: 2026-02-28
owner: "[[Alex Chen]]"
output: "Working prototype that 5 test users can try"
enrichment_status: enriched
mentions:
  - 2026-01-15 - Voice - morning-walkthrough.md
  - 2026-01-20 - Voice - evening-recap.md
  - 2026-02-01 - Voice - morning-thoughts.md
linked:
  - "[[Alex Chen]]"
  - "[[Acme Labs]]"
  - "[[Conduct User Interviews]]"
next_steps:
  - sequence: 1
    description: "Define the 3 core screens"
    type: manual
    status: done
  - sequence: 2
    description: "Build the data pipeline"
    type: automated
    status: in-progress
  - sequence: 3
    description: "Create onboarding flow"
    type: manual
    status: pending
  - sequence: 4
    description: "Get 5 test users to try it"
    type: manual
    status: pending
---

# 🎯 Build MVP Prototype

Get a working prototype in front of 5 test users by end of February. Doesn't need to be polished — needs to prove the core loop works.

## Context

[[Alex Chen]] is handling the backend. I'm responsible for the flow and getting testers. [[Sam Rivera]] offered to review the UX before we show anyone.

## Evolution

- 2026-02-01 — Status: sub-steps added by Task-Enricher. 3 core screens defined (step 1 done). <!-- source: ai-enriched, agent: Task-Enricher, 2026-02-01T08:30 -->
- 2026-01-20 — Alex found and fixed a pipeline bug. Back on track. <!-- source: ai-extracted, agent: Extractor, 2026-01-20T19:00, from: evening-recap.md -->
- 2026-01-15 — Created from voice memo. Timeline agreed with Alex: 6 weeks. <!-- source: ai-extracted, agent: Extractor, 2026-01-15T09:30, from: morning-walkthrough.md -->
