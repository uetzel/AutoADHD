#!/bin/bash
# run-email-workflow.sh — Draft an email from a Canon/Action
#
# Usage: ./run-email-workflow.sh "Follow up with Moyo"
#   or:  ./run-email-workflow.sh "Canon/Actions/Follow Up with Moyo.md"
#
# Flow:
#   1. Find the action (fuzzy match by name)
#   2. Find linked person(s) and their email
#   3. Read style guide
#   4. Call Claude CLI to draft the email in Usman's voice
#   5. Write operation file to Meta/operations/pending/
#   6. Telegram notification fires automatically (vault-bot.py watches pending/)
#
# Exit codes:
#   0 = draft created in pending/
#   1 = action not found
#   2 = no linked person with email
#   3 = Claude CLI draft failed
#   4 = missing dependencies

set -uo pipefail
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/lib-agent.sh" 2>/dev/null || true

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DATE=$(date +%Y-%m-%d)

# --- Args ---
ACTION_QUERY="${1:-}"
DRY_RUN="${2:-}"  # pass "dry-run" as second arg to skip Claude CLI

if [ -z "$ACTION_QUERY" ]; then
    echo "Usage: $0 <action name or path> [dry-run]"
    echo "Example: $0 'Follow up with Moyo'"
    exit 1
fi

# --- Step 1: Find the action ---
ACTIONS_DIR="$VAULT_DIR/Canon/Actions"

if [ -f "$ACTION_QUERY" ]; then
    ACTION_PATH="$ACTION_QUERY"
elif [ -f "$ACTIONS_DIR/$ACTION_QUERY" ]; then
    ACTION_PATH="$ACTIONS_DIR/$ACTION_QUERY"
elif [ -f "$ACTIONS_DIR/${ACTION_QUERY}.md" ]; then
    ACTION_PATH="$ACTIONS_DIR/${ACTION_QUERY}.md"
else
    # Fuzzy match: find action whose filename contains the query (case-insensitive)
    ACTION_PATH=$(find "$ACTIONS_DIR" -name "*.md" -print0 2>/dev/null \
        | xargs -0 grep -li "^name:.*${ACTION_QUERY}" 2>/dev/null \
        | head -1)

    # Fallback: match filename
    if [ -z "$ACTION_PATH" ]; then
        ACTION_PATH=$(find "$ACTIONS_DIR" -iname "*${ACTION_QUERY}*" -name "*.md" 2>/dev/null | head -1)
    fi
fi

if [ -z "$ACTION_PATH" ] || [ ! -f "$ACTION_PATH" ]; then
    echo "ERROR: Could not find action matching '$ACTION_QUERY'"
    echo "Available actions:"
    ls "$ACTIONS_DIR/" | head -10
    exit 1
fi

ACTION_NAME=$(grep -m1 '^name:' "$ACTION_PATH" | sed 's/^name:[[:space:]]*//' | tr -d '"')
ACTION_OUTPUT=$(grep -m1 '^output:' "$ACTION_PATH" | sed 's/^output:[[:space:]]*//' | tr -d '"')
ACTION_STATUS=$(grep -m1 '^status:' "$ACTION_PATH" | sed 's/^status:[[:space:]]*//' | tr -d '"')
ACTION_BASENAME=$(basename "$ACTION_PATH")

echo "[$TIMESTAMP] Found action: $ACTION_NAME"
echo "  Status: $ACTION_STATUS"
echo "  Output: $ACTION_OUTPUT"

# --- Step 2: Find linked person with email ---
# Extract [[Person Name]] or [[Full Name|Alias]] from linked field
LINKED_PEOPLE=$(grep -A 50 '^linked:' "$ACTION_PATH" \
    | grep '^[[:space:]]*-' \
    | grep -oP '\[\[([^]|]+)' \
    | sed 's/\[\[//' \
    | grep -v "Usman Kotwal")

RECIPIENT_EMAIL=""
RECIPIENT_NAME=""
RECIPIENT_FILE=""
RECIPIENT_CONTEXT=""

while IFS= read -r person_name; do
    [ -z "$person_name" ] && continue
    PERSON_FILE="$VAULT_DIR/Canon/People/${person_name}.md"
    if [ -f "$PERSON_FILE" ]; then
        EMAIL=$(grep -m1 '^email:' "$PERSON_FILE" | sed 's/^email:[[:space:]]*//' | tr -d '"' | xargs)
        if [ -n "$EMAIL" ] && [ "$EMAIL" != "" ]; then
            RECIPIENT_EMAIL="$EMAIL"
            RECIPIENT_NAME="$person_name"
            RECIPIENT_FILE="$PERSON_FILE"
            # Grab first 500 chars of person entry for context
            RECIPIENT_CONTEXT=$(head -40 "$PERSON_FILE")
            break
        fi
    fi
done <<< "$LINKED_PEOPLE"

if [ -z "$RECIPIENT_EMAIL" ]; then
    # No email found — create a blocked operation asking for help
    OP_ID="email-blocked-${TIMESTAMP}"
    OP_FILE="$VAULT_DIR/Meta/operations/pending/${OP_ID}.md"

    PEOPLE_LIST=$(echo "$LINKED_PEOPLE" | tr '\n' ', ' | sed 's/,$//')
    [ -z "$PEOPLE_LIST" ] && PEOPLE_LIST="(no linked people found)"

    cat > "$OP_FILE" << BLOCKEDEOF
---
type: email
op_id: ${OP_ID}
name: "Email blocked: ${ACTION_NAME}"
status: blocked
source_action: "${ACTION_BASENAME}"
notify: true
created: ${DATE}
needs_human_input: true
---

# ⚠️ Email blocked — no recipient email found

I tried to draft an email for **${ACTION_NAME}** but couldn't find an email address.

**Linked people:** ${PEOPLE_LIST}

None of them have an \`email:\` field in their Canon entry.

**To unblock:** Reply with the email address, or add it to the person's Canon entry and re-run.
BLOCKEDEOF

    echo "BLOCKED: No linked person with email. Created blocked operation: $OP_ID"
    exit 2
fi

echo "  Recipient: $RECIPIENT_NAME <$RECIPIENT_EMAIL>"

# --- Step 3: Read style guide (first 80 lines for context) ---
STYLE_GUIDE=""
STYLE_FILE="$VAULT_DIR/Meta/style-guide.md"
if [ -f "$STYLE_FILE" ]; then
    STYLE_GUIDE=$(head -80 "$STYLE_FILE")
fi

# --- Step 4: Draft the email ---
# Read the full action file for context
ACTION_CONTENT=$(cat "$ACTION_PATH")

if [ "$DRY_RUN" = "dry-run" ]; then
    # In dry-run mode, generate a placeholder draft
    EMAIL_SUBJECT="Re: ${ACTION_NAME}"
    EMAIL_BODY="[DRY RUN — Claude CLI would draft this email]

To: ${RECIPIENT_NAME} <${RECIPIENT_EMAIL}>
Action: ${ACTION_NAME}
Output goal: ${ACTION_OUTPUT}

This is a dry-run placeholder. In production, Claude CLI drafts this in Usman's voice using the style guide and action context."
    echo "  Mode: DRY RUN (skipping Claude CLI)"
else
    # Call Claude CLI to draft the email
    DRAFT_PROMPT="You are drafting an email from Usman Kotwal to ${RECIPIENT_NAME}.

## Context
Here is the action that triggered this email:
${ACTION_CONTENT}

Here is what we know about the recipient:
${RECIPIENT_CONTEXT}

## Style
${STYLE_GUIDE}

## Instructions
- Write the email in Usman's voice (see style guide above)
- Keep it short — 3-8 sentences max
- Warm but purposeful. Not corporate.
- If the action involves a German-speaking person and the context is personal, write in German. Otherwise English.
- Output ONLY the email in this exact format:

SUBJECT: <one line>
---
<email body, no greeting line like 'Dear X' — just start naturally>
---"

    echo "  Drafting via LLM..."
    DRAFT_OUTPUT=$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" EMAIL_WORKFLOW "$DRAFT_PROMPT" 2>/dev/null) || true

    if [ -z "$DRAFT_OUTPUT" ]; then
        echo "ERROR: LLM returned empty draft"
        exit 3
    fi

    # Parse subject and body from output
    EMAIL_SUBJECT=$(echo "$DRAFT_OUTPUT" | grep -m1 '^SUBJECT:' | sed 's/^SUBJECT:[[:space:]]*//')
    EMAIL_BODY=$(echo "$DRAFT_OUTPUT" | sed -n '/^---$/,/^---$/p' | sed '1d;$d')

    # Fallback if parsing fails
    if [ -z "$EMAIL_SUBJECT" ]; then
        EMAIL_SUBJECT="Re: ${ACTION_NAME}"
    fi
    if [ -z "$EMAIL_BODY" ]; then
        EMAIL_BODY="$DRAFT_OUTPUT"
    fi
fi

# --- Step 5: Write operation file ---
OP_ID="email-${TIMESTAMP}"
OP_FILE="$VAULT_DIR/Meta/operations/pending/${OP_ID}.md"

mkdir -p "$VAULT_DIR/Meta/operations/pending"

cat > "$OP_FILE" << OPEOF
---
type: email
op_id: ${OP_ID}
name: "Email to ${RECIPIENT_NAME}: ${EMAIL_SUBJECT}"
status: pending
source_action: "${ACTION_BASENAME}"
notify: true
to: ${RECIPIENT_EMAIL}
subject: "${EMAIL_SUBJECT}"
created: ${DATE}
---

# 📧 Email Draft

**To:** ${RECIPIENT_NAME} <${RECIPIENT_EMAIL}>
**Subject:** ${EMAIL_SUBJECT}
**From action:** [[${ACTION_NAME}]]

---

${EMAIL_BODY}

---

*Draft generated by email workflow. Approve via Telegram or /approve ${OP_ID}*

## Email Body HTML

<html><body>
<div style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 600px; line-height: 1.6;">
$(echo "$EMAIL_BODY" | sed 's/$/<br>/')
</div>
</body></html>
OPEOF

echo ""
echo "✅ Operation created: $OP_ID"
echo "   File: $OP_FILE"
echo "   To: $RECIPIENT_NAME <$RECIPIENT_EMAIL>"
echo "   Subject: $EMAIL_SUBJECT"
echo ""
echo "Waiting for approval via Telegram or /approve $OP_ID"

"$SCRIPTS_DIR/log-agent-feedback.sh" "EmailWorkflow" "email_drafted" "Drafted email to $RECIPIENT_EMAIL re: $EMAIL_SUBJECT" "$OP_FILE" "" "true" 2>/dev/null || true

exit 0
