#!/bin/bash
# invoke-agent.sh — Model-agnostic LLM invocation layer
#
# Usage: invoke-agent.sh AGENT_NAME PROMPT [MODE]
#
# Reads agent-runtimes.conf to determine which runtime(s) to use.
# Supports:
#   - Single runtime:    ADVISOR=claude
#   - Fallback chains:   ADVISOR=codex,claude  (try codex first, then claude)
#   - Per-mode override: ADVISOR_TRIAGE=claude  (overrides ADVISOR for triage mode)
#   - Provider drivers:  claude, codex (+ future: kimi, gemini, etc.)

set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/Library/Python/3.9/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
unset PWD OLDPWD 2>/dev/null || true
cd "$VAULT_DIR" || { echo "FATAL: cannot cd to $VAULT_DIR" >&2; exit 1; }
SCRIPT_DIR="$VAULT_DIR/Meta/scripts"
CONFIG_FILE="${AGENT_RUNTIME_CONFIG:-$VAULT_DIR/Meta/agent-runtimes.conf}"
TOKEN_LOG="$VAULT_DIR/Meta/agent-token-usage.jsonl"

# Log token usage after each agent call
_log_tokens() {
    local agent_name="$1" runtime="$2" json_output="$3"
    python3 -c "
import json, sys, datetime
try:
    d = json.loads(sys.argv[3])
    usage = d.get('usage', {})
    entry = {
        'ts': datetime.datetime.now().isoformat()[:19],
        'agent': sys.argv[1],
        'runtime': sys.argv[2],
        'input_tokens': usage.get('input_tokens', 0),
        'output_tokens': usage.get('output_tokens', 0),
        'cache_creation': usage.get('cache_creation_input_tokens', 0),
        'cache_read': usage.get('cache_read_input_tokens', 0),
        'cost_usd': d.get('total_cost_usd', 0),
        'duration_ms': d.get('duration_ms', 0),
        'num_turns': d.get('num_turns', 0),
    }
    with open(sys.argv[4], 'a') as f:
        f.write(json.dumps(entry) + '\n')
except Exception:
    pass  # never fail the agent for logging
" "$agent_name" "$runtime" "$json_output" "$TOKEN_LOG" 2>/dev/null || true
}
CODEX_BIN="${CODEX_BIN:-/Applications/Codex.app/Contents/Resources/codex}"
# Resolve claude binary: check PATH first, then find the versioned install location
if command -v claude >/dev/null 2>&1; then
    CLAUDE_BIN="${CLAUDE_BIN:-claude}"
else
    # Claude Code installs to a versioned directory under Application Support
    _CLAUDE_FOUND=$(find "$HOME/Library/Application Support/Claude/claude-code-vm" -name "claude" -type f 2>/dev/null | sort -V | tail -1)
    CLAUDE_BIN="${CLAUDE_BIN:-${_CLAUDE_FOUND:-claude}}"
fi

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 AGENT_NAME PROMPT [MODE]" >&2
    exit 1
fi

AGENT_NAME="$1"
PROMPT="$2"
AGENT_MODE="${3:-}"

# ── Load config ──────────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# ── Resolve runtime (mode-specific > agent-level > default) ──────────
agent_key="$(printf '%s' "$AGENT_NAME" | tr '[:lower:]-' '[:upper:]_')"
runtime_chain="${AGENT_RUNTIME:-}"

# Check mode-specific override first (e.g., ADVISOR_TRIAGE=claude)
if [ -z "$runtime_chain" ] && [ -n "$AGENT_MODE" ]; then
    mode_key="${agent_key}_$(printf '%s' "$AGENT_MODE" | tr '[:lower:]-' '[:upper:]_')"
    runtime_chain="$(eval "printf '%s' \"\${$mode_key:-}\"")"
fi

# Fall back to agent-level config (e.g., ADVISOR=codex,claude)
if [ -z "$runtime_chain" ]; then
    runtime_chain="$(eval "printf '%s' \"\${$agent_key:-}\"")"
fi

# Default to claude if nothing configured
if [ -z "$runtime_chain" ]; then
    runtime_chain="claude"
fi

# ── Provider driver: run a single provider, return exit code ─────────
# Provider format: "provider" or "provider:model" (e.g., "claude:opus", "claude:sonnet")
run_provider() {
    local provider_spec="$1"
    local prompt="$2"

    # Split provider:model
    local provider="${provider_spec%%:*}"
    local model=""
    if [[ "$provider_spec" == *:* ]]; then
        model="${provider_spec#*:}"
    fi

    case "$provider" in
        claude)
            if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
                echo "WARN: Claude CLI not found at $CLAUDE_BIN" >&2
                return 1
            fi
            # Two execution strategies for Claude CLI:
            #
            # Strategy 1 (preferred): Run from vault dir with Max/OAuth auth.
            #   → Free (covered by Max subscription). Works from interactive
            #   terminals and cron jobs with Full Disk Access.
            #
            # Strategy 2 (fallback): Run from /tmp with --bare + API key.
            #   → Uses API credits (~$0.20/extraction). Works under launchd
            #   where TCC blocks git discovery and OAuth doesn't initialize.
            #
            # Try strategy 1 first. If it fails (exit 128 = git/TCC, or
            # "Not logged in"), automatically fall back to strategy 2.

            # --- Build model args ---
            local model_args=""
            if [ -n "$model" ]; then
                local model_id=""
                case "$model" in
                    opus)   model_id="claude-opus-4-6" ;;
                    sonnet) model_id="claude-sonnet-4-6" ;;
                    haiku)  model_id="claude-haiku-4-5-20251001" ;;
                    *)      model_id="$model" ;;
                esac
                model_args="--model $model_id"
            fi

            # --- Strategy 1: Max/OAuth from vault dir ---
            local s1_exit=0
            local s1_output=""
            local s1_stderr_file
            s1_stderr_file=$(mktemp "/tmp/invoke-agent-stderr.XXXXXX")
            s1_output=$(
                unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true
                cd "$VAULT_DIR" 2>/dev/null || true
                "$CLAUDE_BIN" --dangerously-skip-permissions --output-format json $model_args -p "$prompt" 2>"$s1_stderr_file"
            ) || s1_exit=$?
            rm -f "$s1_stderr_file"

            if [ "$s1_exit" -eq 0 ]; then
                # Extract text result from JSON, log token usage
                local tmp_json
                tmp_json=$(mktemp "/tmp/invoke-agent-json.XXXXXX")
                printf '%s' "$s1_output" > "$tmp_json"
                local text_result=""
                text_result=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('result', ''))
" "$tmp_json" 2>/dev/null) || text_result="$s1_output"
                _log_tokens "$AGENT_NAME" "claude" "$s1_output"
                rm -f "$tmp_json"
                printf '%s\n' "$text_result"
                return 0
            fi

            # Check if failure is TCC/auth-related (worth retrying with --bare)
            if echo "$s1_output" | grep -qiE "not a git repository|not logged in|Operation not permitted"; then
                echo "INFO: Claude CLI OAuth failed (exit $s1_exit), falling back to --bare + API key" >&2
            else
                # Non-TCC failure (token limit, rate limit, etc.) — don't retry
                printf '%s\n' "$s1_output"
                return "$s1_exit"
            fi

            # --- Strategy 2: --bare + API key from /tmp ---
            local api_key=""
            if [ -f "$HOME/.anthropic/api_key" ]; then
                api_key="$(cat "$HOME/.anthropic/api_key" | tr -d '[:space:]')"
            fi
            if [ -z "$api_key" ]; then
                echo "WARN: No API key at ~/.anthropic/api_key — --bare fallback unavailable" >&2
                printf '%s\n' "$s1_output"
                return "$s1_exit"
            fi

            local full_prompt="IMPORTANT: The vault root is $VAULT_DIR — use absolute paths for all file operations (Read, Write, Bash, find, grep, cat, etc.).
For example: cat $VAULT_DIR/.claude/skills/vault-extractor/SKILL.md (not .claude/skills/...)
For example: find $VAULT_DIR/Canon/ -name '*.md' (not find Canon/)

$prompt"
            (
                unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true
                export ANTHROPIC_API_KEY="$api_key"
                cd /tmp 2>/dev/null || true
                exec "$CLAUDE_BIN" --bare --dangerously-skip-permissions \
                    --add-dir "$VAULT_DIR" \
                    --append-system-prompt-file "$VAULT_DIR/CLAUDE.md" \
                    $model_args -p "$full_prompt"
            )
            return $?
            ;;

        codex)
            if [ ! -x "$CODEX_BIN" ]; then
                echo "WARN: Codex not installed at $CODEX_BIN — skipping" >&2
                return 1
            fi
            # Write prompt to temp file instead of piping via stdin.
            # Under launchd, stdin pipes to Codex can stall/buffer indefinitely.
            CODEX_PROMPT_FILE=$(mktemp "/tmp/codex-invoke-prompt.XXXXXX")
            printf '%s' "$prompt" > "$CODEX_PROMPT_FILE"
            CODEX_STDERR=$(mktemp "/tmp/codex-invoke-stderr.XXXXXX")
            RAW_OUTPUT=$("$CODEX_BIN" exec --full-auto -C "$VAULT_DIR" "$CODEX_PROMPT_FILE" 2>"$CODEX_STDERR") || {
                if [ -s "$CODEX_STDERR" ]; then
                    cat "$CODEX_STDERR" >&2
                fi
                rm -f "$CODEX_STDERR" "$CODEX_PROMPT_FILE"
                echo "Codex CLI exited with error" >&2
                return 1
            }
            rm -f "$CODEX_STDERR" "$CODEX_PROMPT_FILE"
            # Extract content between "codex" marker and "tokens used"
            CLEAN_OUTPUT=$(printf '%s\n' "$RAW_OUTPUT" | awk '
                /^codex$/ { found=1; next }
                found && /^tokens used$/ { exit }
                found { print }
            ')
            if [ -n "$CLEAN_OUTPUT" ]; then
                printf '%s\n' "$CLEAN_OUTPUT"
            else
                printf '%s\n' "$RAW_OUTPUT"
            fi
            return 0
            ;;

        # ── Future providers (uncomment when CLI is available) ───────
        # kimi)
        #     if ! command -v kimi >/dev/null 2>&1; then
        #         echo "WARN: Kimi CLI not found — skipping" >&2
        #         return 1
        #     fi
        #     kimi -p "$prompt"
        #     return $?
        #     ;;
        #
        # gemini)
        #     if ! command -v gemini >/dev/null 2>&1; then
        #         echo "WARN: Gemini CLI not found — skipping" >&2
        #         return 1
        #     fi
        #     gemini -p "$prompt"
        #     return $?
        #     ;;

        *)
            echo "WARN: Unknown runtime '$provider' for $AGENT_NAME — skipping" >&2
            return 1
            ;;
    esac
}

# ── Execute fallback chain ───────────────────────────────────────────
# Split runtime_chain on commas and try each provider in order.
# First successful provider wins.
IFS=',' read -ra PROVIDERS <<< "$runtime_chain"

for provider in "${PROVIDERS[@]}"; do
    provider=$(echo "$provider" | xargs)  # trim whitespace
    [ -z "$provider" ] && continue

    if run_provider "$provider" "$PROMPT"; then
        exit 0
    fi

    echo "WARN: $provider failed for $AGENT_NAME — trying next in chain" >&2
done

echo "ERROR: All runtimes failed for $AGENT_NAME (chain: $runtime_chain)" >&2
exit 1
