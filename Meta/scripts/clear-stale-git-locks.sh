#!/bin/bash
# clear-stale-git-locks.sh
# Safely removes stale Git lock files when no live Git process is running.

set -euo pipefail

VAULT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$VAULT_DIR"


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib-agent.sh"

agent_clear_stale_git_locks || true
