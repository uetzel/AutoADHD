#!/bin/bash
# launchd-wrapper.sh — Sets up the environment for vault agent scripts.
# Usage in plist: /bin/bash /path/to/launchd-wrapper.sh /path/to/actual-script.sh [args...]
#
# Why: macOS tags files created by managed apps (like Claude) with com.apple.provenance.
# launchd can't execute those files directly. This wrapper is a clean /bin/bash invocation
# that sources the target script, bypassing the provenance restriction.

export HOME="$HOME"
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
export VAULT_DIR="$HOME/VaultSandbox"

cd "$VAULT_DIR" || exit 1


SCRIPT="$1"
shift

if [ -f "$SCRIPT" ]; then
    source "$SCRIPT" "$@"
else
    echo "Error: script not found: $SCRIPT" >&2
    exit 1
fi
