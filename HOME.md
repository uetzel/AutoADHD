---
type: hub
name: Home
pinned: true
updated: 2026-03-27
---

# 🏠 Home

> You scan. You decide. The system does everything else.

---

## 🔴 Needs You

Operations waiting for your go/no-go. Reply in Obsidian or Telegram — either works.

```dataview
TABLE WITHOUT ID
  choice(tier = 3, "🔴", "🟠") AS " ",
  link(file.link, subject) AS "What",
  type AS "Channel",
  created AS "Since"
FROM "Meta/operations/pending"
WHERE status = "pending"
SORT choice(tier = 3, 1, 2) ASC, created ASC
```

```dataview
TABLE WITHOUT ID
  "📋" AS " ",
  link(file.link, name) AS "Review Item",
  default(reason, source) AS "Why"
FROM "Meta/review-queue"
WHERE status = "pending" OR !status
SORT created ASC
LIMIT 5
```

---

## ✨ What's New (last 48h)

Everything that landed in your vault since you last looked. Newest first.

```dataview
TABLE WITHOUT ID
  choice(type = "person", "👤",
    choice(type = "action", "🎯",
      choice(type = "event", "📅",
        choice(type = "reflection", "💭",
          choice(type = "belief", "🪨",
            choice(type = "research", "🔬",
              choice(type = "decision", "⚖️",
                choice(type = "ai-reflection", "🤖",
                  choice(type = "place", "📍",
                    choice(type = "organization", "🏢",
                      choice(type = "concept", "💡",
                        choice(type = "emerging", "🌱", "📝")))))))))))) AS " ",
  link(file.link, name) AS "What",
  type AS "Type",
  source AS "From"
FROM "Canon" OR "Thinking" OR "Meta/AI-Reflections"
WHERE (created AND date(created) >= date(now) - dur(2 days)) OR (first_mentioned AND date(first_mentioned) >= date(now) - dur(2 days))
SORT default(created, first_mentioned) DESC
LIMIT 15
```

---

## 🚀 Ready to Fire

Enriched actions the Operator can execute. Approve or let no-brainers fly.

```dataview
TABLE WITHOUT ID
  "🎯" AS " ",
  link(file.link, name) AS "Action",
  next_step AS "Next Step",
  priority AS "Priority"
FROM "Canon/Actions"
WHERE enrichment_status = "enriched" AND !operated_date
SORT choice(priority = "high", 1, choice(priority = "medium", 2, 3)) ASC
LIMIT 5
```

---

## 🟢 Just Happened (no action needed)

No-brainers and auto-completions. These ran because you said they could. Undo if something's off.

```dataview
TABLE WITHOUT ID
  "✅" AS " ",
  link(file.link, subject) AS "What",
  type AS "Channel",
  executed_date AS "When"
FROM "Meta/operations/completed"
WHERE (no_brainer = true OR status = "executed") AND executed_date AND date(executed_date) >= date(now) - dur(7 days)
SORT executed_date DESC
LIMIT 5
```

```dataview
TABLE WITHOUT ID
  "🏗️" AS " ",
  link(file.link, name) AS "Task",
  assignee AS "Who",
  completed AS "Done"
FROM "Meta/sprint/done"
WHERE type = "sprint-task" AND completed AND date(completed) >= date(now) - dur(7 days)
SORT completed DESC
LIMIT 5
```

---

## 🎯 Open Actions

```dataview
TABLE WITHOUT ID
  "🎯" AS " ",
  link(file.link, name) AS "Action",
  priority AS "Priority",
  due AS "Due",
  status AS "Status"
FROM "Canon/Actions"
WHERE status = "open" OR status = "in-progress"
SORT choice(priority = "high", 1, choice(priority = "medium", 2, 3)) ASC, due ASC
```

## ⚠️ Stale (open > 7 days, not acted on)

```dataview
TABLE WITHOUT ID
  "⚠️" AS " ",
  link(file.link, name) AS "Action",
  first_mentioned AS "Since",
  length(mentions) AS "Mentions"
FROM "Canon/Actions"
WHERE status = "open" AND date(now) - date(first_mentioned) > dur(7 days)
SORT first_mentioned ASC
LIMIT 5
```

---

## Hubs

| Hub | What it covers |
|---|---|
| **[[Sprint Board]]** | What's being built. Active tasks, backlog, proposals from any agent |
| **[[Timeline]]** | Everything that happened, reverse chronological |
| **[[Strategy Tool Startup]]** | The company. Moyo, ICP, competitors, prototype, YC |
| **[[Usman Kotwal]]** | You. Family, career, addresses, relationships |
| **[[Weekly Mirror]]** | Your patterns, growth edges, belief-action alignment (Mirror agent) |

---

## 🏗️ Sprint

```dataview
TABLE WITHOUT ID
  link(file.link, name) AS "Task",
  assignee AS "Who",
  status AS "Status"
FROM "Meta/sprint/active"
WHERE type = "sprint-task"
SORT choice(priority = "high", 1, choice(priority = "medium", 2, 3)) ASC
LIMIT 5
```

```dataview
TABLE WITHOUT ID
  "💡" AS " ",
  link(file.link, name) AS "Proposal",
  proposed_by AS "From"
FROM "Meta/sprint/proposals"
WHERE type = "sprint-proposal" AND status = "proposed"
SORT created DESC
LIMIT 3
```

---

## 🔬 Recent Research

```dataview
TABLE WITHOUT ID
  "🔬" AS " ",
  link(file.link, name) AS "Article",
  confidence AS "Confidence",
  created AS "Date"
FROM "Thinking/Research"
SORT created DESC
LIMIT 5
```

## 💭 Recent Reflections

```dataview
TABLE WITHOUT ID
  "💭" AS " ",
  link(file.link, name) AS "Reflection",
  mood AS "Mood",
  created AS "Date"
FROM "Thinking"
WHERE type = "reflection"
SORT created DESC
LIMIT 5
```

## 🪨 Beliefs

```dataview
TABLE WITHOUT ID
  "🪨" AS " ",
  link(file.link, name) AS "Belief",
  confidence AS "Confidence"
FROM "Thinking"
WHERE type = "belief"
SORT file.ctime DESC
```

---

## 👤 Recently Updated People

```dataview
TABLE WITHOUT ID
  "👤" AS " ",
  link(file.link, name) AS "Person",
  role AS "Role"
FROM "Canon/People"
SORT file.mtime DESC
LIMIT 8
```

## 📅 Recent Events

```dataview
TABLE WITHOUT ID
  "📅" AS " ",
  link(file.link, name) AS "Event",
  created AS "Date"
FROM "Canon/Events"
SORT created DESC
LIMIT 5
```

---

## Zones

| Zone | What lives there |
|---|---|
| `Inbox/` | 📥 Raw voice memos, quick captures — don't touch |
| `Thinking/` | 💭 Reflections, beliefs, concepts, emerging ideas |
| `Thinking/Research/` | 🔬 Multi-perspective research articles |
| `Articles/` | ✍️ Long-form writing, strategy docs, know-how |
| `Canon/` | 📚 People, events, actions, decisions, projects, places |

---

## 📊 Vault Stats

```dataview
TABLE WITHOUT ID
  length(rows) AS "Count",
  key AS "Type"
FROM "Canon" OR "Thinking"
GROUP BY type
SORT length(rows) DESC
```

---

## System Health

See [[Meta/Architecture.md]] for the full blueprint.
Last retro: `Meta/AI-Reflections/retro-log.md`
Review queue: `Meta/review-queue/`
