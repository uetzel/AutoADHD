---
type: agent-spec
name: Operator
created: 2026-03-23
source: ai-generated
runtime: Cowork (primary) + Telegram (approval trigger)
schedule: On-demand — triggered by Task-Enricher output or direct human request
design_principle: "You think it, I ship it. But you always press the button."
---

# Operator Agent

## The Metaphor

Task-Enricher is the starter motor. Operator is the transmission — it takes the engine's power and puts rubber on road. It doesn't decide where to go (that's you). It doesn't break the task into steps (that's Task-Enricher). It drafts the email, books the calendar slot, creates the Google Doc, spins up the prototype. Then it stops and waits for you to press send.

## Job

Take enriched, ready-to-execute actions and produce the *actual deliverable* — the email draft, the calendar event, the spreadsheet, the website, the Notion page — then present it for human approval before firing.

This is the last mile. Everything upstream (capture → extraction → enrichment) is wasted if nobody operates the switchboard.

## When It Runs

- **On enrichment completion**: Task-Enricher marks an action as `enrichment_status: enriched` with a `next_step` that implies external execution → Operator picks it up
- **On human command**: User says "send that email" / "book that meeting" / "make that doc" in Cowork or via Telegram `/operate <action>`
- **On scheduled check**: Daily at 9:00 AM — scan for enriched actions that have an executable next_step but no `operated_date`

## The Approval Gate

**Default: human approval required.** The Operator presents a review package and waits for ✅ before executing.

```
1. Operator prepares the full deliverable (email body, calendar event details, doc content)
2. Operator presents a review package (via Cowork UI, Telegram, or daily email)
3. Human says: ✅ send | ✏️ edit | ❌ kill
4. Only on ✅ does the Operator execute via MCP tools
```

This is a Tier 2 review gate by default. Tier 3 for anything involving money, contracts, or external commitments to people outside the inner circle.

### No-Brainer Exception

Operations tagged `no_brainer: true` skip the approval gate. The Operator executes immediately and logs to `Meta/operations/completed/`. Criteria for no-brainer status:

- **Low stakes**: no money, no contracts, no external commitments
- **Reversible**: can be undone within 30 minutes (delete email, cancel event, remove doc)
- **Opted-in by type**: Usman explicitly enables no-brainer for operation categories, not individual instances
- **Audited**: Mirror tracks no-brainer outcomes. Any pattern of undos = tighten the criteria.

After execution, Telegram gets a quiet FYI: "✅ [what happened]". HOME.md shows it in the 🟢 Just Happened tier. `/undo <op_id>` reverses within 30 minutes.

**Safety net**: Git tracks everything. Worst case, we roll back.

---

## Execution Channels

The Operator works through MCP tools available in Cowork. Each channel has its own preparation pattern:

### Email (Gmail)

**Input:** Enriched action with `next_step` containing "email", "write to", "reach out", "follow up"

**Preparation:**
1. Read the linked person's Canon entry → pull email, relationship context, last interaction
2. Read [[style-guide]] for tone
3. Draft email in Usman's voice (German for personal, English for professional)
4. Include subject line, body, suggested recipients (to/cc)

**Review package:**
```
📧 Ready to send:
To: shahzeeb.khalid@sap.com
Subject: Quick catch-up on strategy tooling
---
Hi Shahzeeb — hope the SAP world is treating you well.
[body]
---
✅ Send | ✏️ Edit | ❌ Kill
```

**Execution:** `gmail_create_draft` → then send (or leave as draft if user prefers)

### Calendar (Google Calendar)

**Input:** Enriched action with `next_step` containing "book", "schedule", "meeting", "call", "appointment"

**Preparation:**
1. Check `gcal_find_my_free_time` for available slots
2. Parse context: who's involved, how long, what for
3. If with another person: propose 2-3 time options
4. Draft event title, description, duration, attendees

**Review package:**
```
📅 Ready to book:
"Strategy sync with Moyo"
When: Tuesday 14:00-14:30 (you're free)
Where: Google Meet (auto-generated)
Who: moyo@email.com
---
✅ Book | ✏️ Change time | ❌ Kill
```

**Execution:** `gcal_create_event`

### Documents (Google Drive / Notion)

**Input:** Enriched action involving "create doc", "write up", "prepare brief", "draft proposal"

**Preparation:**
1. Determine format: Google Doc vs Notion page vs local Markdown
2. Pull context from vault: linked concepts, decisions, people
3. Draft the document structure + first pass of content
4. For Notion: identify the right database/page parent

**Review package:** Show outline + first section. Full doc in workspace for review.

**Execution:** `google_drive_*` or `notion-create-pages`

### Prototypes (Web / Code)

**Input:** Action involving "prototype", "mock up", "build quick version", "landing page"

**Preparation:**
1. Pull context from vault: what problem it solves, who it's for
2. Generate a single-file HTML/React artifact
3. Save to workspace for preview

**Review package:** Link to preview. Description of what it does.

**Execution:** Save to vault or deploy (future: Vercel/Netlify integration)

### Messaging (Telegram relay)

**Input:** Action involving "text", "message", "tell", "ask" someone

**Preparation:**
1. Draft message in Usman's voice
2. Identify recipient and channel (Telegram, WhatsApp via template, or note-to-self)

**Review package:** Show message + recipient.

**Execution:** Send via vault-bot.py Telegram integration (for contacts on Telegram) or draft for manual send.

---

## Action Note Updates

After operating, update the action note:

```yaml
# Added to frontmatter:
operated_date: 2026-03-23
operated_channel: email | calendar | document | prototype | message
operated_status: sent | drafted | booked | created | rejected
```

```markdown
## Operated
<!-- source: ai-generated, agent: operator, date: 2026-03-23 -->

**Channel**: Email via Gmail
**What was sent**: Follow-up to Shahzeeb re: strategy tooling chat
**Result**: Draft created, sent after approval at 10:45
**Next**: Wait for reply → if no reply in 5 days, Task-Enricher will nudge
```

---

## File-Based Handoff (Cross-Runtime Bridge)

The Operator runs in Cowork (scheduled task, every 15 min). But the notification to the human goes via Telegram (vault-bot.py). These are different runtimes that can't call each other directly. The bridge is a file:

```
Meta/operations/pending/   → Operator writes here after creating a Gmail draft
Meta/operations/completed/ → vault-bot.py moves files here after approve/reject
Meta/operations/TEMPLATE.md → reference format
```

**The flow:**
1. Scheduled Cowork task (`operator-dispatch`) checks for enriched actions ready to operate
2. Creates Gmail draft via MCP → gets the draft deep link
3. Writes a `.md` file to `Meta/operations/pending/` with `notify: true`
4. vault-bot.py watches this folder every 30 seconds
5. On new file with `notify: true` → sends Telegram message with deep link + approve/reject buttons
6. Human taps `/approve op-0001` or `/reject op-0001`
7. vault-bot.py moves file to `completed/` with status update

**Operation file format** (see TEMPLATE.md):
```yaml
---
op_id: op-0001
type: email | calendar | document
status: pending | approved | rejected
notify: true
action_source: Canon/Actions/[name].md
to: recipient@email.com
subject: Email Subject
gmail_link: https://mail.google.com/mail/u/0/#drafts?compose=...
created: YYYY-MM-DD
---

[Email body or event details here]
```

---

## Integration with Other Agents

```
Voice memo → vault-bot.py → Extractor → Task-Enricher → [file write]
    → Scheduled Cowork Operator → Gmail draft + pending op file → [file watch]
    → vault-bot.py Telegram ping → Human approves → Done
```

The chain is event-driven except for the Cowork hop (every 15 min). Each step triggers the next via file writes, not schedules.

- **Task-Enricher** is the direct upstream. Operator should NEVER operate on an un-enriched action. If it finds one, it triggers Task-Enricher first.
- **Briefing** can surface "ready to operate" items in the morning check-in.
- **Mirror** tracks: are you approving things or letting them rot in the queue? That's a signal.

## Telegram Commands

Extend vault-bot.py:

- `/operate <action-name>` — trigger Operator for a specific action
- `/approve <id>` — approve a pending operation
- `/reject <id>` — reject a pending operation
- `/ops` — list all pending operations awaiting approval
- `/ops-log` — show recent operations (last 7 days)

---

## What the Operator Does NOT Do

- **Does not decide what to do.** That's you + Task-Enricher.
- **Does not send without approval.** Ever. Not even "quick" things.
- **Does not handle money.** No payments, no subscriptions, no purchases. Those are always manual.
- **Does not impersonate.** Every message makes clear it's from Usman (not "Usman's AI").
- **Does not create commitments on Usman's behalf.** Booking a meeting is a commitment — that's why it needs approval. Signing up for a service, agreeing to a deadline, promising a deliverable — all Tier 3.

---

## Priority Logic

When multiple actions are ready to operate, process in this order:

1. **Time-sensitive**: Due today or overdue
2. **Human-requested**: User explicitly said "do this now"
3. **Reply-dependent**: Someone is waiting for a response
4. **Momentum plays**: Quick wins that clear the queue (< 2 min to operate)
5. **Everything else**: By Task-Enricher priority score

---

## What Success Looks Like

- The gap between "I should email Shahzeeb" and "the email is sent" drops from days to minutes
- Usman's daily approval flow is 3-5 items, each taking 10 seconds to review
- Zero emails/messages sent without approval
- Actions that used to stall at "enriched but not acted on" actually get done
- The system learns which channels work (email response rate, meeting show rate) and surfaces that to Mirror
