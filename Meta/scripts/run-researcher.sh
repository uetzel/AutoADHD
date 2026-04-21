#!/bin/bash
# run-researcher.sh
# Multi-perspective research agent — runs on Codex with highest model
# Usage: ./run-researcher.sh <action-note.md | topic-string>
#
# Phases:
#   0. Telegram notify (non-blocking)
#   1. Context gathering
#   2. Multi-perspective runs (3 lenses)
#   3. Synthesis pass
#   4. Verification pass (loop max 2x)
#   5. Write article to Thinking/Research/
#   6. Link back to source + notify

set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"

# macOS TCC fix: export so git (and subprocesses like Codex) can work
# without getcwd() in ~/Documents under launchd.
export GIT_DIR="$VAULT_DIR/.git"
export GIT_WORK_TREE="$VAULT_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATE_TODAY=$(date +%Y-%m-%d)
HEAD_BEFORE_RUN=$(git rev-parse HEAD)
CONFIG_FILE="${AGENT_RUNTIME_CONFIG:-$VAULT_DIR/Meta/agent-runtimes.conf}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Failure notification via Telegram
notify_failure() {
    "$SCRIPT_DIR/send-telegram.sh" "⚠️ *Researcher FAILED* at $(date '+%H:%M')
Reason: $1
Topic will be retried on next trigger." 2>/dev/null || true
}

echo "[$TIMESTAMP] Running Researcher agent..."

# --scan mode only reads action files and writes research articles.
# Allow dirty worktree since scan is safe (doesn't modify tracked files).
if [ "${1:-}" = "--scan" ]; then
    export VAULT_AGENT_ALLOW_DIRTY=1
fi

agent_require_commands git
agent_assert_clean_worktree "Researcher"
agent_acquire_lock "vault-researcher"

if [ "${VAULT_AGENT_CONTEXT:-}" = "voice-pipeline" ]; then
    echo "Researcher is disabled inside the voice pipeline context." >&2
    exit 1
fi

if [ "${RESEARCHER_WEB_RUNTIME_VERIFIED:-0}" != "1" ] && [ "${VAULT_RESEARCHER_WEB_RUNTIME_VERIFIED:-0}" != "1" ]; then
    echo "Researcher requires a runtime with verified web access. Set RESEARCHER_WEB_RUNTIME_VERIFIED=1 in Meta/agent-runtimes.conf after validating the runtime." >&2
    exit 1
fi

# --- Scan mode: find all actions with enrichment_status: needs-research ---
if [ "${1:-}" = "--scan" ]; then
    echo "[$TIMESTAMP] Scanning for actions with enrichment_status: needs-research..."
    FOUND=0
    for action_file in "$VAULT_DIR"/Canon/Actions/*.md; do
        [ -f "$action_file" ] || continue
        if grep -q "^enrichment_status:.*needs-research" "$action_file" 2>/dev/null; then
            FOUND=$((FOUND + 1))
            echo "  Found: $(basename "$action_file")"
            # Release lock before recursive call (each run acquires its own)
            agent_release_lock 2>/dev/null || true
            /bin/bash "$0" "$action_file" || {
                echo "  Research failed for: $(basename "$action_file")"
                continue
            }
            # Re-acquire lock for next iteration
            agent_acquire_lock "vault-researcher" 2>/dev/null || true
        fi
    done
    if [ "$FOUND" -eq 0 ]; then
        echo "[$TIMESTAMP] No actions need research. All clear."
    else
        echo "[$TIMESTAMP] Processed $FOUND research request(s)."
    fi
    agent_release_lock 2>/dev/null || true
    exit 0
fi

# --- Input ---
INPUT="${1:?Usage: run-researcher.sh <action-note.md | topic string | --scan>}"

# Determine if input is a file or a topic string
if [ -f "$INPUT" ]; then
    SOURCE_NOTE="$INPUT"
    TOPIC=$(grep -m1 "^name:" "$SOURCE_NOTE" | sed 's/^name: *//' || echo "$INPUT")
else
    SOURCE_NOTE=""
    TOPIC="$INPUT"
fi

# --- Phase 0: Telegram notify (non-blocking) ---
echo "Phase 0: Notifying via Telegram..."
"$SCRIPT_DIR/send-telegram.sh" "🔬 Researcher started: $TOPIC
⏳ Working... reply with any angle you want explored." 2>/dev/null || true

# Create pending question file for async Telegram reply
mkdir -p Meta/research/pending Meta/research/answers Meta/research/temp
RESEARCH_ID="research-${TIMESTAMP}"
cat > "Meta/research/pending/${RESEARCH_ID}.md" <<EOF
---
id: $RESEARCH_ID
topic: $TOPIC
source: ${SOURCE_NOTE:-direct request}
created: $DATE_TODAY
status: pending
---

What specific angle should this research take?
EOF

# Brief pause to allow a quick reply (but don't block)
sleep 5

# Check for Telegram reply
HUMAN_ANGLE=""
if [ -f "Meta/research/answers/${RESEARCH_ID}.md" ]; then
    HUMAN_ANGLE=$(cat "Meta/research/answers/${RESEARCH_ID}.md")
    echo "Got human input: $HUMAN_ANGLE"
fi

# --- Phase 1: Context gathering ---
echo "Phase 1: Gathering context..."

# Collect linked notes (1 hop)
LINKED_NOTE_PATHS=""
if [ -n "$SOURCE_NOTE" ]; then
    LINKS=$(grep -oE '\[\[[^\]]+\]\]' "$SOURCE_NOTE" 2>/dev/null | tr -d '[]' | head -10 || true)
    for link in $LINKS; do
        LINK_FILE=$(find Canon/ Thinking/ -name "${link}.md" -type f 2>/dev/null | head -1)
        if [ -n "$LINK_FILE" ] && [ -f "$LINK_FILE" ]; then
            LINKED_NOTE_PATHS="$LINKED_NOTE_PATHS
$LINK_FILE"
        fi
    done
fi

# --- Phase 2: Multi-perspective runs ---
echo "Phase 2: Running perspective agents..."

RESEARCH_BRIEF="## Research Brief
- Topic: $TOPIC
- Source note path: ${SOURCE_NOTE:-direct request}
- Human direction: ${HUMAN_ANGLE:-No specific angle requested. Use your best judgment based on context.}

## Context Files To Read
$LINKED_NOTE_PATHS
"

# Perspective prompts — the Researcher selects appropriate lenses
# We run a selector pass first to pick the right 3 perspectives
SELECTOR_PROMPT="You are selecting research perspectives for a multi-lens research task.

Topic: $TOPIC
Source note path: ${SOURCE_NOTE:-direct request}

Based on the topic, select exactly 3 perspective lenses. Always include a Contrarian.

For business/strategy: Customer-First (Bezos), Strategist (Roger Martin), Contrarian
For personal/life: Practical Expert, Philosopher, Contrarian
For technical/build: Builder, Analyst, Contrarian

If the human requested specific perspectives, use those (but keep Contrarian).
Human input: ${HUMAN_ANGLE:-none}

Output ONLY three lines, each formatted exactly as:
PERSPECTIVE_NAME|EMOJI|SYSTEM_PROMPT_CORE

Example:
Customer-First (Bezos)|🎯|What does the customer actually need? Work backwards from their problem.
Strategist (Roger Martin)|🧠|Where's the real choice? What are you choosing NOT to do?
Contrarian|🔥|Why is this wrong? What's the strongest argument against?
"

PERSPECTIVES_RAW=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$SELECTOR_PROMPT" 2>/dev/null || echo "Customer-First (Bezos)|🎯|What does the customer actually need?
Strategist (Roger Martin)|🧠|Where is the real choice?
Contrarian|🔥|Why is this wrong?")

# Parse perspectives and run each one
PERSPECTIVE_COUNT=0
while IFS='|' read -r PNAME PEMOJI PPROMPT; do
    PERSPECTIVE_COUNT=$((PERSPECTIVE_COUNT + 1))
    echo "  Running perspective $PERSPECTIVE_COUNT: $PNAME..."

    PERSPECTIVE_PROMPT="You are a research analyst with this specific lens:
**$PNAME** $PEMOJI — $PPROMPT

$RESEARCH_BRIEF

## Your Task
Read CLAUDE.md, Meta/Agents/Researcher.md, the source note if provided, and the listed context files before you answer.
Research this topic thoroughly from your specific perspective. Use web search to find real data, examples, and evidence.

## Output Format (write EXACTLY this structure):

# Perspective: $PNAME $PEMOJI

## Key Findings
[3-5 bullet points — the core insights from this angle]

## Evidence
[Sources, data points, examples — with URLs where available]

## Recommendation
[One-sentence recommendation from this perspective]

## Confidence
[high | medium | low] — and why
"

    if RESULT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$PERSPECTIVE_PROMPT" 2>&1); then
        echo "$RESULT" > "Meta/research/temp/${RESEARCH_ID}-perspective-${PERSPECTIVE_COUNT}.md"
    else
        echo "# Perspective: $PNAME $PEMOJI
## Key Findings
- Research run failed. Using available context only.
## Confidence
low — automated research failed" > "Meta/research/temp/${RESEARCH_ID}-perspective-${PERSPECTIVE_COUNT}.md"
    fi
done < <(echo "$PERSPECTIVES_RAW" | grep '|' | head -3)

echo "Ran $PERSPECTIVE_COUNT perspective(s)."

# Wait a moment, then check for late Telegram reply before synthesis
sleep 3
if [ -z "$HUMAN_ANGLE" ] && [ -f "Meta/research/answers/${RESEARCH_ID}.md" ]; then
    HUMAN_ANGLE=$(cat "Meta/research/answers/${RESEARCH_ID}.md")
    echo "Got late human input: $HUMAN_ANGLE"
fi

# --- Phase 3: Synthesis pass ---
echo "Phase 3: Synthesizing perspectives..."

# Gather all perspective outputs
ALL_PERSPECTIVES=""
for pfile in Meta/research/temp/${RESEARCH_ID}-perspective-*.md; do
    [ -f "$pfile" ] && ALL_PERSPECTIVES="$ALL_PERSPECTIVES
$(cat "$pfile")

---
"
done

SOURCE_NOTE_INSTRUCTION="No source note file was provided. Work from the topic only."
if [ -n "$SOURCE_NOTE" ]; then
    SOURCE_NOTE_INSTRUCTION="Read the source note at: $SOURCE_NOTE"
fi

SYNTHESIS_PROMPT="You are the RESEARCHER agent for this Obsidian vault.

## STEP 1: Read these files in order
1. Read CLAUDE.md
2. Read Meta/Agents/Researcher.md
3. $SOURCE_NOTE_INSTRUCTION

## STEP 2: Read supporting context
- Read these linked notes if they exist:
$LINKED_NOTE_PATHS
- Read up to 5 belief notes with: find Thinking/ -name '*.md' -exec grep -l 'type: belief' {} + | head -5

## Research Brief
- Topic: $TOPIC
- Human direction: ${HUMAN_ANGLE:-No specific angle requested. Use your best judgment based on context.}

## Late Human Input
${HUMAN_ANGLE:-none}

## Perspective Outputs
$ALL_PERSPECTIVES

## Your Task
Synthesize these perspectives into a single research article. Follow the article format from Meta/Agents/Researcher.md exactly.

Key rules:
- Find where perspectives AGREE (likely true)
- Find where they DISAGREE (present the tension — don't resolve artificially)
- Surface NON-OBVIOUS connections
- Write a CLEAR recommendation but flag its assumptions
- Add emoji prefix to the H1 heading: 🔬
- Use wikilinks to connect to vault notes where relevant
- Include proper frontmatter as specified in the spec
- Set triggered_by to: ${SOURCE_NOTE:-direct request}
- Date: $DATE_TODAY
- Output ONLY the final article markdown. No CLI transcript, no commentary, no fences.

## HARD BOUNDARY
You may modify ONLY:
- Thinking/Research/
- Meta/research/
- a triggering action note or Canon action note if adding a research link
- Meta/changelog.md

You must NOT create or edit:
- Meta/Agents/
- Meta/scripts/
- CLAUDE.md
- HOME.md
- AGENTS.md
- Meta/Architecture.md
- Meta/agent-runtimes.conf
- Inbox/
- Canon/ except the triggering action note when adding a research link

Write the COMPLETE article content. This will be saved directly as a markdown file."

ARTICLE_FILENAME="$DATE_TODAY - $TOPIC"
# Sanitize filename
ARTICLE_FILENAME=$(echo "$ARTICLE_FILENAME" | sed 's/[\/\\:*?"<>|]/-/g' | head -c 200)

mkdir -p "Thinking/Research"

if SYNTHESIS_RESULT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$SYNTHESIS_PROMPT" 2>&1); then
    CLEAN_SYNTHESIS="$(agent_extract_after_marker '---' "$SYNTHESIS_RESULT")"
    if [ -z "$CLEAN_SYNTHESIS" ]; then
        CLEAN_SYNTHESIS="$SYNTHESIS_RESULT"
    fi
    echo "$CLEAN_SYNTHESIS" > "Thinking/Research/${ARTICLE_FILENAME}.md"
else
    notify_failure "Synthesis pass failed"
    agent_release_lock
    exit 1
fi

# --- Phase 4: Verification pass ---
echo "Phase 4: Verifying research..."

VERIFICATION_PROMPT="You are fact-checking and verifying a research article.

Read CLAUDE.md first. Use direct web checks for unstable facts and prefer primary sources.

## Article to verify:
$(cat "Thinking/Research/${ARTICLE_FILENAME}.md")

## Your Task
1. Check if cited facts are plausible (web search key claims)
2. Identify obvious gaps the perspectives missed
3. Check if recommendations are internally consistent
4. Flag anything that contradicts these vault beliefs:
Run: find Thinking/ -name '*.md' -exec grep -l 'type: belief' {} + | head -5 and read those files if needed.

Output ONE of:
PASS — the article is solid, no critical gaps
MINOR_ISSUES — [list issues to note but not block on]
CRITICAL_GAPS — [list specific gaps that need another research pass]

Then output the corrected article if any changes were needed. If PASS, just output PASS."

VERIFY_RESULT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$VERIFICATION_PROMPT" 2>&1 || echo "PASS")

# Check if critical gaps need a loop
LOOP_COUNT=0
MAX_LOOPS=2
while echo "$VERIFY_RESULT" | grep -q "CRITICAL_GAPS" && [ $LOOP_COUNT -lt $MAX_LOOPS ]; do
    LOOP_COUNT=$((LOOP_COUNT + 1))
    echo "Verification found critical gaps. Loop $LOOP_COUNT/$MAX_LOOPS..."

    # Extract gaps and re-research
    GAPS=$(echo "$VERIFY_RESULT" | sed -n '/CRITICAL_GAPS/,/^$/p')

    GAP_PROMPT="You are filling research gaps identified during verification.

Read CLAUDE.md first. Use direct web checks and primary sources where possible.

## Original research:
$(cat "Thinking/Research/${ARTICLE_FILENAME}.md")

## Gaps to fill:
$GAPS

Research these specific gaps. Use web search. Then output an UPDATED version of the full article with gaps filled. Maintain the same format and frontmatter. Add any new sources to the Sources section."

    if GAP_RESULT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$GAP_PROMPT" 2>&1); then
        CLEAN_GAP_RESULT="$(agent_extract_after_marker '---' "$GAP_RESULT")"
        if [ -z "$CLEAN_GAP_RESULT" ]; then
            CLEAN_GAP_RESULT="$GAP_RESULT"
        fi
        echo "$CLEAN_GAP_RESULT" > "Thinking/Research/${ARTICLE_FILENAME}.md"
    fi

    # Re-verify
    VERIFY_RESULT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$VERIFICATION_PROMPT" 2>&1 || echo "PASS")
done

# If verification produced a corrected article (not just PASS), update
if ! echo "$VERIFY_RESULT" | grep -q "^PASS$"; then
    # Check if verification output contains article content (has frontmatter)
    if echo "$VERIFY_RESULT" | grep -q "^---"; then
        CLEAN_VERIFY_RESULT="$(agent_extract_after_marker '---' "$VERIFY_RESULT")"
        if [ -z "$CLEAN_VERIFY_RESULT" ]; then
            CLEAN_VERIFY_RESULT="$VERIFY_RESULT"
        fi
        echo "$CLEAN_VERIFY_RESULT" > "Thinking/Research/${ARTICLE_FILENAME}.md"
    fi
fi

# --- Phase 5: Link back ---
echo "Phase 5: Linking back to source..."

# Update source action with research link and flip enrichment_status
if [ -n "$SOURCE_NOTE" ] && [ -f "$SOURCE_NOTE" ]; then
    # Add research field to frontmatter if not present
    if ! grep -q "^research:" "$SOURCE_NOTE"; then
        sed -i '' "/^---$/,/^---$/{
            /^---$/b
            /^linked:/i\\
research: \"[[Thinking/Research/${ARTICLE_FILENAME}]]\"
        }" "$SOURCE_NOTE" 2>/dev/null || true
    fi

    # Flip enrichment_status so it doesn't get re-researched
    if grep -q "^enrichment_status:.*needs-research" "$SOURCE_NOTE" 2>/dev/null; then
        sed -i '' 's/^enrichment_status:.*needs-research/enrichment_status: researched/' "$SOURCE_NOTE" 2>/dev/null || true
    fi
fi

# --- Phase 5.5: Enrichment — scatter findings into the vault ---
echo "Phase 5.5: Enriching vault with research findings..."

ENRICHMENT_PROMPT="You are the RESEARCHER agent doing post-research enrichment for this Obsidian vault.

## STEP 1: Read these files
1. Read CLAUDE.md (vault rules)
2. Read .claude/skills/vault-writer/SKILL.md (note format rules)
3. Read the research article: Thinking/Research/${ARTICLE_FILENAME}.md
4. Read the source action: ${SOURCE_NOTE:-none}

## Your Task
The research article is done. Now scatter its findings into the vault so the knowledge is CONNECTED, not isolated. Do these things:

### A) Create a concept note in Thinking/
Create ONE concept note (type: concept) in Thinking/ that captures the core insight from this research in 10-15 lines. This is the distilled takeaway — the thing worth remembering even if the full article is never read again. Use wikilinks to connect to relevant vault notes.

Filename: the core concept name (e.g. 'VO2 Max as Health Proxy.md')
Frontmatter: type: concept, source: ai-generated, source_agent: Researcher, linked: [action, people, related notes]
Emoji heading: 💡

### B) Add a Findings section to the source action
If a source action file exists, append a ## Findings section with a 2-3 sentence summary of the research outcome. Also add a ## Evolution entry. Link to both the research article and the concept note.

### C) Add wikilinks to related notes
Search for existing Thinking/ and Canon/ notes that are related to this research topic. If you find notes that should link to the new concept or research article, add a wikilink. Only modify notes where the connection is clear and meaningful — don't spam links.

Run: find Thinking/ Canon/ -name '*.md' | head -80 to see what exists.

## Output Rules
- Follow CLAUDE.md and vault-writer skill format exactly
- Every new or modified file needs proper provenance comments
- Use emoji headings per the type table
- Don't create duplicate notes — check if a concept already exists first

## HARD BOUNDARY
You may ONLY create/modify:
- Thinking/ (new concept notes, wikilink additions)
- Canon/Actions/ (findings section on source action)
- Canon/Concepts/ (if concept belongs there)

You must NOT touch: Meta/Agents/, Meta/scripts/, CLAUDE.md, HOME.md, Inbox/"

if ENRICHMENT_RESULT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$ENRICHMENT_PROMPT" 2>&1); then
    echo "  Enrichment pass completed."
else
    echo "  Enrichment pass failed (non-fatal). Article is still saved."
fi

# --- Phase 6: Commit and notify ---
echo "Phase 6: Committing and notifying..."

if ! agent_assert_no_forbidden_commits "Researcher" "$HEAD_BEFORE_RUN" \
    Meta/Agents \
    Meta/scripts \
    CLAUDE.md \
    HOME.md \
    AGENTS.md \
    Meta/Architecture.md \
    Meta/agent-runtimes.conf \
    Inbox/; then
    notify_failure "forbidden control-file edits detected"
    exit 1
fi

agent_stage_and_commit "[Researcher] research: $TOPIC [$TIMESTAMP]" \
    "Thinking/Research/" \
    "Thinking/" \
    "Meta/research/" \
    Canon/Actions/ \
    Canon/Concepts/ \
    Canon/

# Clean up temp files
rm -f Meta/research/temp/${RESEARCH_ID}-perspective-*.md
rm -f Meta/research/pending/${RESEARCH_ID}.md

# Telegram notification
CONFIDENCE=$(grep -m1 "^confidence:" "Thinking/Research/${ARTICLE_FILENAME}.md" 2>/dev/null | sed 's/^confidence: *//' || echo "unknown")
"$SCRIPT_DIR/send-telegram.sh" "🔬✅ Research complete: $TOPIC
Confidence: $CONFIDENCE
📄 Thinking/Research/${ARTICLE_FILENAME}.md" 2>/dev/null || true

# Log to agent feedback queue
"$SCRIPT_DIR/log-agent-feedback.sh" \
    "Researcher" \
    "research_complete" \
    "Research complete: $TOPIC" \
    "" \
    "" \
    "true" 2>/dev/null || true

echo "[$TIMESTAMP] Researcher complete: Thinking/Research/${ARTICLE_FILENAME}.md"
