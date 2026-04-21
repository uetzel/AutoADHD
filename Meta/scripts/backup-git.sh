#!/bin/bash
# Backs up .git directory to a separate location
# Run via launchd daily or before risky operations
# This is your "can't delete history" safety net

VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
BACKUP_DIR="$HOME/.vault-git-backup"
TIMESTAMP=$(date +%Y-%m-%d_%H%M)

cd "$VAULT_DIR" || exit 1


# Create backup dir if needed
mkdir -p "$BACKUP_DIR"

# Bundle the entire git repo into a single file (includes ALL history)
git bundle create "$BACKUP_DIR/vault-$TIMESTAMP.bundle" --all

# Keep only last 7 backups
ls -t "$BACKUP_DIR"/vault-*.bundle 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null

echo "✅ Git backup: $BACKUP_DIR/vault-$TIMESTAMP.bundle"
