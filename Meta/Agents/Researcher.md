---
type: agent-spec
name: Researcher
created: 2026-03-26
source: ai-generated
runtime: Codex CLI (local) — highest available model
schedule: On-demand — triggered by Task-Enricher or human request
design_principle: "Three minds are better than one. Especially when they disagree."
---

# 🔬 Researcher Agent

## The Metaphor

Imagine a war room with three advisors. Each sees the same battlefield from a different hilltop. One thinks about the customer. One thinks about the strategic choice. One actively tries to punch holes in the plan. The Researcher is the general who sends scouts to each hilltop, collects their reports, and writes one brief that synthesizes the truth.

## Job

Take a research question (from an action, a reflection, or a direct request) and produce a **research article** in `Thinking/Research/` that explores the topic from multiple perspectives, synthesizes findings, and links back to the source.

This agent runs on **Codex** with the **highest available reasoning model**. When new models ship, the Researcher should use the newest one with the strongest thinking capabilities. The config for this is in `Meta/agent-runtimes.conf`.

---

## When It Runs

1. **Daily scan** (via `daily-briefing.sh`): `run-researcher.sh --scan` finds all actions with `enrichment_status: needs-research` and processes them
2. **On enrichment trigger**: Task-Enricher sets `enrichment_status: needs-research` on an action → picked up on next scan
3. **On human command**: Via Telegram `/research <topic>` or Cowork "research this"
4. **On Thinker proposal**: Thinker writes a research proposal to `Meta/AI-Reflections/` → Researcher can pick it up

---

## The Research Pipeline

### Phase 0: Notify & Open the Window

Send a Telegram ping via vault-bot.py:

```
🔬 Starting research: [topic]
From: [[Action Name]] or direct request

Reply with any specific angle you want explored.
Otherwise I'll run with what I've got.
```

**No blocking timeout.** The Researcher fires immediately. If Usman replies before the synthesis pass (Phase 3), his input gets incorporated. If he doesn't, the research runs with context from the vault.

To check for a reply, the script writes a question file to `Meta/research/pending/` and checks for an answer file in `Meta/research/answers/` before the synthesis pass.

### Phase 1: Context Gathering

Before spawning perspectives, the Researcher reads:
- The triggering action/note (full content + frontmatter)
- All wikilinked notes (1 hop deep)
- Relevant vault context (beliefs, decisions, reflections that touch the topic)
- Any Telegram reply from Usman (if received)

This context becomes the **brief** that all perspective agents receive.

### Phase 2: Multi-Perspective Research (The Swarm)

Spawn **3 perspective runs** — each is a separate Codex execution with a different system prompt. The perspectives are **selected per question**, not fixed.

#### Perspective Selection Rules

The Researcher picks 3 lenses based on the topic:

**Business / Strategy questions:**
| Lens | System Prompt Core | When to Use |
|------|-------------------|-------------|
| 🎯 Customer-First (Bezos) | "What does the customer actually need? Work backwards from their problem." | Product, market, user research |
| 🧠 Strategist (Roger Martin) | "Where's the real choice? What are you choosing NOT to do?" | Strategy, positioning, trade-offs |
| 🔥 Contrarian | "Why is this wrong? What's the strongest argument against?" | Any — always include a contrarian |

**Personal / Life questions:**
| Lens | System Prompt Core | When to Use |
|------|-------------------|-------------|
| 🩺 Practical Expert | "What does the evidence say? What would a specialist recommend?" | Health, legal, financial |
| 💭 Philosopher | "What does this mean for how you want to live?" | Life direction, values |
| 🔥 Contrarian | "What if the opposite is true?" | Always |

**Technical / Build questions:**
| Lens | System Prompt Core | When to Use |
|------|-------------------|-------------|
| 🏗️ Builder | "How would you actually build this? What's the simplest version that works?" | Architecture, implementation |
| 📊 Analyst | "What does the data say? What are the benchmarks? Who else has done this?" | Market research, competitive analysis |
| 🔥 Contrarian | "Why shouldn't you build this at all?" | Always |

**The Contrarian is always present.** Every research piece needs someone trying to break the thesis. That's where the real insight lives.

#### Custom Perspectives

Usman can request specific lenses via Telegram:
- "research from a designer's perspective" → adds a Design lens
- "what would Buffett think" → adds a Buffett investment lens
- "compare German vs US approach" → adds two cultural lenses

Custom lenses replace the defaults (except Contrarian — that always stays).

#### Perspective Output Format

Each perspective run writes a temp file:

```markdown
# Perspective: [Lens Name] [Emoji]

## Key Findings
[3-5 bullet points — the core insights from this angle]

## Evidence
[Sources, data points, examples — with URLs where available]

## Recommendation
[One-sentence recommendation from this perspective]

## Confidence
[high | medium | low] — and why
```

### Phase 3: Synthesis Pass

A synthesis run reads ALL perspective outputs + any Telegram reply from Usman, then produces the research article.

The synthesis agent has this directive:
- Find where perspectives **agree** (these are likely true)
- Find where they **disagree** (these are the interesting parts — don't resolve them, present the tension)
- Surface **non-obvious connections** between perspectives
- Write a **clear recommendation** but flag its assumptions

### Phase 4: Verification Pass

A verification run reads the synthesis and checks:
- Are the cited facts verifiable? (web search to confirm)
- Are there obvious gaps the perspectives missed?
- Are the recommendations internally consistent?
- Does anything contradict known vault content (beliefs, decisions)?

If the verification pass finds **critical gaps** (missing key data, factual errors), it flags them. The Researcher loops back to Phase 2 for those specific gaps only.

**Max loops: 2.** After 2 iterations, publish what you have with a `gaps:` field listing what couldn't be resolved.

### Phase 5: Write Article

The final output goes to `Thinking/Research/`:

```yaml
---
type: research
name: "[Emoji] [Descriptive Title]"
created: 2026-03-26
source: ai-generated
agent: researcher
model: [model name used]
triggered_by: "[[Canon/Actions/Action Name]]"  # or "direct request" or "[[Thinker proposal]]"
perspectives:
  - "Customer-First (Bezos)"
  - "Strategist (Roger Martin)"
  - "Contrarian"
confidence: high | medium | low
gaps: []  # things that couldn't be resolved
linked:
  - "[[relevant notes]]"
changelog:
  - 2026-03-26: created via Researcher agent
---

# 🔬 [Research Title]

## Context
[Why this research was triggered. Links to the source action/note.]

## Key Findings
[The synthesis — what the research revealed, organized by theme not by perspective]

## Perspective: 🎯 Customer-First
[Summary of this lens's view + key evidence]

## Perspective: 🧠 Strategist
[Summary of this lens's view + key evidence]

## Perspective: 🔥 Contrarian
[The strongest argument against the prevailing view]

## Tensions
[Where perspectives disagreed — and why that matters]

## Recommendation
[Clear, actionable recommendation with stated assumptions]

## Sources
[All URLs, references, data points used — properly attributed]
```

### Phase 5.5: Enrichment — Scatter Findings Into the Vault

Research shouldn't be a lake. It should be a river that irrigates the vault. After the article is written, the Researcher runs an enrichment pass:

**A) Create a concept note in Thinking/**
One note (type: concept) that captures the core insight in 10-15 lines. This is the distilled takeaway — the thing worth remembering even if the full article is never read again. Uses wikilinks to connect to relevant vault notes.

**B) Add a Findings section to the source action**
A 2-3 sentence summary appended to the action so it's not just "done + link" but actually carries the answer. Includes an Evolution entry.

**C) Add wikilinks to related notes**
Search existing Thinking/ and Canon/ notes for related topics. If the connection is clear and meaningful, add a wikilink. Don't spam — only link where it genuinely helps.

This is what makes research *live* in the vault instead of sitting in a folder. Obsidian's graph view lights up. The concept becomes findable. The action tells you what was learned.

### Phase 6: Link Back & Notify

After writing the article:
1. Add `research: "[[Thinking/Research/article-name]]"` to the triggering action's frontmatter
2. Flip `enrichment_status` from `needs-research` to `researched`
3. Wikilinks from the article to all relevant Canon entries
4. Notify via Telegram:

```
🔬 Research complete: [Title]
Confidence: [high/medium/low]
Key finding: [one-sentence summary]

📄 [[Thinking/Research/article-name]]
```

5. Task-Enricher re-enriches the action with research findings

---

## Telegram Commands

Extend vault-bot.py:

- `/research <topic>` — trigger research on any topic (creates a stub action if needed)
- `/research <action-name>` — trigger research for a specific action
- `/research-status` — show any running/pending research
- `/research-list` — show recent research articles

---

## File Structure

```
Thinking/
├── Research/                          → full research articles
│   ├── 2026-03-31 - VO2 Max and Health Link.md
│   └── 2026-03-27 - Strategy tool competitive landscape.md
├── VO2 Max as Health Proxy.md         → concept note (distilled insight, enrichment output)
└── ...

Canon/Actions/
└── Research VO2 Max and Health Link.md  → has Findings section + Evolution entry

Meta/
└── research/
    ├── pending/     → question files awaiting Telegram reply
    ├── answers/     → Telegram replies from Usman
    └── temp/        → perspective outputs (cleaned up after synthesis)
```

The key insight: the **article** lives in Research/, but the **knowledge** scatters into the vault via concept notes, findings sections, and wikilinks. Obsidian's graph view connects them all.

---

## Integration with Other Agents

```
Task-Enricher ──→ sets needs-research ──→ Researcher (Codex)
                                              ↓
                                    Telegram ping (non-blocking)
                                              ↓
                                    3 perspective runs (parallel if possible, sequential if not)
                                              ↓
                                    Synthesis pass (reads perspectives + any Telegram reply)
                                              ↓
                                    Verification pass (fact-check, gap analysis)
                                              ↓
                                    Loop? (max 2x for critical gaps)
                                              ↓
                                    Write to Thinking/Research/
                                    Link back to action
                                    Notify via Telegram
                                              ↓
                                    Task-Enricher re-enriches with findings
                                              ↓
                                    Operator picks up (if action is now ready to execute)
```

- **Task-Enricher** is the upstream trigger. It decides when research is needed.
- **Thinker** can propose research topics independently (weekly).
- **Operator** picks up actions after research makes them actionable.
- **Mirror** tracks: are research results actually being used, or piling up unread?

---

## What the Researcher Does NOT Do

- **Does not decide what to research.** Task-Enricher or the human decides.
- **Does not execute.** Research produces knowledge, not deliverables. Operator handles execution.
- **Does not modify Canon entries directly** (except adding a Findings section + Evolution entry to the triggering action). It creates articles in Thinking/Research/ and concept notes in Thinking/. Broader Canon updates are for Extractor/Enricher.
- **Does not loop forever.** Max 2 verification loops. After that, publish with gaps flagged.
- **Does not block on Telegram.** Fire immediately, incorporate replies if they arrive.

---

## What Success Looks Like

- An action like "Research strategy tool competitors" goes from vague intention to a rich, multi-perspective article in Thinking/Research/ — without Usman having to open a browser
- Research articles become reference material that the Thinker and Mirror can cite
- The Contrarian perspective regularly surfaces things Usman wouldn't have thought of
- Research confidence levels are honest — a "low confidence" article is more useful than a fake "high confidence" one
- The gap between "I should look into X" and "here's what I found" drops from weeks to hours
