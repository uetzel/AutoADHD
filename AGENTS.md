# AGENTS.md

Rules for any AI agent (Claude, Codex, or future systems) operating in this vault.

Read `CLAUDE.md` for the full protocol. Read `Meta/Architecture.md` for the system blueprint.
Read `Meta/Engineering.md` before making code, script, test, or CI changes.

## SKILLS (load the right one for your task)

Instead of reading all of CLAUDE.md, load the focused skill for what you're doing:

| Task | Skill to read |
|------|--------------|
| Creating or editing any vault note | `.claude/skills/vault-writer/SKILL.md` |
| Processing inbox notes → Canon entries | `.claude/skills/vault-extractor/SKILL.md` |
| Architecture or system design | `Meta/Architecture.md` |
| Code or script changes | `Meta/Engineering.md` |

Load the skill BEFORE starting the task. It has everything you need in ~200 lines instead of 300+.

---

## CORE RULES

1. **Git is the safety net.** Every change is tracked. Mistakes are revertable.
2. **Raw transcripts are sacred.** Never edit content under `# Raw` in Inbox notes.
3. **Don't fabricate.** If unsure, say so and ask.
4. **Use wikilinks.** `[[Name]]` is how structure is built.
5. **English for Canon.** Raw content stays in its original language.
6. **Locked fields are untouchable.** If a note has a `locked:` array, those fields cannot be changed by any agent.
7. **Provenance is mandatory.** Every fact must trace back to a source.
8. **Review gates are structural.** See `Meta/Architecture.md` for the three tiers.

## WRITE PERMISSIONS

- All folders are writable
- Exception: never edit `# Raw` sections in Inbox notes
- Exception: never change locked fields

## ENGINEERING RULES

- For code and tooling changes, follow TDD by default: test first, then implementation, then refactor.
- Run `make check` before considering code work complete.
- Use branches for structural changes to scripts, tests, CI, and automation.
- Keep agent content runs and code/tooling changes separate.
- Prefer small diffs and small commits over mixed changes.

## FOR OPENAI CODEX (GPT-5.4)

Codex is the **workhorse runtime** — handling structured, repeatable agent tasks. Claude handles interactive sessions, judgment-heavy analysis, and MCP tool execution (Gmail, Calendar, etc.).

### Agents You Run

| Agent | Spec | What It Does | Schedule |
|---|---|---|---|
| **Extractor** | `Meta/Agents/Extractor.md` | Process inbox notes → create/update Canon entries | On new inbox note |
| **Reviewer** | `Meta/Agents/Reviewer.md` | QA pass after extraction | After Extractor |
| **Implementer** | `Meta/Agents/Implementer.md` | Auto-fix findings from Retro + Reviewer | After Retro + Reviewer |
| **Retrospective** | `Meta/Agents/Retrospective.md` | Daily vault health check | Daily 9 PM |
| **Briefing** | `Meta/Agents/Briefing.md` | Daily morning briefing | Daily 7:30 AM |

### Agents You Also Run

These are routed via `agent-runtimes.conf`:
- **Task-Enricher** (`TASK_ENRICHER=codex`) — `--scan` mode uses Codex for AI enrichment. `--morning` and `--nudge` are pure shell (no AI needed). Daily 8:30 AM via launchd.
- **Researcher** (`RESEARCHER=codex`) — multi-perspective research swarm, daily scan + on-demand

### Agents That Stay on Claude

These need MCP tools or deep relational judgment:
- **Mirror** (`MIRROR=claude`) — personal pattern reflection. Runs weekly in `weekly-maintenance.sh` after Reviewer.
- **Thinker** (`THINKER=claude`) — deep connections + external research
- **Operator** — executes via MCP tools (Gmail, Calendar)

### How to Run an Agent

Each agent has a shell script: `Meta/scripts/run-[agent].sh`. These scripts:
1. Gather context (vault stats, recent notes, git activity)
2. Load the agent spec from `Meta/Agents/`
3. Invoke the AI with a structured prompt
4. Commit changes
5. Log to changelog

You can either execute the shell script directly OR read it to understand the context gathering and perform the same steps natively.

### Agent Chaining

- After **Extractor** → run **Reviewer**
- After **Reviewer** → run **Implementer** (trigger: `reviewer`)
- After **Retrospective** → run **Implementer** (trigger: `retro`)

### Output Locations

| What | Where |
|---|---|
| Extraction results | Canon/ folders + `## Extracted` section in inbox note |
| Review findings | `Meta/AI-Reflections/review-log.md` (append, never overwrite) |
| Retro findings | `Meta/AI-Reflections/retro-log.md` (append, never overwrite) |
| Implementer actions | `Meta/AI-Reflections/implementer-log.md` (append) |
| Briefing | `Inbox/[DATE] - Daily Briefing.md` |
| Tier 3 items | `Meta/review-queue/[timestamp]-[action].md` |

### Also Good For (non-agent work)

- **Script fixes** — bugs in `Meta/scripts/*.sh`, hardening, error handling
- **Bulk data processing** — parsing imports, transforming data
- **Prototype generation** — quick HTML/React prototypes from descriptions
- **Test writing** — test suites for vault scripts
- **Code-heavy tooling** — new scripts, pipelines, automation

### You Should NOT

- Write in Usman's voice (see `Meta/style-guide.md` — that's Claude's domain)
- Make architectural decisions (propose them in a PR description instead)
- Touch locked fields in any note's frontmatter
- Run Mirror or Thinker (these need Claude's judgment)
- Execute external service calls (Gmail, Calendar — that's the Operator via Cowork)

### Working Pattern
1. For agent runs: work directly on main, commit, push
2. For structural changes: work on a branch, push, let human review
3. Commit messages: `[AgentName] action: description` (e.g. `[Extractor] extract: 3 notes processed`)
4. For Tier 1 changes (script fixes, YAML cleanup): auto-merge is fine
5. For Tier 2+ changes: human reviews the PR

## KEY PATHS

```
CLAUDE.md              — vault rules, note formats, agent roles
Meta/Architecture.md   — system blueprint, runtimes, review gates
Meta/MANIFEST.md       — auto-generated vault index (don't edit)
Meta/scripts/          — all shell scripts (the plumbing)
Meta/Agents/           — agent specifications (the brains)
Meta/style-guide.md    — Usman's writing voice
Canon/                 — stable knowledge (people, events, concepts, etc.)
Inbox/                 — raw capture (voice memos, quick notes)
```

## CURRENT KNOWN ISSUES

Check `Meta/AI-Reflections/retro-log.md` and `Meta/AI-Reflections/review-log.md` for the latest findings. The Implementer agent handles most auto-fixes now, but code-level improvements to scripts are a good fit for Codex.

## WHEN IN DOUBT

Stop. Explain. Ask.
