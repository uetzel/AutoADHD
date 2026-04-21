#!/bin/bash
# build-manifest.sh
# Auto-generates a vault manifest for fast AI navigation
# Run after any vault change, or as a git hook
# The manifest gives agents instant context without reading every file

set -euo pipefail
VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
unset PWD OLDPWD 2>/dev/null || true
cd "$VAULT_DIR"


MANIFEST="$VAULT_DIR/Meta/MANIFEST.md"
DATE=$(date +%Y-%m-%d)

{
    echo "---"
    echo "type: meta"
    echo "name: Vault Manifest"
    echo "updated: $DATE"
    echo "source: ai-generated"
    echo "---"
    echo ""
    echo "# Vault Manifest"
    echo ""
    echo "Auto-generated index of all Canon entries. Agents: read this FIRST for fast context."
    echo ""
    echo "## People ($(ls "$VAULT_DIR/Canon/People/" 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    for f in "$VAULT_DIR/Canon/People/"*.md; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .md)
        # Extract aliases if present (stop at next YAML key to avoid picking up tags/locked/linked)
        aliases=$(awk '/^aliases:/{found=1; next} found{if(/^[^ ]/) exit; if(/^ *- /){line=$0; sub(/^ *- */, "", line); gsub(/"/, "", line); printf "%s,", line}}' "$f" 2>/dev/null | sed 's/,$//' || true)
        if [ -n "$aliases" ]; then
            echo "- [[${name}]] (aka: ${aliases})"
        else
            echo "- [[${name}]]"
        fi
    done
    echo ""
    echo "## Events ($(ls "$VAULT_DIR/Canon/Events/" 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    for f in "$VAULT_DIR/Canon/Events/"*.md; do
        [ -f "$f" ] || continue
        echo "- [[$(basename "$f" .md)]]"
    done
    echo ""
    echo "## Concepts ($(ls "$VAULT_DIR/Canon/Concepts/" 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    for f in "$VAULT_DIR/Canon/Concepts/"*.md; do
        [ -f "$f" ] || continue
        echo "- [[$(basename "$f" .md)]]"
    done
    echo ""
    echo "## Decisions ($(ls "$VAULT_DIR/Canon/Decisions/" 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    for f in "$VAULT_DIR/Canon/Decisions/"*.md; do
        [ -f "$f" ] || continue
        echo "- [[$(basename "$f" .md)]]"
    done
    echo ""
    echo "## Projects ($(ls "$VAULT_DIR/Canon/Projects/" 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    for f in "$VAULT_DIR/Canon/Projects/"*.md; do
        [ -f "$f" ] || continue
        echo "- [[$(basename "$f" .md)]]"
    done
    echo ""
    echo "## Actions ($(ls "$VAULT_DIR/Canon/Actions/"*.md 2>/dev/null | wc -l | tr -d ' '))"
    echo ""
    for f in "$VAULT_DIR/Canon/Actions/"*.md; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .md)
        status=$(grep "^status:" "$f" 2>/dev/null | head -1 | sed 's/status: *//' || true)
        if [ -n "$status" ]; then
            echo "- [[${name}]] — ${status}"
        else
            echo "- [[${name}]]"
        fi
    done
    echo ""
    echo "## Recent Inbox (last 15)"
    echo ""
    { ls -t "$VAULT_DIR/Inbox/Voice/"*.md "$VAULT_DIR/Inbox/Voice/_extracted/"*.md 2>/dev/null || true; } | head -15 | while read f; do
        echo "- [[$(basename "$f" .md)]]"
    done
    echo ""
    echo "## AI Reflections"
    echo ""
    for f in "$VAULT_DIR/Meta/AI-Reflections/"*.md; do
        [ -f "$f" ] || continue
        echo "- [[$(basename "$f" .md)]]"
    done
} > "$MANIFEST"

echo "Manifest updated: $(date)"
