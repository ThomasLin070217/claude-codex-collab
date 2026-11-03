#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  board.sh — 共享黑板总线 (v3)
#
#  v2 → v3 修复（基于 Claude + Codex 双模型评审）：
#   1. JSON 构造/解析改用 jq（macOS 自带），不再 sed/grep 手抠 —— 修"解析脆弱"
#   2. 每条消息带唯一 id —— 修"无信封/无法幂等"
#   3. 锁加 stale 检测（owner pid + 超时强清）—— 修"进程被杀→死锁"
#   4. 游标改字节偏移，compact 时显式重置 —— 修"行号游标在截断后失效"
#   5. 状态机加 lease（租约）+ heartbeat —— 修"崩溃永久卡 running / pid 判活"
#   6. state/handoff 原子写（tmp + mv）—— 修"读到半截文件"
#
#  依赖：bash + 系统自带命令；jq 优先，缺失时降级并提示。
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
CHECKPOINT_DIR="$COLLAB_DIR/checkpoints"
STATE_DIR="$COLLAB_DIR/state"
AGENTS_DIR="$COLLAB_DIR/agents"
LOCK_DIR="$COLLAB_DIR/.lock"

# 锁超过该秒数视为 stale；租约默认 600s（匹配 Codex timeout）
STALE_LOCK_SECONDS="${STALE_LOCK_SECONDS:-10}"
LEASE_SECONDS="${LEASE_SECONDS:-600}"

# ── 工具 ──────────────────────────────────────────────────────────
now_iso() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }
now_epoch() { date +%s; }

has_jq() { command -v jq >/dev/null 2>&1; }

# jq 缺失时的降级转义（尽量别走到这里：macOS 自带 jq）
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# 生成唯一消息 id：msg-<epoch>-<pid>-<random>
gen_msg_id() { printf 'msg-%s-%s-%s' "$(date +%s)" "$$" "$RANDOM"; }

# 原子写：tmp + mv（发布即完整）
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$.$RANDOM"
    printf '%s' "$content" > "$tmp"
    mv "$tmp" "$file"
}

# ── 锁：mkdir 原子锁 + stale 检测 ──────────────────────────────────
board_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        # stale 检测：owner pid 已不存在，或锁存在超过 STALE_LOCK_SECONDS
        if [ -f "$LOCK_DIR/pid" ]; then
            local opid="" mtime="" now=""
            opid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
            mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
            now=$(now_epoch)
            if { [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null; } \
               || { [ -n "$mtime" ] && [ "$mtime" != "0" ] && [ $((now - mtime)) -gt "$STALE_LOCK_SECONDS" ]; }; then
                echo "[board] 检测到 stale 锁（owner pid=${opid:-?}），强制清理" >&2
                rm -rf "$LOCK_DIR"
                continue
            fi
        fi
        i=$((i+1))
        if [ $i -gt 200 ]; then
            echo "[board] lock timeout on $LOCK_DIR" >&2
            return 1
        fi
        sleep 0.05
    done
    printf '%s' "$$" > "$LOCK_DIR/pid"
}

board_unlock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }

# ── init ──────────────────────────────────────────────────────────
board_init() {
    mkdir -p "$(dirname "$BUS_FILE")" "$CURSOR_DIR" "$MEMORY_DIR" \
             "$HANDOFF_DIR" "$WORK_DIR" "$SPECS_DIR" "$ARCHIVE_DIR" \
             "$CHECKPOINT_DIR" "$STATE_DIR" "$AGENTS_DIR"
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

# ── write：追加一条消息到总线（jq 构造 + 唯一 id）─────────────────
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
    local id line
    id=$(gen_msg_id)

    if has_jq; then
        line=$(jq -cn \
            --arg id "$id" --arg ts "$(now_iso)" --arg from "$from" --arg to "$to" \
            --arg type "$type" --arg task "$task" --arg ref "$ref" --arg summary "$summary" \
            '{id:$id, ts:$ts, from:$from, to:$to, type:$type, task:$task, ref:$ref, summary:$summary}')
    else
        echo "[board] 警告：未找到 jq，JSON 转义降级（建议 brew install jq）" >&2
        line=$(printf '{"id":"%s","ts":"%s","from":"%s","to":"%s","type":"%s","task":"%s","ref":"%s","summary":"%s"}' \
            "$(json_escape "$id")" "$(now_iso)" "$(json_escape "$from")" "$(json_escape "$to")" \
            "$(json_escape "$type")" "$(json_escape "$task")" "$(json_escape "$ref")" "$(json_escape "$summary")")
    fi

    board_lock || return 1
    printf '%s\n' "$line" >> "$BUS_FILE"
    board_unlock
    printf '%s\n' "$id"
}

# ── read：按字节偏移增量读（游标存字节数，append 场景稳定）────────
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
    local offset=0
    [ -f "$cursor_file" ] && offset=$(cat "$cursor_file" 2>/dev/null || echo 0)
    [ "$all" = "1" ] && offset=0

    local size
    size=$(wc -c < "$BUS_FILE" | tr -d ' ')
    [ -z "$size" ] && size=0

    if [ "$size" -gt "$offset" ]; then
        tail -c +$((offset+1)) "$BUS_FILE"
    fi

    board_lock || return 1
    printf '%s' "$size" > "$cursor_file"
    board_unlock
}

# ── handoff：写交接文件（原子写）───────────────────────────────────
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
    local file="$HANDOFF_DIR/${task_id}.md" content
    content="# Handoff: $task_id

- 来源: $from
- 时间: $(now_iso)
- 状态: ${status:-done}"
    [ -n "$outcome" ] && content+=$'\n\n## 结论\n'"$outcome"
    [ -n "$artifacts" ] && content+=$'\n\n## 产物\n'"$artifacts"
    [ -n "$risks" ] && content+=$'\n\n## 遗留风险\n'"$risks"
    [ -n "$next" ] && content+=$'\n\n## 下一步\n'"$next"

    atomic_write "$file" "$content"
    echo "[board] handoff 已写：$file"

    board_write --from "$from" --type handoff --task "$task_id" \
        --ref "handoff/${task_id}.md" \
        --summary "${outcome:-交接完成}" >/dev/null || true
}

# ── remember：写语义层（锁保护 + 去重）─────────────────────────────
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
    printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$author" "$type" "$text" >> "$INDEX_FILE"

    board_unlock
    echo "[board] 已写入语义记忆：${text:0:60}"
}

# ── state：结构化状态（jq 构造 + lease + 原子写）───────────────────
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
    # 租约：running 时设 lease_epoch = now + LEASE_SECONDS；终态清空
    local lease_epoch=""
    [ "$status" = "running" ] && lease_epoch=$(( $(now_epoch) + LEASE_SECONDS ))

    local file="$STATE_DIR/${task_id}.json" content
    if has_jq; then
        content=$(jq -cn \
            --arg id "$task_id" --arg status "$status" \
            --argjson pid "${pid:-0}" --arg verdict "$verdict" \
            --arg lease_epoch "$lease_epoch" --arg updated "$(now_iso)" \
            '{id:$id, status:$status, pid:$pid, verdict:$verdict, lease_epoch:$lease_epoch, updated:$updated}')
    else
        content=$(printf '{"id":"%s","status":"%s","pid":%s,"verdict":"%s","lease_epoch":"%s","updated":"%s"}' \
            "$(json_escape "$task_id")" "$(json_escape "$status")" "${pid:-0}" \
            "$(json_escape "$verdict")" "$lease_epoch" "$(now_iso)")
    fi
    atomic_write "$file" "$content"
}

# ── heartbeat：续租（running 任务的心跳）────────────────────────────
board_heartbeat() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || { echo "[board] heartbeat 需要 <task_id>" >&2; return 1; }
    board_init
    local file="$STATE_DIR/${task_id}.json"
    [ -f "$file" ] || { echo "[board] 无状态文件：$task_id" >&2; return 1; }

    local lease_epoch=$(( $(now_epoch) + LEASE_SECONDS ))
    if has_jq; then
        jq --arg le "$lease_epoch" --arg ts "$(now_iso)" \
            '.lease_epoch = $le | .updated = $ts' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        echo "[board] 警告：heartbeat 需要 jq" >&2
        return 1
    fi
}

# ── check：判活（弃 pid，靠 lease）─────────────────────────────────
# board check <task_id>  → 输出 running|done|failed|orphaned|unknown
board_check() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || { echo "[board] check 需要 <task_id>" >&2; return 1; }
    board_init
    local file="$STATE_DIR/${task_id}.json"
    [ -f "$file" ] || { echo "unknown"; return 0; }

    local status lease
    if has_jq; then
        status=$(jq -r '.status // "unknown"' "$file" 2>/dev/null || echo unknown)
        lease=$(jq -r '.lease_epoch // ""' "$file" 2>/dev/null || echo "")
    else
        status=$(grep -o '"status":"[^"]*"' "$file" | head -1 | cut -d'"' -f4)
        lease=$(grep -o '"lease_epoch":"[^"]*"' "$file" | head -1 | cut -d'"' -f4)
    fi

    if [ "$status" = "running" ] && [ -n "$lease" ] && [ "$lease" != "" ]; then
        if [ "$(now_epoch)" -gt "$lease" ]; then
            echo "orphaned"
            return 0
        fi
    fi
    echo "$status"
}

# ── compact：折叠旧日志到 archive + checkpoint，重置游标 ───────────
board_compact() {
    board_init
    board_lock || return 1
    local ts
    ts=$(date +%s)
    if [ -s "$BUS_FILE" ]; then
        mkdir -p "$ARCHIVE_DIR" "$CHECKPOINT_DIR"
        mv "$BUS_FILE" "$ARCHIVE_DIR/log-${ts}.ndjson"
        : > "$BUS_FILE"
        # 所有 agent 游标重置（日志已截断，字节偏移从 0 重新计）
        rm -f "$CURSOR_DIR"/* 2>/dev/null || true
        # 写 checkpoint 快照（当前世界状态摘要，供恢复）
        {
            echo "# Checkpoint $(now_iso)"
            echo "- 归档: archive/log-${ts}.ndjson"
            echo "- 语义记忆条数: $(grep -c '^## ' "$DECISIONS_FILE" 2>/dev/null || echo 0)"
        } > "$CHECKPOINT_DIR/${ts}.md"
        echo "[board] 已 compact：旧日志归档到 archive/log-${ts}.ndjson，游标已重置"
    else
        echo "[board] 总列为空，无需 compact"
    fi
    board_unlock
}

# ── search ─────────────────────────────────────────────────────────
board_search() {
    board_init
    local files=()
    [ -f "$BUS_FILE" ] && files+=("$BUS_FILE")
    [ -f "$DECISIONS_FILE" ] && files+=("$DECISIONS_FILE")
    [ -f "$INDEX_FILE" ] && files+=("$INDEX_FILE")
    if [ ${#files[@]} -eq 0 ]; then
        echo "[board] 无数据可检索"; return 0
    fi
    if command -v rg >/dev/null 2>&1; then
        rg -i "$@" "${files[@]}" || echo "[board] 无匹配"
    else
        grep -i -H -n "$1" "${files[@]}" 2>/dev/null || echo "[board] 无匹配"
    fi
}

# ── agents ─────────────────────────────────────────────────────────
board_agents() {
    board_init
    if compgen -G "$AGENTS_DIR/*.md" >/dev/null 2>&1; then
        for f in "$AGENTS_DIR"/*.md; do
            local name
            name=$(grep -m1 '^name:' "$f" 2>/dev/null | sed 's/^name:[[:space:]]*//')
            [ -n "$name" ] || name=$(basename "$f" .md)
            echo "── $name  ($(basename "$f"))"
            sed -n '1,20p' "$f"; echo
        done
    else
        echo "[board] 无名片卡（$AGENTS_DIR）"
    fi
}

# ── CLI 分发 ──────────────────────────────────────────────────────
board_main() {
    case "${1:-}" in
        init)       shift; board_init "$@" ;;
        write)      shift; board_write "$@" ;;
        read)       shift; board_read "$@" ;;
        handoff)    shift; board_handoff "$@" ;;
        remember)   shift; board_remember "$@" ;;
        state)      shift; board_state "$@" ;;
        heartbeat)  shift; board_heartbeat "$@" ;;
        check)      shift; board_check "$@" ;;
        compact)    shift; board_compact "$@" ;;
        search)     shift; board_search "$@" ;;
        agents)     shift; board_agents "$@" ;;
        help|"")
            cat <<'HELP'
board.sh <command> [args]

  init                            初始化目录 + 分层记忆
  write  --from X --to Y --type T --task ID [--ref P] [--summary S]
                                  追加消息（jq 构造，返回唯一 id）
  read   --as NAME [--all]        增量读总线（字节偏移游标）
  handoff <task_id> --from X [--status done --outcome O --artifacts A --risks R --next N]
  remember --author X --text T [--type decision --evidence P --status confirmed]
  state  <task_id> <running|done|failed> [--verdict V --pid N]
  heartbeat <task_id>             续租（刷新 lease）
  check   <task_id>               判活：running|done|failed|orphaned|unknown
  compact                         折叠旧日志到 archive，重置游标
  search <kw...>                  检索总线 + 语义记忆
  agents                          列出名片卡
HELP
            ;;
        *) echo "[board] 未知命令: $1" >&2; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    board_main "$@"
fi
