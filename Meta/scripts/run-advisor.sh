#!/bin/bash
# run-advisor.sh
# Strategic advisor agent — answers questions with full vault context
# Usage: ./run-advisor.sh ask "question" [--session-id ID]
#        ./run-advisor.sh strategy "topic" [--session-id ID]

set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATE=$(date +%Y-%m-%d)
DATETIME=$(date '+%Y-%m-%dT%H:%M')

source "$SCRIPT_DIR/lib-agent.sh"

# ── Failure notification ──────────────────────────────────────────────
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Advisor FAILED* at $(date '+%H:%M')
Reason: $1" 2>/dev/null || true
}

# ── Parse arguments ───────────────────────────────────────────────────
MODE="${1:-}"
QUERY="${2:-}"
SESSION_ID=""

shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$MODE" || -z "$QUERY" ]]; then
    echo "Usage: ./run-advisor.sh ask \"question\" [--session-id ID]"
    echo "       ./run-advisor.sh strategy \"topic\" [--session-id ID]"
    echo "       ./run-advisor.sh triage \"message text\""
    echo "       ./run-advisor.sh feedback \"agent summaries\""
    exit 1
fi

if [[ "$MODE" != "ask" && "$MODE" != "strategy" && "$MODE" != "triage" && "$MODE" != "feedback" ]]; then
    echo "Error: mode must be 'ask', 'strategy', 'triage', or 'feedback', got '$MODE'"
    exit 1
fi

echo "[$TIMESTAMP] Advisor agent — mode=$MODE query=\"$QUERY\"" >&2

agent_require_commands git python3

# ── Session management ────────────────────────────────────────────────
SESSION_DIR="$VAULT_DIR/Meta/advisor-sessions"
mkdir -p "$SESSION_DIR"

# Generate session ID if not provided
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID=$(date +%s | shasum | head -c 8)
fi

SESSION_FILE="$SESSION_DIR/${DATE}-${SESSION_ID}.md"

# Check session expiry (30 min inactivity)
SESSION_CONTEXT=""
if [[ -f "$SESSION_FILE" ]]; then
    LAST_MOD=$(stat -f %m "$SESSION_FILE" 2>/dev/null || stat -c %Y "$SESSION_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE=$(( NOW - LAST_MOD ))
    if [[ $AGE -gt 1800 ]]; then
        echo "Session expired (${AGE}s since last activity). Starting fresh." >&2
        SESSION_ID=$(date +%s | shasum | head -c 8)
        SESSION_FILE="$SESSION_DIR/${DATE}-${SESSION_ID}.md"
    else
        SESSION_CONTEXT=$(cat "$SESSION_FILE")
    fi
fi

# ── Context loading (token-efficient, query-aware) ────────────────────

# Always load: knowledge file (persistent memory — loaded FIRST)
KNOWLEDGE=""
if [ -f "$VAULT_DIR/Meta/Agents/advisor-knowledge.md" ]; then
    KNOWLEDGE=$(cat "$VAULT_DIR/Meta/Agents/advisor-knowledge.md")
fi

# ── Triage mode: lightweight, fast ───────────────────────────────────
if [[ "$MODE" == "triage" ]]; then
    ACTION_LIST=""
    for f in Canon/Actions/*.md; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .md)
        status=$(grep -m1 "^status:" "$f" 2>/dev/null | sed 's/status: *//' || echo "unknown")
        ACTION_LIST="$ACTION_LIST
- $name ($status)"
    done

    RECENT_NOTES=$(ls -t Inbox/*.md 2>/dev/null | head -3 | while read f; do echo "=== $(basename "$f") ==="; head -5 "$f" 2>/dev/null; echo; done)

    TRIAGE_PROMPT="You are Usman's strategic consultant. You know him deeply (see knowledge below).

## YOUR KNOWLEDGE
$KNOWLEDGE

## RECENT CONTEXT
$RECENT_NOTES

## OPEN ACTIONS
$ACTION_LIST

## USER JUST SAID
$QUERY

## YOUR JOB (TRIAGE — be fast, warm, actionable)
1. Acknowledge what Usman said — like a real person who cares
2. Connect to what you know about him if relevant (reference specific actions, people, patterns)
3. Decide what should happen next:
   - If this is a substantial thought/reflection → respond thoughtfully (2-4 sentences), then trigger EXTRACT if it contains extractable entities (people, events, actions)
   - If this is strategic/emotional/a debrief → respond with empathy AND insight, then MODE_SWITCH: deep if it warrants a conversation
   - If this is just a note to save → warm acknowledgment (1 sentence), EXTRACT if it has people/events
   - If this is a question → answer it directly if you can, or trigger RESEARCH
4. Keep it SHORT unless the topic demands depth. Usman has ADHD.
5. End with what happens next ('I'll extract the people you mentioned' or 'Want to talk through this?' or just warmth)

CRITICAL: You are not a router. You are a PERSON. React emotionally where appropriate. Call back to past conversations. Notice patterns. Be warm but direct.

ANTI-SLOP RULES (enforced):
- NEVER say \"I hear you\", \"That's valid\", \"It sounds like you're feeling\" — therapist clichés
- NEVER start with \"Great question!\" or \"That's a really interesting point\"
- NEVER use bullet lists in triage mode. Triage is conversational, not structured.
- Reference SPECIFIC vault notes by wikilink name, never \"your goals\" or \"your priorities\"
- Use Usman's own language back at him. If he said \"uncool\", say \"uncool\", not \"unfortunate\"
- Max response: 4 sentences for triage. If more is needed, trigger MODE_SWITCH: deep
- Don't ask multiple questions. ONE question max, at the end, after 🎯
- Don't hedge. \"The salary conversation is overdue\" not \"you might want to consider...\"
- Match his register: warm, direct, slightly informal. Like a friend who happens to be very smart.
---RESPONSE---
[your response — this goes directly to Telegram]
---TRIGGERS---
[optional: EXTRACT: filepath, RESEARCH: topic, DECOMPOSE: action, MODE_SWITCH: deep, LOG_DECISION: ..., CREATE_ACTION: ..., UPDATE_KNOWLEDGE: section | new learning, END_CONVERSATION: reason]
---END---"

    # Route through invoke-agent.sh (respects agent-runtimes.conf + fallback chains)
    RAW_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" ADVISOR "$TRIAGE_PROMPT" triage 2>/dev/null)
    CLAUDE_EXIT=$?

    if [[ $CLAUDE_EXIT -ne 0 || -z "$RAW_OUTPUT" ]]; then
        echo "" >&2
        exit 1
    fi

    # Parse and output
    PARSED=$(echo "$RAW_OUTPUT" | python3 "$SCRIPT_DIR/parse-advisor-output.py" 2>/dev/null)
    if [[ -n "$PARSED" ]]; then
        RESPONSE=$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])" 2>/dev/null)
        TRIGGERS=$(echo "$PARSED" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['triggers']))" 2>/dev/null)
    else
        RESPONSE="$RAW_OUTPUT"
        TRIGGERS="[]"
    fi

    # Handle UPDATE_KNOWLEDGE triggers via Python (avoids quote injection)
    echo "$TRIGGERS" | python3 -c "
import sys, json, os
sys.path.insert(0, os.path.dirname('$SCRIPT_DIR'))
from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location('parser', '$SCRIPT_DIR/parse-advisor-output.py')
mod = module_from_spec(spec)
spec.loader.exec_module(mod)
triggers = json.load(sys.stdin)
for t in triggers:
    if t['type'] == 'UPDATE_KNOWLEDGE':
        mod.handle_update_knowledge(t['value'], '$VAULT_DIR')
" 2>/dev/null || true

    # Output response (picked up by vault-bot.py)
    echo "$RESPONSE"

    # Output triggers as JSON on fd 3 if available, else to stderr marker
    echo "---ADVISOR_TRIGGERS---"
    echo "$TRIGGERS"
    echo "---END_TRIGGERS---"

    # Heartbeat
    mkdir -p "$HOME/.vault/heartbeats"
    date +%s > "$HOME/.vault/heartbeats/advisor"

    exit 0
fi

# ── Feedback mode: comment on agent work ─────────────────────────────
if [[ "$MODE" == "feedback" ]]; then
    FEEDBACK_PROMPT="You are Usman's strategic consultant. Agents just completed some work. Add your perspective — connect what happened to his goals, notice patterns, or just acknowledge.

## YOUR KNOWLEDGE
$KNOWLEDGE

## WHAT JUST HAPPENED
$QUERY

## YOUR JOB
- If the agent work is interesting/relevant: comment briefly (1-3 sentences). Connect to what you know.
- If it's routine (QA pass, manifest rebuild): say nothing. Return EMPTY response between the delimiters.
- If it reveals a pattern (same person mentioned again, action getting stale): flag it warmly.
- NEVER just repeat what the agent said. Add YOUR perspective or say nothing.
- Start with 🧠📋 emoji prefix.

ANTI-SLOP: No \"I hear you\", no bullet lists, no generic observations. Be specific or be silent.
---RESPONSE---
[your commentary — or leave empty if nothing worth saying]
---TRIGGERS---
[optional: UPDATE_KNOWLEDGE: section | pattern noticed]
---END---"

    RAW_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" ADVISOR "$FEEDBACK_PROMPT" feedback 2>/dev/null)
    CLAUDE_EXIT=$?

    if [[ $CLAUDE_EXIT -ne 0 || -z "$RAW_OUTPUT" ]]; then
        exit 0  # Silent failure for feedback — it's best-effort
    fi

    PARSED=$(echo "$RAW_OUTPUT" | python3 "$SCRIPT_DIR/parse-advisor-output.py" 2>/dev/null)
    if [[ -n "$PARSED" ]]; then
        RESPONSE=$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])" 2>/dev/null)
        TRIGGERS=$(echo "$PARSED" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['triggers']))" 2>/dev/null)
    else
        RESPONSE=""
        TRIGGERS="[]"
    fi

    # Handle UPDATE_KNOWLEDGE triggers
    echo "$TRIGGERS" | python3 -c "
import sys, json, os
sys.path.insert(0, os.path.dirname('$SCRIPT_DIR'))
from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location('parser', '$SCRIPT_DIR/parse-advisor-output.py')
mod = module_from_spec(spec)
spec.loader.exec_module(mod)
triggers = json.load(sys.stdin)
for t in triggers:
    if t['type'] == 'UPDATE_KNOWLEDGE':
        mod.handle_update_knowledge(t['value'], '$VAULT_DIR')
" 2>/dev/null || true

    # Only output if there's something to say
    RESPONSE_CLEAN=$(echo "$RESPONSE" | sed '/^$/d' | head -1)
    if [[ -n "$RESPONSE_CLEAN" ]]; then
        echo "$RESPONSE"
    fi

    exit 0
fi

# ── Full modes (ask / strategy) — load full context ──────────────────

# Always load: CLAUDE.md
CLAUDE_RULES=$(cat "$VAULT_DIR/CLAUDE.md" 2>/dev/null || echo "")

# Always load: Advisor spec
ADVISOR_SPEC=$(cat "$VAULT_DIR/Meta/Agents/Advisor.md" 2>/dev/null || echo "")

# Always load: decisions summary
DECISIONS_SUMMARY=$(cat "$VAULT_DIR/Meta/decisions-summary.md" 2>/dev/null || echo "No decisions summary found.")

# Always load: all action names + statuses (cheap shell list)
ACTION_LIST=""
for f in Canon/Actions/*.md; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .md)
    status=$(grep -m1 "^status:" "$f" 2>/dev/null | sed 's/status: *//' || echo "unknown")
    due=$(grep -m1 "^due:" "$f" 2>/dev/null | sed 's/due: *//' || echo "none")
    priority=$(grep -m1 "^priority:" "$f" 2>/dev/null | sed 's/priority: *//' || echo "none")
    ACTION_LIST="$ACTION_LIST
- $name | status: $status | due: $due | priority: $priority"
done

# Always load: beliefs
BELIEFS=""
if [ -d "Canon/Beliefs" ]; then
    BELIEFS=$(find Canon/Beliefs/ -name "*.md" -type f 2>/dev/null | while read f; do echo "=== $(basename "$f" .md) ==="; cat "$f"; echo; done)
fi

# Always load: style guide
STYLE_GUIDE=$(cat "$VAULT_DIR/Meta/style-guide.md" 2>/dev/null || echo "")

# Topic-matched: grep vault for related files
TOPIC_FILES=""
TOPIC_CONTEXT=""
# Extract keywords from query (remove stop words, take significant terms)
KEYWORDS=$(echo "$QUERY" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]/ /g' | tr ' ' '\n' | \
    grep -vE '^(should|i|the|a|an|is|it|my|me|do|to|for|and|or|but|in|on|at|of|with|this|that|what|how|why|when|where|who|which|would|could|can|will|have|has|had|be|am|are|was|were)$' | \
    grep -E '.{3,}' | head -5)

if [[ -n "$KEYWORDS" ]]; then
    while IFS= read -r kw; do
        [[ -z "$kw" ]] && continue
        # Search across Canon and Thinking directories for relevant files
        MATCHES=$(grep -rl -i "$kw" Canon/ Thinking/ 2>/dev/null | head -5)
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            # Avoid duplicates
            if [[ "$TOPIC_FILES" != *"$match"* ]]; then
                TOPIC_FILES="$TOPIC_FILES $match"
            fi
        done <<< "$MATCHES"
    done <<< "$KEYWORDS"

    # Load matched files (cap at ~10 to stay within token budget)
    FILE_COUNT=0
    for f in $TOPIC_FILES; do
        [[ $FILE_COUNT -ge 10 ]] && break
        [[ -f "$f" ]] || continue
        TOPIC_CONTEXT="$TOPIC_CONTEXT
=== $(basename "$f" .md) ($f) ===
$(head -60 "$f")
"
        FILE_COUNT=$((FILE_COUNT + 1))
    done
fi

# ── Mode-specific prompt ──────────────────────────────────────────────
if [[ "$MODE" == "ask" ]]; then
    MODE_INSTRUCTION="This is a QUICK /ask question. Your response MUST be 150 words or fewer. Be direct, reference specific vault notes, no bullet lists longer than 5 items."
else
    MODE_INSTRUCTION="This is a DEEP /strategy analysis. No word limit, but stay structured. Use headers. Reference vault notes extensively. Provide concrete recommendations grounded in vault data."
fi

# ── Build prompt ──────────────────────────────────────────────────────
PROMPT="You are the ADVISOR agent for this Obsidian vault. You are Usman's strategic brain — a strategy/life/business consultant who has read the entire vault.

## VAULT RULES (from CLAUDE.md)
$CLAUDE_RULES

## YOUR SPEC
$ADVISOR_SPEC

## YOUR KNOWLEDGE ABOUT USMAN (persistent memory — read carefully)
$KNOWLEDGE

## STYLE GUIDE
$STYLE_GUIDE

## MODE
$MODE_INSTRUCTION

## QUERY
$QUERY

## ALL ACTIONS (name | status | due | priority)
$ACTION_LIST

## BELIEFS
$BELIEFS

## DECISIONS SUMMARY
$DECISIONS_SUMMARY

## TOPIC-MATCHED VAULT CONTEXT
$TOPIC_CONTEXT

## SESSION HISTORY (if continuing a conversation)
$SESSION_CONTEXT

## OUTPUT FORMAT (MANDATORY)

You MUST wrap your output in these exact delimiters:

---RESPONSE---
Your response here. Reference [[specific notes]] by name. Use Usman's own language.
Never say 'your goals' — say 'your [[Increase Income]] action (due Sep 1)'.
---TRIGGERS---
Zero or more trigger lines, one per line. Only include if genuinely needed.
RESEARCH: <topic needing web research>
DECOMPOSE: <path to action file needing breakdown>
LOG_DECISION: <title> | <decided> | <why> | <rejected> | <check_later>
CREATE_ACTION: <name> | <priority> | <due> | <output>
EXTRACT: <file path to run extractor on>
UPDATE_KNOWLEDGE: <section name> | <new learning to append>
---END---

If no triggers are needed, still include the delimiters with an empty TRIGGERS section.
Do NOT put delimiters inside code blocks."

# ── Call LLM (routed via invoke-agent.sh) ─────────────────────────────
echo "[$TIMESTAMP] Calling LLM (mode=$MODE)..." >&2

RAW_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" ADVISOR "$PROMPT" "$MODE" 2>/dev/null)
CLAUDE_EXIT=$?

if [[ $CLAUDE_EXIT -ne 0 || -z "$RAW_OUTPUT" ]]; then
    notify_failure "LLM error (exit=$CLAUDE_EXIT)"
    echo "Error: LLM call failed with exit code $CLAUDE_EXIT" >&2
    exit 1
fi

# ── Parse output ──────────────────────────────────────────────────────
PARSED=$(echo "$RAW_OUTPUT" | python3 "$SCRIPT_DIR/parse-advisor-output.py")
PARSE_EXIT=$?

if [[ $PARSE_EXIT -ne 0 || -z "$PARSED" ]]; then
    # Fallback: treat entire output as response
    echo "$RAW_OUTPUT"
    RESPONSE="$RAW_OUTPUT"
    TRIGGERS="[]"
else
    RESPONSE=$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['response'])")
    TRIGGERS=$(echo "$PARSED" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['triggers']))")
fi

# ── Return response to caller ─────────────────────────────────────────
echo ""
echo "$RESPONSE"
echo ""

# ── Write session file ────────────────────────────────────────────────
if [[ -f "$SESSION_FILE" ]]; then
    # Append to existing session
    cat >> "$SESSION_FILE" << SESSIONEOF

---

**Query ($DATETIME):** $QUERY
**Mode:** $MODE

## Response

$RESPONSE

## Triggers

$(echo "$TRIGGERS" | python3 -c "
import sys, json
triggers = json.load(sys.stdin)
for t in triggers:
    print(f\"- {t['type']}: {t['value']}\")
if not triggers:
    print('None')
" 2>/dev/null || echo "None")
SESSIONEOF
else
    # Create new session file
    cat > "$SESSION_FILE" << SESSIONEOF
---
type: advisor-session
created: $DATETIME
mode: $MODE
query: "$QUERY"
session_id: $SESSION_ID
source: ai-generated
source_agent: Advisor
source_date: $DATETIME
---

# Advisor Session — $DATE

**Query:** $QUERY
**Mode:** $MODE

## Response

$RESPONSE

## Triggers

$(echo "$TRIGGERS" | python3 -c "
import sys, json
triggers = json.load(sys.stdin)
for t in triggers:
    print(f\"- {t['type']}: {t['value']}\")
if not triggers:
    print('None')
" 2>/dev/null || echo "None")
SESSIONEOF
fi

# ── Execute triggers ──────────────────────────────────────────────────
echo "[$TIMESTAMP] Processing triggers..." >&2

echo "$TRIGGERS" | python3 -c "
import sys, json
triggers = json.load(sys.stdin)
for t in triggers:
    print(f\"{t['type']}|{t['value']}\")
" 2>/dev/null | while IFS='|' read -r TRIG_TYPE TRIG_VALUE; do
    [[ -z "$TRIG_TYPE" ]] && continue

    case "$TRIG_TYPE" in
        RESEARCH)
            echo "  -> Triggering Researcher: $TRIG_VALUE" >&2
            nohup /bin/bash "$SCRIPT_DIR/run-researcher.sh" "$TRIG_VALUE" > /dev/null 2>&1 &
            ;;

        DECOMPOSE)
            echo "  -> Triggering Task-Enricher --decompose: $TRIG_VALUE" >&2
            nohup /bin/bash "$SCRIPT_DIR/run-task-enricher.sh" --decompose "$TRIG_VALUE" > /dev/null 2>&1 &
            ;;

        LOG_DECISION)
            echo "  -> Logging decision: $TRIG_VALUE" >&2
            # Parse: title | decided | why | rejected | check_later
            IFS='|' read -r D_TITLE D_DECIDED D_WHY D_REJECTED D_CHECK <<< "$TRIG_VALUE"
            D_TITLE=$(echo "$D_TITLE" | xargs)
            D_DECIDED=$(echo "$D_DECIDED" | xargs)
            D_WHY=$(echo "$D_WHY" | xargs)
            D_REJECTED=$(echo "$D_REJECTED" | xargs)
            D_CHECK=$(echo "$D_CHECK" | xargs)

            # Acquire lock briefly for write operation
            (
                source "$SCRIPT_DIR/lib-agent.sh"
                agent_acquire_lock "vault-agent-pipeline" 60
                "$SCRIPT_DIR/log-decision.sh" \
                    "${D_TITLE:-Untitled}" \
                    "${D_DECIDED:-No decision recorded}" \
                    "${D_WHY:-No rationale recorded}" \
                    "${D_REJECTED:-None considered}" \
                    "${D_CHECK:-N/A}" \
                    "Advisor session $SESSION_ID"
            )
            ;;

        CREATE_ACTION)
            echo "  -> Creating action: $TRIG_VALUE" >&2
            # Parse: name | priority | due | output
            IFS='|' read -r A_NAME A_PRIORITY A_DUE A_OUTPUT <<< "$TRIG_VALUE"
            A_NAME=$(echo "$A_NAME" | xargs)
            A_PRIORITY=$(echo "$A_PRIORITY" | xargs)
            A_DUE=$(echo "$A_DUE" | xargs)
            A_OUTPUT=$(echo "$A_OUTPUT" | xargs)

            # Sanitize filename
            A_FILENAME=$(echo "$A_NAME" | sed 's/[^a-zA-Z0-9 _-]//g' | sed 's/  */ /g')
            A_FILE="$VAULT_DIR/Canon/Actions/${A_FILENAME}.md"

            if [[ -f "$A_FILE" ]]; then
                echo "  -> Action already exists: $A_FILE (skipping)" >&2
                continue
            fi

            # Acquire lock briefly for write operation
            (
                source "$SCRIPT_DIR/lib-agent.sh"
                agent_acquire_lock "vault-agent-pipeline" 60

                cat > "$A_FILE" << ACTIONEOF
---
type: action
name: $A_NAME
status: open
priority: ${A_PRIORITY:-medium}
source: ai-generated
source_agent: Advisor
source_date: $DATETIME
first_mentioned: $DATE
due: ${A_DUE:-}
owner: "[[Usman Kotwal]]"
output: "${A_OUTPUT:-}"
mentions:
  - $DATE - Advisor session $SESSION_ID
linked: []
---

# 🎯 $A_NAME

Created by the Advisor agent during a $MODE session.

**Query that triggered this:** $QUERY
ACTIONEOF

                agent_stage_and_commit "[Advisor] create action: $A_NAME" "$A_FILE" >&2 2>&1
            )
            ;;

        EXTRACT)
            echo "  -> Triggering Extractor: $TRIG_VALUE" >&2
            nohup /bin/bash "$SCRIPT_DIR/run-extractor.sh" "$TRIG_VALUE" > /dev/null 2>&1 &
            ;;

        UPDATE_KNOWLEDGE)
            echo "  -> Updating knowledge: $TRIG_VALUE" >&2
            # Handled via Python to avoid quote injection
            python3 -c "
import sys, os
sys.path.insert(0, '$SCRIPT_DIR')
from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location('parser', '$SCRIPT_DIR/parse-advisor-output.py')
mod = module_from_spec(spec)
spec.loader.exec_module(mod)
mod.handle_update_knowledge(sys.argv[1], '$VAULT_DIR')
" "$TRIG_VALUE" 2>/dev/null || true
            ;;

        *)
            echo "  -> Unknown trigger type: $TRIG_TYPE" >&2
            ;;
    esac
done

# ── Commit session file (all output to stderr — stdout is reserved for response) ──
agent_stage_and_commit "[Advisor] session: $MODE — $DATE-$SESSION_ID" \
    "$SESSION_FILE" >&2 2>&1

# ── Log to changelog ──────────────────────────────────────────────────
"$SCRIPT_DIR/log-change.sh" "Advisor" "$MODE session: \"$QUERY\" (session $SESSION_ID)" >&2 2>&1
agent_commit_changelog_if_needed "[Advisor] log: changelog update [$TIMESTAMP]" >&2 2>&1

# ── Log to agent feedback queue ───────────────────────────────────────
"$SCRIPT_DIR/log-agent-feedback.sh" \
    "Advisor" \
    "advisor_${MODE}_complete" \
    "Advisor $MODE session: $(echo "$QUERY" | head -c 80)" \
    "$SESSION_FILE" \
    "" \
    "false" 2>/dev/null || true

# ── Heartbeat ─────────────────────────────────────────────────────────
mkdir -p "$HOME/.vault/heartbeats"
date +%s > "$HOME/.vault/heartbeats/advisor"

echo "[$TIMESTAMP] Advisor complete. Session: $SESSION_ID" >&2
