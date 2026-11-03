#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  board.sh — 共享黑板总线 (v2)
#
#  把「文件白板（互读全文）」升级为：
#    · append-only 消息总线 + 每 agent 游标增量读
#    · 交接文件（只回传结论，过程隔离）
#    · 分层记忆（原始层 specs/ 永不改 + 语义层 memory/decisions.md）
#
#  零依赖：文件系统即状态。只用 mkdir/cat/echo/tail/rg/sed。
#  可作库 source，也可直接执行 `board.sh <command> ...`。
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── 目录布局 ──────────────────────────────────────────────────────
COLLAB_DIR="${COLLAB_DIR:-$HOME/Agent/collab}"
BUS_FILE="$COLLAB_DIR/bus/log.ndjson"
CURSOR_DIR="$COLLAB_DIR/cursor"
MEMORY_DIR="$COLLAB_DIR/memory"
CORE_FILE="$MEMORY_DIR/core.md"
DECISIONS_FILE="$MEMORY_DIR/decisions.md"
INDEX_FILE="$MEMORY_DIR/index.md"
HANDOFF_DIR="$COLLAB_DIR/handoff"
WORK_DIR="$COLLAB_DIR/work"
SPECS_DIR="$COLLAB_DIR/specs"
ARCHIVE_DIR="$COLLAB_DIR/archive"
STATE_DIR="$COLLAB_DIR/state"
AGENTS_DIR="$COLLAB_DIR/agents"
LOCK_DIR="$COLLAB_DIR/.lock"

# ── 工具 ──────────────────────────────────────────────────────────
now_iso() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }

# JSON 字符串转义（零依赖，不引入 jq）
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# mkdir 原子锁（macOS/Linux 通用，零依赖）
board_lock() {
    local i=0
    until mkdir "$LOCK_DIR" 2>/dev/null; do
        i=$((i+1))
        if [ $i -gt 100 ]; then
            echo "[board] lock timeout on $LOCK_DIR" >&2
            return 1
        fi
        sleep 0.05
    done
}

board_unlock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }

# ── init：建目录 + 初始化分层记忆 ─────────────────────────────────
board_init() {
    mkdir -p "$(dirname "$BUS_FILE")" "$CURSOR_DIR" "$MEMORY_DIR" \
             "$HANDOFF_DIR" "$WORK_DIR" "$SPECS_DIR" "$ARCHIVE_DIR" \
             "$STATE_DIR" "$AGENTS_DIR"

    [ -f "$BUS_FILE" ] || : > "$BUS_FILE"

    if [ ! -f "$CORE_FILE" ]; then
        cat > "$CORE_FILE" <<'CORE'
# core.md — 常驻层（几 KB，永不膨胀）

> 目标、当前状态、关键约束。人工 + agent 双写。只放「必须永远在上下文里的东西」。

## 目标
<!-- 本次协作要达成什么 -->

## 当前状态
<!-- 进行到哪一步、卡在哪 -->

## 关键约束
- 不 commit 到 git（由用户决定）
- 不碰 .git/ .claude/ CLAUDE.md
CORE
    fi

    [ -f "$DECISIONS_FILE" ] || : > "$DECISIONS_FILE"
    [ -f "$INDEX_FILE" ] || : > "$INDEX_FILE"
}

# ── write：追加一条消息到总线 ─────────────────────────────────────
# board write --from claude --to codex --type spec --task task-1 [--ref path] [--summary "..." ]
board_write() {
    local from="" to="" type="" task="" ref="" summary=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) from="$2"; shift 2 ;;
            --to)   to="$2";   shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --task) task="$2"; shift 2 ;;
            --ref)  ref="$2";  shift 2 ;;
            --summary) summary="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$from" ] && [ -n "$type" ] || { echo "[board] write 需要 --from 和 --type" >&2; return 1; }

    board_init
    board_lock || return 1
    {
        printf '{"ts":"%s","from":"%s","to":"%s","type":"%s","task":"%s","ref":"%s","summary":"%s"}\n' \
            "$(now_iso)" \
            "$(json_escape "$from")" \
            "$(json_escape "$to")" \
            "$(json_escape "$type")" \
            "$(json_escape "$task")" \
            "$(json_escape "$ref")" \
            "$(json_escape "$summary")" >> "$BUS_FILE"
    }
    board_unlock
}

# ── read：增量读总线（按游标），并推进游标 ─────────────────────────
# board read --as claude [--all]
board_read() {
    local as="" all=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --as) as="$2"; shift 2 ;;
            --all) all=1; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$as" ] || { echo "[board] read 需要 --as <name>" >&2; return 1; }

    board_init
    [ -f "$BUS_FILE" ] || { echo "[board] 总线尚未初始化，先 board init" >&2; return 1; }

    local cursor_file="$CURSOR_DIR/$as"
    local cursor=0
    [ -f "$cursor_file" ] && cursor=$(cat "$cursor_file" 2>/dev/null || echo 0)
    [ "$all" = "1" ] && cursor=0

    local total
    total=$(wc -l < "$BUS_FILE" | tr -d ' ')
    [ -z "$total" ] && total=0

    if [ "$total" -gt "$cursor" ]; then
        tail -n +$((cursor+1)) "$BUS_FILE"
    fi

    # 推进游标（读即消费）
    board_lock || return 1
    printf '%s' "$total" > "$cursor_file"
    board_unlock
}

# ── handoff：写交接文件（只回传结论，过程隔离） ───────────────────
# board handoff <task_id> --from codex --status done \
#   [--outcome "..." --artifacts "..." --risks "..." --next "..."]
board_handoff() {
    local task_id="${1:-}"; shift || true
    [ -n "$task_id" ] || { echo "[board] handoff 需要 <task_id>" >&2; return 1; }

    local from="" status="" outcome="" artifacts="" risks="" next=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) from="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            --outcome) outcome="$2"; shift 2 ;;
            --artifacts) artifacts="$2"; shift 2 ;;
            --risks) risks="$2"; shift 2 ;;
            --next) next="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$from" ] || { echo "[board] handoff 需要 --from" >&2; return 1; }

    board_init
    local file="$HANDOFF_DIR/${task_id}.md"
    {
        echo "# Handoff: $task_id"
        echo
        echo "- 来源: $from"
        echo "- 时间: $(now_iso)"
        echo "- 状态: ${status:-done}"
        [ -n "$outcome" ] && { echo; echo "## 结论"; echo "$outcome"; }
        [ -n "$artifacts" ] && { echo; echo "## 产物"; echo "$artifacts"; }
        [ -n "$risks" ] && { echo; echo "## 遗留风险"; echo "$risks"; }
        [ -n "$next" ] && { echo; echo "## 下一步"; echo "$next"; }
    } > "$file"
    echo "[board] handoff 已写：$file"

    # 同步写一条总线消息，让其他 agent 的游标能感知到
    board_write --from "$from" --type handoff --task "$task_id" \
        --ref "handoff/${task_id}.md" \
        --summary "${outcome:-交接完成}" || true
}

# ── remember：写语义层（provenance + 去重/冲突检测） ───────────────
# board remember --author claude --type decision --text "..." \
#   [--evidence path] [--status confirmed|proposed|superseded]
board_remember() {
    local author="" type="decision" text="" evidence="" status="proposed"
    while [ $# -gt 0 ]; do
        case "$1" in
            --author) author="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --text) text="$2"; shift 2 ;;
            --evidence) evidence="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$author" ] && [ -n "$text" ] || { echo "[board] remember 需要 --author 和 --text" >&2; return 1; }

    board_init
    board_lock || return 1

    # 去重：已有相同 text？
    if grep -Fq "文本: $text" "$DECISIONS_FILE" 2>/dev/null; then
        echo "[board] 已存在相同条目，跳过（避免重复）：${text:0:60}"
        board_unlock
        return 0
    fi

    {
        echo
        echo "## ${type}: ${text:0:80}"
        echo "- 文本: $text"
        echo "- 作者: $author"
        echo "- 时间: $(now_iso)"
        [ -n "$evidence" ] && echo "- 依据: $evidence"
        echo "- 状态: $status"
    } >> "$DECISIONS_FILE"

    # 同时更新索引（供 rg 检索语义层）
    printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$author" "$type" "$text" >> "$INDEX_FILE"

    board_unlock
    echo "[board] 已写入语义记忆：${text:0:60}"
}

# ── state：写结构化任务状态（真状态机） ────────────────────────────
# board state <task_id> <running|done|failed> [--verdict v] [--pid n]
board_state() {
    local task_id="${1:-}"; local status="${2:-}"
    [ -n "$task_id" ] && [ -n "$status" ] || { echo "[board] state 需要 <task_id> <status>" >&2; return 1; }

    local verdict="" pid=""
    shift 2 || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --verdict) verdict="$2"; shift 2 ;;
            --pid) pid="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    board_init
    local file="$STATE_DIR/${task_id}.json"
    cat > "$file" <<STATE
{
  "id": "$(json_escape "$task_id")",
  "status": "$(json_escape "$status")",
  "pid": ${pid:-0},
  "spec": "specs/$(json_escape "$task_id").md",
  "handoff": "handoff/$(json_escape "$task_id").md",
  "updated": "$(now_iso)",
  "verdict": "$(json_escape "$verdict")"
}
STATE
}

# ── search：检索总线 + 语义记忆 ─────────────────────────────────
# 优先 ripgrep，未安装则回退 grep（零依赖）。
board_search() {
    board_init
    local files=()
    [ -f "$BUS_FILE" ] && files+=("$BUS_FILE")
    [ -f "$DECISIONS_FILE" ] && files+=("$DECISIONS_FILE")
    [ -f "$INDEX_FILE" ] && files+=("$INDEX_FILE")
    if [ ${#files[@]} -eq 0 ]; then
        echo "[board] 无数据可检索"
        return 0
    fi
    if command -v rg >/dev/null 2>&1; then
        rg -i "$@" "${files[@]}" || echo "[board] 无匹配"
    else
        # grep 只支持单关键词；多关键词请装 rg
        grep -i -H -n "$1" "${files[@]}" 2>/dev/null || echo "[board] 无匹配"
    fi
}

# ── agents：列出名片卡 ─────────────────────────────────────────────
board_agents() {
    board_init
    if compgen -G "$AGENTS_DIR/*.md" >/dev/null 2>&1; then
        for f in "$AGENTS_DIR"/*.md; do
            local name
            name=$(grep -m1 '^name:' "$f" 2>/dev/null | sed 's/^name:[[:space:]]*//')
            [ -n "$name" ] || name=$(basename "$f" .md)
            echo "── $name  ($(basename "$f"))"
            sed -n '1,20p' "$f"
            echo
        done
    else
        echo "[board] 无名片卡（$AGENTS_DIR）"
    fi
}

# ── CLI 分发 ──────────────────────────────────────────────────────
board_main() {
    case "${1:-}" in
        init)      shift; board_init "$@" ;;
        write)     shift; board_write "$@" ;;
        read)      shift; board_read "$@" ;;
        handoff)   shift; board_handoff "$@" ;;
        remember)  shift; board_remember "$@" ;;
        state)     shift; board_state "$@" ;;
        search)    shift; board_search "$@" ;;
        agents)    shift; board_agents "$@" ;;
        help|"")
            cat <<'HELP'
board.sh <command> [args]

  init                          初始化目录 + 分层记忆
  write  --from X --to Y --type T --task ID [--ref P] [--summary S]
  read   --as NAME [--all]      增量读总线（推进游标）
  handoff <task_id> --from X [--status done --outcome O --artifacts A --risks R --next N]
  remember --author X --text T [--type decision --evidence P --status confirmed]
  state  <task_id> <running|done|failed> [--verdict V --pid N]
  search <keyword...>           rg 检索总线 + 语义记忆
  agents                        列出名片卡
HELP
            ;;
        *) echo "[board] 未知命令: $1" >&2; return 1 ;;
    esac
}

# 作为脚本执行时运行 main；被 source 时只暴露函数。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    board_main "$@"
fi
