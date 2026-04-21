#!/bin/bash

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${AGENT_RUNTIME_CONFIG:-$VAULT_DIR/Meta/agent-runtimes.conf}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

RUNTIME="${RESEARCHER:-}"
if [ -z "$RUNTIME" ]; then
    echo "[researcher-check] RESEARCHER runtime not configured." >&2
    exit 1
fi

echo "[researcher-check] Configured runtime: $RUNTIME"

PROMPT="This is a live web-capability smoke test for the Researcher agent.

Use the web to visit https://example.com/ and reply with EXACTLY three lines:
WEB_OK
URL=https://example.com/
TITLE=Example Domain

Do not add any extra text."

OUTPUT="$(/bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$PROMPT" 2>&1 || true)"

echo "[researcher-check] Raw output:"
printf '%s\n' "$OUTPUT"

if printf '%s\n' "$OUTPUT" | grep -qx 'WEB_OK' \
    && printf '%s\n' "$OUTPUT" | grep -qx 'URL=https://example.com/' \
    && printf '%s\n' "$OUTPUT" | grep -qx 'TITLE=Example Domain'; then
    echo "[researcher-check] PASS: runtime returned the expected web result."
    exit 0
fi

echo "[researcher-check] FAIL: runtime did not return the expected web result." >&2
echo "[researcher-check] If this runtime is not truly web-capable, set RESEARCHER_WEB_RUNTIME_VERIFIED=0." >&2
exit 1
