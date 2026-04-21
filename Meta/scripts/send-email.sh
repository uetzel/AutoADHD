#!/bin/bash
# send-email.sh — sends an HTML email via Gmail SMTP
#
# Usage: ./send-email.sh <to_email> <subject> <html_file>
#
# Requires:
#   - ~/.vault-gmail-app-password (Gmail App Password, NOT your regular password)
#   - ~/.vault-owner-email (your Gmail address)
#
# To get an App Password:
#   1. Go to https://myaccount.google.com/security
#   2. Enable 2-Step Verification if not already on
#   3. Go to App Passwords → create one for "Mail"
#   4. Save it: echo "xxxx xxxx xxxx xxxx" > ~/.vault-gmail-app-password
#   5. chmod 600 ~/.vault-gmail-app-password

set -uo pipefail

TO="$1"
SUBJECT="$2"
HTML_SOURCE="$3"

if [ ! -f "$HTML_SOURCE" ]; then
    echo "ERROR: Source file not found: $HTML_SOURCE"
    exit 1
fi

# Support reading HTML from an op file with ## Email Body HTML section
# or from a standalone HTML file
HTML_FILE="$HTML_SOURCE"
if grep -q "^## Email Body HTML" "$HTML_SOURCE" 2>/dev/null; then
    # Extract HTML from op file into a temp file
    HTML_FILE=$(mktemp /tmp/vault-email-XXXXXX.html)
    sed -n '/^## Email Body HTML$/,$ { /^## Email Body HTML$/d; p; }' "$HTML_SOURCE" > "$HTML_FILE"
    trap "rm -f '$HTML_FILE'" EXIT
fi

# Load credentials
SENDER_EMAIL="${VAULT_OWNER_EMAIL:-}"
if [ -z "$SENDER_EMAIL" ] && [ -f "$HOME/.vault-owner-email" ]; then
    SENDER_EMAIL=$(cat "$HOME/.vault-owner-email")
fi

APP_PASSWORD=""
if [ -f "$HOME/.vault-gmail-app-password" ]; then
    APP_PASSWORD=$(cat "$HOME/.vault-gmail-app-password")
fi

if [ -z "$SENDER_EMAIL" ] || [ -z "$APP_PASSWORD" ]; then
    echo "ERROR: Missing credentials."
    echo "  - Email: ~/.vault-owner-email"
    echo "  - App Password: ~/.vault-gmail-app-password"
    exit 1
fi

# Send via Python smtplib — all values passed as env vars (no shell injection)
SENDER_EMAIL="$SENDER_EMAIL" \
APP_PASSWORD="$APP_PASSWORD" \
TO_EMAIL="$TO" \
EMAIL_SUBJECT="$SUBJECT" \
HTML_FILE="$HTML_FILE" \
python3 << 'PYEOF'
import os
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

sender = os.environ["SENDER_EMAIL"]
to = os.environ["TO_EMAIL"]
subject = os.environ["EMAIL_SUBJECT"]
app_password = os.environ["APP_PASSWORD"]
html_file = os.environ["HTML_FILE"]

with open(html_file, "r") as f:
    html_body = f.read()

msg = MIMEMultipart("alternative")
msg["Subject"] = subject
msg["From"] = f"Vault Briefing <{sender}>"
msg["To"] = to

plain = "Your vault briefing is ready. Open in a browser to see the full version."
msg.attach(MIMEText(plain, "plain"))
msg.attach(MIMEText(html_body, "html"))

with smtplib.SMTP_SSL("smtp.gmail.com", 465) as server:
    server.login(sender, app_password)
    server.sendmail(sender, [to], msg.as_string())

print(f"Email sent to {to}")
PYEOF
