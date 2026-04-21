#!/bin/bash
# calendar-create.sh — Create a Google Calendar event from an operation file
#
# Usage: ./calendar-create.sh <op-file.md>
#
# Reads the operation .md file, parses frontmatter for event details,
# and creates the event via Google Calendar API.
#
# Requires:
#   - ~/.vault-gcal-credentials.json (OAuth token for Google Calendar API)
#
# To set up credentials:
#   1. Create a Google Cloud project with Calendar API enabled
#   2. Create OAuth 2.0 credentials (Desktop app)
#   3. Run the initial auth flow to get a refresh token
#   4. Save credentials: ~/.vault-gcal-credentials.json
#   5. chmod 600 ~/.vault-gcal-credentials.json

set -euo pipefail
VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/lib-agent.sh" 2>/dev/null || true

OP_FILE="${1:-}"

if [ -z "$OP_FILE" ] || [ ! -f "$OP_FILE" ]; then
    echo "Usage: $0 <op-file.md>"
    echo "ERROR: Operation file not found: $OP_FILE"
    exit 1
fi

# --- Parse frontmatter from op file ---
SUBJECT=$(sed -n 's/^subject: *"\(.*\)"/\1/p' "$OP_FILE" | head -1)
WHEN=$(sed -n 's/^when: *"\(.*\)"/\1/p' "$OP_FILE" | head -1)
DURATION=$(sed -n 's/^duration: *\([0-9]*\)/\1/p' "$OP_FILE" | head -1)
ATTENDEES=$(sed -n 's/^attendees: *"\(.*\)"/\1/p' "$OP_FILE" | head -1)
OP_ID=$(sed -n 's/^op_id: *\(.*\)/\1/p' "$OP_FILE" | head -1)

# Extract description from ## Event Details section
DESCRIPTION=$(sed -n '/^## Event Details$/,/^---$/p' "$OP_FILE" | grep '^Description: ' | sed 's/^Description: //')

echo "[$OP_ID] Preparing calendar event..."
echo "  Subject: $SUBJECT"
echo "  When: $WHEN"
echo "  Duration: ${DURATION} minutes"
echo "  Attendees: $ATTENDEES"
echo "  Description: $DESCRIPTION"

# --- Check credentials ---
CREDS_FILE="$HOME/.vault-gcal-credentials.json"

if [ ! -f "$CREDS_FILE" ]; then
    echo ""
    echo "WARNING: Google Calendar API credentials not configured."
    echo "  Expected: $CREDS_FILE"
    echo ""
    echo "To set up:"
    echo "  1. Create a Google Cloud project with Calendar API enabled"
    echo "  2. Create OAuth 2.0 credentials (Desktop app type)"
    echo "  3. Run initial auth flow and save token to $CREDS_FILE"
    echo "  4. chmod 600 $CREDS_FILE"
    echo ""
    echo "Event NOT created. Credentials needed."
    exit 1
fi

# --- TODO: Replace this stub with actual Google Calendar API call ---
# The actual implementation would use the Google Calendar API via Python:
#
# SUBJECT="$SUBJECT" WHEN="$WHEN" DURATION="$DURATION" \
# ATTENDEES="$ATTENDEES" DESCRIPTION="$DESCRIPTION" \
# CREDS_FILE="$CREDS_FILE" \
# python3 << 'PYEOF'
# import os, json
# from datetime import datetime, timedelta
# from google.oauth2.credentials import Credentials
# from googleapiclient.discovery import build
#
# creds = Credentials.from_authorized_user_file(os.environ["CREDS_FILE"])
# service = build("calendar", "v3", credentials=creds)
#
# start = datetime.fromisoformat(os.environ["WHEN"])
# end = start + timedelta(minutes=int(os.environ["DURATION"]))
#
# event = {
#     "summary": os.environ["SUBJECT"],
#     "description": os.environ["DESCRIPTION"],
#     "start": {"dateTime": start.isoformat(), "timeZone": "Europe/Berlin"},
#     "end": {"dateTime": end.isoformat(), "timeZone": "Europe/Berlin"},
#     "attendees": [{"email": a.strip()} for a in os.environ["ATTENDEES"].split(",") if "@" in a],
# }
#
# result = service.events().insert(calendarId="primary", body=event).execute()
# print(f"Event created: {result.get('htmlLink')}")
# PYEOF

echo ""
echo "STUB: Would create Google Calendar event with the above details."
echo "Replace the TODO section in calendar-create.sh with actual API call when credentials are ready."
exit 0
