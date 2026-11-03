#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────┐
# │  codex-bridge.sh — Claude Code ↔ Codex CLI Bridge (v2)   │
# │  v2: 集成 board.sh 黑板总线 · 结构化 verdict · 真状态机   │
# │  零依赖。Bash 是唯一中间件，文件系统是唯一状态。            │
# └──────────────────────────────────────────────────────────┘
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config ────────────────────────────────────────────────
COLLAB_DIR="${COLLAB_DIR:-$HOME/Agent/collab}"
SPECS_DIR="$COLLAB_DIR/specs"
OUTPUT_DIR="$COLLAB_DIR/output"
REPORTS_DIR="$COLLAB_DIR/reports"

# 引入黑板总线（同目录 board.sh）；缺失时降级为纯直连（不致命）。
if [ -f "$SCRIPT_DIR/board.sh" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/board.sh"
else
    echo "[codex-bridge] 未找到 board.sh，跳过总线集成（仅直连 Codex）" >&2
    board_write() { :; }
    board_state() { :; }
fi

# ── Auto-detect Codex CLI ─────────────────────────────────
detect_codex() {
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
# 注：v3 阶段将从 agents/<role>.md 名片卡读取，取代此处硬编码。
ARCHITECT_PROMPT="You are a skeptical code reviewer. Challenge every assumption. Find what could break, not what looks good. Be critical and specific. If the code has no real issues, say so briefly — don't invent problems."

ORACLE_PROMPT="You are a root-cause analyst. Form your own independent hypothesis before reading anyone else's analysis. Trace the evidence. Don't guess — follow the chain of causality. If you can't determine the cause with confidence, say what additional data you would need."

BUILDER_PROMPT="You are an independent implementation engineer. Follow the spec, but apply your own engineering judgment. If you find ambiguities, missing constraints, edge cases not covered, or a better approach — flag them before implementing. The spec represents one view; your fresh perspective matters. Write clean, tested, production-ready code.

When you finish, output a structured handoff as a single JSON code block (machine-read by the bridge, do not wrap it in prose):

\`\`\`json
{\"outcome\": \"<what was implemented, 1-2 lines>\", \"artifacts\": \"<files created/modified>\", \"risks\": \"<known limitations or risks>\", \"next\": \"<suggested next step for review>\"}
\`\`\`"

SPEC_REVIEWER_PROMPT="You are reviewing a technical spec BEFORE implementation begins. Your job is to catch problems before any code is written. Read the spec and produce a structured implementation contract with exactly these sections:

Understanding: What you believe the task is (in your own words — this reveals misunderstandings).
Plan: Files/modules likely affected. Tests or checks you will run.
Risks: Ambiguities, missing constraints, hidden assumptions, spec gaps, conflicts with standard practice.
Decision: Exactly one of — proceed | needs_clarification | recommend_alternative

If you choose needs_clarification or recommend_alternative, explain exactly what clarification you need or what alternative you propose and why. Be concise. This contract is the gate between planning and implementation — if you approve a flawed spec, you will implement the wrong thing.

At the very end, output your verdict as a single JSON code block (this is machine-read by the bridge, do not wrap it in prose):

\`\`\`json
{\"task\": \"<task_id>\", \"decision\": \"proceed|needs_clarification|recommend_alternative\", \"understanding\": \"<one line>\", \"risks\": [\"...\"], \"plan\": [\"...\"]}
\`\`\`"

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
  --task-id <id>   Write per-task state + bus message + save output

Roles:
  architect      Skeptical code reviewer (review mode)
  oracle         Root cause analyst (debug mode)
  builder        Independent implementer (build mode)
  spec-reviewer  Pre-implementation spec auditor (build mode, contract step)
  neutral        No role shaping (think mode)

Examples:
  codex-bridge.sh think neutral "Monorepo vs polyrepo for a TS project?"
  codex-bridge.sh review spec-reviewer "Read specs/task-1.md and produce a contract"
  codex-bridge.sh build builder "Implement spec at specs/task-1.md"
  codex-bridge.sh debug oracle "Users report intermittent 500 errors on /api/generate"
  codex-bridge.sh review architect "Review the diff at work/claude/diff.txt"
EOF
}

# ── Retry & Timeout ───────────────────────────────────────
MAX_RETRIES=${CODEX_MAX_RETRIES:-2}
RETRY_BASE_DELAY=${CODEX_RETRY_DELAY:-5}
CODEX_TIMEOUT=${CODEX_TIMEOUT:-600}

CODEX_PID=0
CODEX_STDOUT=""   # 供 verdict 提取使用

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
            > "$output_file" 2>&1 &
        CODEX_PID=$!
        wait "$CODEX_PID" && exit_code=0 || exit_code=$?

        CODEX_STDOUT=$(cat "$output_file")

        # 同步模式：回显到 stdout，供 Claude 直接读
        printf '%s\n' "$CODEX_STDOUT"

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

# ── Verdict 提取（结构化、机器可读） ──────────────────────
# 从 Codex stdout 里找 ```json 代码块，尽力提取 decision 字段。
extract_verdict() {
    local json
    json=$(printf '%s' "$CODEX_STDOUT" \
        | sed -n '/^```json[[:space:]]*$/,/^```[[:space:]]*$/p' \
        | sed '1d;$d' \
        | tr -d '\r')
    [ -z "$json" ] && { echo ""; return 0; }
    local decision
    decision=$(printf '%s' "$json" \
        | grep -o '"decision"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"decision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    echo "$decision"
}

# 从 Codex stdout 提取 ```json handoff 块，返回 JSON 文本（供写交接文件）。
extract_handoff_json() {
    printf '%s' "$CODEX_STDOUT" \
        | sed -n '/^```json[[:space:]]*$/,/^```[[:space:]]*$/p' \
        | sed '1d;$d' \
        | tr -d '\r'
}

# 从 JSON 里尽力提取单个字段值。
json_field() {
    local json="$1" key="$2"
    printf '%s' "$json" \
        | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/"
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
║  Install: npm install -g @openai/codex && codex login    ║
║  Or download Codex app from openai.com/codex             ║
╚══════════════════════════════════════════════════════════╝
ERR
        exit 1
    fi

    # Force Codex to use ChatGPT subscription auth, not API key
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

    # ── v2: 总线 + 状态机 ────────────────────────────────
    # 写一条总线消息（payload 走 ref，不走全文）
    board_write --from codex --to claude --type "$mode" --task "$task_id" \
        --summary "${prompt:0:120}" || true

    # 真状态机：启动写 running
    board_state "$task_id" running 2>/dev/null || true

    local sandbox="read-only"
    local codex_args=("$CODEX_BIN" exec -s read-only --skip-git-repo-check "$full_prompt")

    case "$mode" in
        think|debug|review)
            sandbox="read-only"
            ;;
        build)
            sandbox="danger-full-access"
            codex_args=("$CODEX_BIN" exec --sandbox danger-full-access --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$full_prompt")
            ;;
    esac

    run_codex "${codex_args[@]}"
    local rc=$?

    # 保存输出（供后续 review 读，避免 prompt 粘贴）
    if [ -n "$task_id" ]; then
        mkdir -p "$OUTPUT_DIR"
        printf '%s\n' "$CODEX_STDOUT" > "$OUTPUT_DIR/${task_id}.txt"
    fi

    # 提取结构化 verdict（spec-reviewer / architect 会输出 JSON）
    local verdict=""
    verdict=$(extract_verdict)

    # 提取结构化 handoff（builder 会输出 JSON），写交接文件（只回传结论）
    if [ -n "$task_id" ] && [ "$mode" = "build" ]; then
        local handoff_json
        handoff_json=$(extract_handoff_json)
        if [ -n "$handoff_json" ]; then
            board_handoff "$task_id" --from codex --status done \
                --outcome   "$(json_field "$handoff_json" outcome)" \
                --artifacts "$(json_field "$handoff_json" artifacts)" \
                --risks     "$(json_field "$handoff_json" risks)" \
                --next      "$(json_field "$handoff_json" next)" || true
        fi
    fi

    # 真状态机：退出写 done/failed + verdict + 真实 pid
    if [ $rc -eq 0 ]; then
        board_state "$task_id" done --verdict "$verdict" --pid "$CODEX_PID" 2>/dev/null || true
    else
        board_state "$task_id" failed --verdict "$verdict" --pid "$CODEX_PID" 2>/dev/null || true
    fi

    exit $rc
}

main "$@"
