#!/bin/bash
# send-telegram.sh — Send a message to the vault owner via Telegram
# Usage: ./send-telegram.sh "Your message here"
#
# Reads token from VAULT_BOT_TOKEN env var or ~/.vault-bot-token
# Reads chat ID from VAULT_BOT_CHAT_ID env var or ~/.vault-bot-chat-id

MESSAGE="${1:?Usage: send-telegram.sh MESSAGE}"

# Load token
TOKEN="${VAULT_BOT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$HOME/.vault-bot-token" ]; then
    TOKEN=$(cat "$HOME/.vault-bot-token")
fi
if [ -z "$TOKEN" ]; then
    echo "No Telegram token found. Skipping send."
    exit 0
fi

# Load chat ID
CHAT_ID="${VAULT_BOT_CHAT_ID:-}"
if [ -z "$CHAT_ID" ] && [ -f "$HOME/.vault-bot-chat-id" ]; then
    CHAT_ID=$(cat "$HOME/.vault-bot-chat-id")
fi
if [ -z "$CHAT_ID" ]; then
    echo "No chat ID found. Run /start on the bot first."
    exit 0
fi

# Send via Telegram Bot API
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d text="$MESSAGE" \
    -d parse_mode="Markdown" \
    > /dev/null 2>&1

echo "Telegram message sent."
