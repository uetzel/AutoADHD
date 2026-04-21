#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"
export PYTHONPYCACHEPREFIX="$ROOT_DIR/.tmp/pycache"
mkdir -p "$PYTHONPYCACHEPREFIX"

LINT_ONLY=0
if [ "${1:-}" = "--lint-only" ]; then
    LINT_ONLY=1
fi

echo "[ci-check] Running shell syntax checks..."
while IFS= read -r script; do
    bash -n "$script"
done < <(find Meta/scripts -maxdepth 1 -type f -name "*.sh" | sort)

echo "[ci-check] Smoke-testing Researcher runtime script syntax..."
bash -n Meta/scripts/check-researcher-runtime.sh

if command -v shellcheck >/dev/null 2>&1; then
    echo "[ci-check] Running shellcheck..."
    shellcheck Meta/scripts/*.sh
else
    echo "[ci-check] shellcheck not installed locally; skipping."
fi

echo "[ci-check] Running Python compile checks..."
python3 -m py_compile Meta/scripts/vault-bot.py

if [ "$LINT_ONLY" -eq 0 ]; then
    echo "[ci-check] Running Python tests..."
    python3 -m unittest discover -s tests -p 'test_*.py' -v
fi

echo "[ci-check] All checks passed."
