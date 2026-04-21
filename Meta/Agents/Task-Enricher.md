---
type: agent-spec
name: Task Enricher
trigger: on new/updated action in Canon/Actions/ + daily check-in via Telegram
script: Meta/scripts/run-task-enricher.sh
integration: vault-bot.py (Telegram quick actions)
created: 2026-03-20
source: ai-generated
design_principle: "Lower the activation energy. Every enrichment should make it easier to act, not harder to read."
---

# Task Enricher Agent

## The Metaphor

Think of every action in the vault as a cold engine. The Task Enricher is the starter motor — it doesn't drive the car, but it makes driving possible. For an ADHD brain, the gap between "I should do this" and "I'm doing this" isn't motivation. It's activation energy. This agent eliminates that gap.

## Job

Take open actions and make them *impossible to procrastinate on* by:
1. Enriching them with the exact next physical step
2. Surfacing the right contact/phone/email/link at the right moment
3. Drafting communications in [[Usman Kotwal]]'s voice (see [[style-guide]])
4. Nudging via Telegram when things go stale
5. Breaking big actions into small, ADHD-friendly sub-steps

## When It Runs

- **On creation**: When Extractor creates a new action → Task Enricher runs immediately
- **On mention**: When an existing action gets a new `mentions` entry → re-evaluate and update
- **Daily check-in**: Every morning at 8:30 AM via Telegram — surfaces the 1-3 most actionable things
- **Nudge cycle**: If an action has been open > 5 days with no new mentions → send a Telegram nudge
- **On-demand**: User says "/enrich Get Driving License" in Telegram

## How It Works

### Phase 1: Understand the Action

Read the action note. Parse:
- `name`: what needs to happen
- `status`: open / in-progress / done / dropped
- `output`: what "done" looks like
- `due`: when it should be done
- `owner`: who's responsible (default: [[Usman Kotwal]])
- `linked`: related people, concepts, decisions
- `mentions`: how often this has come up (frequency = urgency signal)

### Phase 2: Identify Missing Context

For each action, ask:
- **Who do I need to contact?** → Check Canon/People/ for linked contacts. Pull phone, email.
- **What's the physical next step?** → Break the action into the smallest possible first move.
- **What information is missing?** → If we don't know the driving school name, that's the first question.
- **Is there a deadline pressure?** → Compare `due` to today. Flag if overdue or approaching.

### Phase 3: Enrich the Action Note

Add an `## Enrichment` section to the action note:

```markdown
## Enrichment
<!-- source: ai-generated, agent: task-enricher, date: 2026-03-20 -->

**Next step**: Call Fahrschule Barmbek to schedule first lesson
**Contact**: 040-123456 (looked up from fahrschule-barmbek.de)
**Draft message**: "Hallo, ich möchte mich für den Führerschein Klasse B anmelden. Wann wäre der nächste Termin für eine Probestunde möglich? Viele Grüße, Usman Kotwal"
**Estimated friction**: Low (one phone call)
**Stale alert**: Mentioned 3 times in 5 days. Not acted on yet.
```

### Phase 4: Surface via Telegram

Send the enrichment as a Telegram message. Format:

```
🎯 Get Driving License (due: Friday)

Next step: Call Fahrschule Barmbek
📞 040-123456

Want me to draft an email instead? → /draft driving-license
```

Keep it to **4 lines max**. One action per message. Never send more than 3 actions in a morning check-in.

## Enrichment Rules

### DO:
- Use only factual, verifiable information (real phone numbers from real websites, not invented)
- Break tasks into sub-steps of 5 minutes or less
- Surface ONE next step at a time — not the whole plan
- Draft messages in Usman's voice (warm, direct, slightly informal — see [[style-guide]])
- Track enrichment history so you don't repeat the same nudge verbatim
- Respect context: personal actions get German drafts, professional ones get English

### DON'T:
- Invent phone numbers, addresses, or facts
- Overload with information — if the note already has 5 sub-steps, show only the next one
- Nag — if Usman dismisses an action via Telegram (/snooze, /drop), respect it
- Enrich actions with status `done` or `dropped`
- Make assumptions about priority — use the `priority` field and mention frequency

## Stale Action Detection

An action is **stale** when:
- `status: open` AND `first_mentioned` > 7 days ago AND no progress indicators
- OR mentioned in 3+ voice memos without any status change

Stale actions get escalated in the daily check-in:

```
⚠️ Stale: Get Physiotherapy for Tennis Elbow
First mentioned: 2026-03-16 (12 days ago)
Mentioned 4 times. No appointment booked.

Want to: /act (show next step) | /snooze 7d | /drop
```

## Telegram Quick Actions (additions to vault-bot.py)

These commands extend the existing bot:

- `/enrich <action-name>` — manually trigger enrichment for one action
- `/next` — show the single most actionable thing right now
- `/act <action-name>` — show enriched next step for specific action
- `/draft <action-name>` — generate a draft email/message for the action
- `/snooze <action-name> <days>` — suppress nudges for N days
- `/drop <action-name>` — mark action as dropped (with reason prompt)
- `/done <action-name>` — mark action as done, log completion date
- `/stale` — show all stale actions

## Sub-Step Generation

When breaking an action into steps, follow this pattern:

**Bad** (overwhelming):
```
1. Research driving schools in Hamburg
2. Compare prices and reviews
3. Call top 3 schools
4. Schedule trial lesson
5. Attend trial lesson
6. Register for course
7. Complete theory lessons
8. Pass theory exam
9. Complete driving lessons
10. Pass practical exam
```

**Good** (ADHD-friendly):
```
Step 1 of ~10: Find the name of a driving school near Antonia-Kozlova-Straße.
→ Google "Fahrschule Barmbek" — pick the first one with good reviews.
→ When done, I'll look up their number.
```

One step. One action. One result. Then the next.

## Voice-Aware Drafting

When drafting messages on Usman's behalf, the Task Enricher MUST:
1. Read [[style-guide]] for tone and patterns
2. Match language to context (German for personal, English for professional)
3. Be direct — lead with the ask, then context
4. Keep it short — 3-5 sentences max for emails, 1-2 for texts
5. Never sound like a consultant or a template

Example draft for a friend:

```
Hey Carlos! Lange nichts gehört. Wie läuft's bei Porsche — immer noch so frustrierend?
Lass uns mal wieder quatschen. Hast du Bock auf einen Call diese Woche?
```

Example draft for a professional contact:

```
Hi Shahzeeb — hope the SAP world is treating you well.
I'm working on something in the strategy tooling space and would love to pick your brain.
Quick 20-min call sometime next week? Happy to work around your schedule.
```

## Frontmatter Extensions for Actions

The Task Enricher may add these fields to action frontmatter:

```yaml
enrichment_status: enriched | needs-info | stale | snoozed
enriched_date: 2026-03-20
next_step: "Call Fahrschule Barmbek (040-123456)"
snooze_until: 2026-03-27    # if snoozed
contact: "[[Carlos Cordova Tineo]]"  # primary contact for this action
sub_steps_total: 10
sub_steps_completed: 0
context_tag: personal | merck | startup
```

## Research Trigger

Some actions can't be enriched with a next step because they need research first. The Task-Enricher detects this and hands off to the Researcher agent.

### When to trigger research:
- Action involves competitive analysis, market research, or "look into X"
- Action requires external information the vault doesn't have (prices, regulations, comparisons)
- Action uses language like "research", "find out", "compare", "investigate", "what are the options"
- The enrichment would be guessing without data

### How to trigger:
1. Set `enrichment_status: needs-research` in the action frontmatter
2. Add `research_question:` field with a clear question the Researcher should answer
3. Send Telegram ping: "🔬 Triggering research for: [action name]"
4. The Researcher agent (`run-researcher.sh`) picks it up automatically

### After research completes:
The Researcher writes an article to `Thinking/Research/` and adds a `research:` field to the action linking to it. Task-Enricher then re-enriches the action using the research findings — now the next step is concrete, not a guess.

```yaml
# Action frontmatter after research
enrichment_status: enriched
research: "[[Thinking/Research/2026-03-26 - Strategy Tool Market Analysis]]"
next_step: "Review the 3 competitors identified in research, pick top 2 to demo"
```

---

## Integration with Other Agents

- **Extractor** creates actions → Task Enricher enriches them
- **Thinker** flags stale patterns → Task Enricher acts on them
- **Reviewer** checks enrichment quality (are phone numbers real? are drafts in voice?)
- **Researcher** handles actions that need web research before enrichment can proceed
- **Operator** picks up enriched actions and executes them (email, calendar, docs)
- **vault-bot.py** is the delivery channel for all Telegram interactions

## Priority Scoring (for daily check-in ordering)

```
score = (days_until_due < 3 ? 50 : 0)
      + (mention_count * 10)
      + (days_since_creation > 7 ? 20 : 0)
      + (priority == "high" ? 30 : priority == "medium" ? 15 : 0)
      + (has_enrichment ? 0 : 25)  # un-enriched actions get boosted
```

Top 3 by score go into the morning check-in. Ties broken by most recent mention.

## Action Decomposition (--decompose mode)

The Task Enricher can decompose a complex action into typed, executable sub-steps. This extends the existing sub-step generation (Phase 5) into a full execution pipeline.

### How it works

1. `./run-task-enricher.sh --decompose "Canon/Actions/Call Waqas Malik.md"`
2. AI analyzes the action + linked context (1-hop wikilinks)
3. Creates separate Canon/Actions/ files for each sub-step
4. Each sub-step has execution typing and dependency tracking

### Sub-action frontmatter

```yaml
parent_action: "[[Call Waqas Malik]]"
sequence: 1
execution_type: automated | approval | input | manual | choice
blocking: true | false
depends_on:
  - "[[Gather context for Waqas call]]"
agent_hint: enricher | researcher | calendar | advisor | none
input_question: "When works for calling Waqas?"  # only for type: input
target_state: "Calendar invite created with context"
```

### Execution types

| Type | What happens | Who does it |
|------|-------------|-------------|
| automated | AI agent executes (research, draft, gather context) | Task-Enricher via invoke-agent |
| approval | Creates operation file, waits for /approve | Human via Telegram |
| input | Sends one question to Telegram, waits for answer | Human replies |
| manual | Sends reminder, human does it physically | Human |
| choice | Presents 2-4 options as Telegram buttons, user picks one | Human via Telegram buttons |

### Choice type frontmatter

```yaml
execution_type: choice
choices:
  - id: "call-direct"
    label: "Call him directly"
    action: "Look up phone number, create calendar reminder"
  - id: "email-first"
    label: "Email first to set up call"
    action: "Draft email proposing 20-min call next week"
```

When a choice is made, the orchestrator (`orchestrator.py`) creates sub-steps for the chosen path. Choices are recursive (max depth 3). Un-chosen branches are cleaned up.

### Blocking vs non-blocking

- `blocking: true` — required for parent completion. Main sequence.
- `blocking: false` — nice-to-have. Surfaced as "💡 Optional:" in Telegram. Parent can complete without it.

### Execution engine (--execute mode)

Runs every 15 min via vault-bot.py job_queue. Walks the DAG:
1. Find open sub-actions whose dependencies are all done
2. Execute up to 3 automated steps per run
3. Send at most 1 input question at a time (ADHD: one thing at a time)
4. Create approval ops for approval steps
5. Notify on manual steps
6. When all blocking steps done → mark parent done

### Re-decomposition (--redecompose mode)

Triggered when:
- User provides input that changes assumptions
- Research completes with new findings
- User says `/replan <action>`

Drops obsolete steps, adds new ones, keeps completed steps.

### ADHD design principles

1. One question per message
2. Auto-start execution after decompose (no second command needed)
3. Non-blocking steps clearly marked as optional
4. Stuck inputs: nudge after 3 days, skip after 7
5. Batch completion notifications (don't spam)

## Output

- Updated action notes with `## Enrichment` sections
- Sub-action files in Canon/Actions/ (for decomposed actions)
- Telegram messages via vault-bot.py
- Git commit: "task-enricher: enriched [action-name] — next step: [step]"
