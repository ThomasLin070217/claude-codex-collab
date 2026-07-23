#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────┐
# │  codex-bridge.sh — Claude Code ↔ Codex CLI Bridge       │
# │  Zero dependencies. Bash is the only middleware.         │
# └──────────────────────────────────────────────────────────┘
set -euo pipefail

# ── Config ────────────────────────────────────────────────
COLLAB_DIR="$HOME/Agent/collab"
SPECS_DIR="$COLLAB_DIR/specs"
OUTPUT_DIR="$COLLAB_DIR/output"
REPORTS_DIR="$COLLAB_DIR/reports"
STATE_FILE="$COLLAB_DIR/state.json"

# ── Auto-detect Codex CLI ─────────────────────────────────
detect_codex() {
    # Priority: PATH → app bundle → homebrew → npm global
    if command -v codex &>/dev/null; then
        echo "codex"
    elif [ -f "/Applications/Codex.app/Contents/Resources/codex" ]; then
        echo "/Applications/Codex.app/Contents/Resources/codex"
    elif [ -f "/opt/homebrew/bin/codex" ]; then
        echo "/opt/homebrew/bin/codex"
    elif [ -f "$HOME/.npm-global/bin/codex" ]; then
        echo "$HOME/.npm-global/bin/codex"
    else
        echo ""
    fi
}

CODEX_BIN=$(detect_codex)

# ── Role Prompts ──────────────────────────────────────────
# Injected as system-level context shaping Codex's behavior.
# Kept short — long prompts burn tokens and confuse the model.

ARCHITECT_PROMPT="You are a skeptical code reviewer. Challenge every assumption. Find what could break, not what looks good. Be critical and specific. If the code has no real issues, say so briefly — don't invent problems."

ORACLE_PROMPT="You are a root-cause analyst. Form your own independent hypothesis before reading anyone else's analysis. Trace the evidence. Don't guess — follow the chain of causality. If you can't determine the cause with confidence, say what additional data you would need."

BUILDER_PROMPT="You are an independent implementation engineer. Follow the spec, but apply your own engineering judgment. If you find ambiguities, missing constraints, edge cases not covered, or a better approach — flag them before implementing. The spec represents one view; your fresh perspective matters. Write clean, tested, production-ready code."

SPEC_REVIEWER_PROMPT="You are reviewing a technical spec BEFORE implementation begins. Your job is to catch problems before any code is written. Read the spec and produce a structured implementation contract with exactly these sections:

Understanding: What you believe the task is (in your own words — this reveals misunderstandings).
Plan: Files/modules likely affected. Tests or checks you will run.
Risks: Ambiguities, missing constraints, hidden assumptions, spec gaps, conflicts with standard practice.
Decision: Exactly one of — proceed | needs_clarification | recommend_alternative

If you choose needs_clarification or recommend_alternative, explain exactly what clarification you need or what alternative you propose and why. Be concise. This contract is the gate between planning and implementation — if you approve a flawed spec, you will implement the wrong thing."

# ── Usage ─────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: codex-bridge.sh [--task-id <id>] <mode> <role> <prompt>

Modes:
  think     Read-only analysis & debate (sandbox read-only)
  build     Full implementation (sandbox danger-full-access)
  debug     Read-only root cause analysis (sandbox read-only)
  review    Read-only code review (sandbox read-only)

Options:
  --task-id <id>   Write per-task state to state/<id>.json

Roles:
  architect      Skeptical code reviewer (review mode)
  oracle         Root cause analyst (debug mode)
  builder        Independent implementer (build mode)
  spec-reviewer  Pre-implementation spec auditor (build mode, contract step)
  neutral        No role shaping (think mode)

Examples:
  codex-bridge.sh think neutral "Monorepo vs polyrepo for a TS project?"
  codex-bridge.sh review spec-reviewer "Review this spec before implementation: [spec]"
  codex-bridge.sh build builder "Implement rate limiter per spec at specs/task-001.md"
  codex-bridge.sh debug oracle "Users report intermittent 500 errors on /api/generate"
  codex-bridge.sh review architect "Review the diff in output/task-001.diff"
EOF
}

# ── Retry & Timeout ───────────────────────────────────────
MAX_RETRIES=${CODEX_MAX_RETRIES:-2}
RETRY_BASE_DELAY=${CODEX_RETRY_DELAY:-5}
CODEX_TIMEOUT=${CODEX_TIMEOUT:-600}

run_codex() {
    local attempt=1
    local output_file
    local exit_code=0

    output_file=$(mktemp /tmp/codex-bridge.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -f '$output_file'" RETURN

    while [ $attempt -le $MAX_RETRIES ]; do
        # Timeout via perl (no coreutils dependency, macOS native)
        perl -e 'alarm shift; exec @ARGV' "$CODEX_TIMEOUT" "$@" \
            > "$output_file" 2>&1 && exit_code=0 || exit_code=$?

        cat "$output_file"

        if [ $exit_code -eq 0 ]; then
            return 0
        fi

        # Don't retry on: auth failure, Codex not found, user interrupt
        if [ $exit_code -eq 126 ] || [ $exit_code -eq 127 ] || [ $exit_code -eq 130 ]; then
            return $exit_code
        fi

        if [ $attempt -lt $MAX_RETRIES ]; then
            local delay=$((RETRY_BASE_DELAY * (2 ** (attempt - 1))))
            echo "[codex-bridge] Attempt $attempt failed (exit $exit_code). Retrying in ${delay}s..." >&2
            sleep $delay
        fi
        attempt=$((attempt + 1))
    done

    echo "[codex-bridge] All $MAX_RETRIES attempts failed." >&2
    return $exit_code
}

# ── State Management ─────────────────────────────────────
STATE_DIR="$COLLAB_DIR/state"
mkdir -p "$STATE_DIR"

write_task_state() {
    local task_id="$1"
    local status="$2"
    local pid="${3:-0}"
    local verdict="${4:-}"
    local state_file="$STATE_DIR/${task_id}.json"

    cat > "$state_file" <<STATE
{
  "id": "$task_id",
  "status": "$status",
  "pid": $pid,
  "spec": "specs/${task_id}.md",
  "output": "output/${task_id}.txt",
  "contract": "output/${task_id}-contract.txt",
  "report": "reports/${task_id}-review.md",
  "started": "$(date -Iseconds)",
  "verdict": "$verdict"
}
STATE
}

# ── Main ──────────────────────────────────────────────────
main() {
    local task_id=""

    # Single-pass: extract --task-id, filter everything else
    local filtered=()
    local skip_next=false
    for arg in "$@"; do
        if $skip_next; then
            skip_next=false
            continue
        fi
        case "$arg" in
            --task-id=*) task_id="${arg#*=}" ;;
            --task-id) skip_next=true ;;
            *) filtered+=("$arg") ;;
        esac
    done

    local mode="${filtered[0]:-}"
    local role="${filtered[1]:-}"
    local prompt="${filtered[2]:-}"

    if [ -z "$mode" ] || [ -z "$prompt" ]; then
        usage
        exit 1
    fi

    # Guard: no Codex CLI found
    if [ -z "$CODEX_BIN" ]; then
        cat <<ERR
╔══════════════════════════════════════════════════════════╗
║  Codex CLI not found.                                    ║
║                                                          ║
║  Install options:                                        ║
║  1. npm install -g @openai/codex && codex login          ║
║  2. Download Codex app from openai.com/codex             ║
║                                                          ║
║  Then verify: codex --version                            ║
╚══════════════════════════════════════════════════════════╝
ERR
        exit 1
    fi

    # Force Codex to use ChatGPT subscription auth, not API key
    # This prevents silent billing if OPENAI_API_KEY is set in env
    unset OPENAI_API_KEY

    # Build the role-aware prompt
    local full_prompt="$prompt"
    case "$role" in
        architect)      full_prompt="$ARCHITECT_PROMPT

$prompt" ;;
        oracle)         full_prompt="$ORACLE_PROMPT

$prompt" ;;
        builder)        full_prompt="$BUILDER_PROMPT

$prompt" ;;
        spec-reviewer)  full_prompt="$SPEC_REVIEWER_PROMPT

$prompt" ;;
    esac

    # Dispatch by mode
    case "$mode" in
        think)
            # Sync read-only — Claude reads stdout directly
            # Write state if task-id provided
            [ -n "$task_id" ] && write_task_state "$task_id" "running" "$$" ""
            run_codex $CODEX_BIN exec -s read-only --skip-git-repo-check "$full_prompt"
            ;;
        debug)
            # Sync read-only — independent hypothesis formation
            [ -n "$task_id" ] && write_task_state "$task_id" "running" "$$" ""
            run_codex $CODEX_BIN exec -s read-only --skip-git-repo-check "$full_prompt"
            ;;
        review)
            # Sync read-only — code review
            [ -n "$task_id" ] && write_task_state "$task_id" "running" "$$" ""
            run_codex $CODEX_BIN exec -s read-only --skip-git-repo-check "$full_prompt"
            ;;
        build)
            # Full sandbox access — Codex can create, modify, run commands
            [ -n "$task_id" ] && write_task_state "$task_id" "running" "$$" ""
            run_codex $CODEX_BIN exec --sandbox danger-full-access --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$full_prompt"
            ;;
        *)
            echo "Unknown mode: $mode"
            usage
            exit 1
            ;;
    esac
}

main "$@"
