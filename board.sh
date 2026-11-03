#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  board.sh — 共享黑板总线 (v3.1)
#
#  v2 → v3 修复（基于 Claude + Codex 双模型评审）：
#   1. JSON 构造/解析改用 jq（macOS 自带），不再 sed/grep 手抠 —— 修"解析脆弱"
#   2. 每条消息带唯一 id —— 修"无信封/无法幂等"
#   3. 锁加 stale 检测（owner pid + 超时强清）—— 修"进程被杀→死锁"
#   4. 游标改字节偏移，compact 时显式重置 —— 修"行号游标在截断后失效"
#   5. 状态机加 lease（租约）+ heartbeat —— 修"崩溃永久卡 running / pid 判活"
#   6. state/handoff 原子写（tmp + mv）—— 修"读到半截文件"
#
#  v3 → v3.1 修复（基于三通道复盘：自建 Codex + subagent Codex + subagent Claude）：
#   7. 锁改 owner token + 原子 rename 抢占 + 释放 fencing —— 修"双 breaker 同时删锁 / 旧持有者误删"
#   8. 消息加 seq 单调递增 —— 修"无消息序号"
#   9. read 加 seen-set 幂等去重 + 半行跳过 —— 修"有 id 不幂等 / 半条日志"
#  10. state 加状态转换防护（终态不可回 running）—— 修"旧持有者覆盖新状态"
#  11. atomic_write 加 fsync —— 修"断电丢数据"
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

# fsync 单个文件（尽力持久化；python3 在 macOS/Linux 均有）
fsync_file() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)" "$1" 2>/dev/null || true
    fi
}

# 原子写：tmp + fsync + mv（发布即完整 + 尽力持久化）
atomic_write() {
    local file="$1" content="$2"
    local tmp="${file}.tmp.$$.$RANDOM"
    printf '%s' "$content" > "$tmp"
    fsync_file "$tmp"
    mv "$tmp" "$file"
}

# ── 锁：mkdir 原子锁 + owner token + 原子抢占（fencing）────────────
# owner token 格式 pid-epoch-rand；释放时校验 token，防误删他人锁；
# stale 清理用原子 rename（只一个 breaker 能成功），避免双 breaker 同时 rm。
board_lock() {
    local token="$$-$(now_epoch)-$RANDOM"
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        local stale=0 owner="" opid="" mtime="" now=""
        now=$(now_epoch)
        if [ -f "$LOCK_DIR/owner" ]; then
            owner=$(cat "$LOCK_DIR/owner" 2>/dev/null || echo "")
            opid="${owner%%-*}"
            mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
            # 条件1：owner 进程已死
            if [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null; then stale=1; fi
            # 条件2：锁存在超过 STALE_LOCK_SECONDS（兜底；临界区极短，误伤概率低，且靠 token 校验缓解）
            if [ -n "$mtime" ] && [ "$mtime" != "0" ] && [ $((now - mtime)) -gt "$STALE_LOCK_SECONDS" ]; then stale=1; fi
        else
            # 半初始化锁（写 owner 前崩溃）
            mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo 0)
            if [ -n "$mtime" ] && [ "$mtime" != "0" ] && [ $((now - mtime)) -gt "$STALE_LOCK_SECONDS" ]; then stale=1; fi
        fi
        if [ "$stale" = "1" ]; then
            # 原子抢占：rename 旧锁到唯一名（只有一个 breaker 成功），再删 victim
            local victim="$LOCK_DIR.stale.$$.$RANDOM"
            if mv "$LOCK_DIR" "$victim" 2>/dev/null; then
                echo "[board] 抢占 stale 锁（owner=${owner:-?}）" >&2
                rm -rf "$victim" 2>/dev/null || true
                continue
            fi
            # rename 失败 = 别人已抢/已释放，继续等
        fi
        i=$((i+1))
        if [ $i -gt 200 ]; then
            echo "[board] lock timeout on $LOCK_DIR" >&2
            return 1
        fi
        sleep 0.05
    done
    printf '%s' "$token" > "$LOCK_DIR/owner"
    LOCK_TOKEN="$token"
}

board_unlock() {
    # fencing：只释放自己持有的锁；token 不匹配说明锁已被抢占，拒绝删除
    if [ -f "$LOCK_DIR/owner" ]; then
        local cur
        cur=$(cat "$LOCK_DIR/owner" 2>/dev/null || echo "")
        if [ -n "${LOCK_TOKEN:-}" ] && [ "$cur" != "$LOCK_TOKEN" ]; then
            echo "[board] fencing：锁已被抢占，拒绝释放（原 token 失效）" >&2
            return 0
        fi
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    LOCK_TOKEN=""
}

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
    local id
    id=$(gen_msg_id)

    board_lock || return 1
    # seq 在锁内计算，保证单调递增（append-only + 单写者锁）
    local seq line
    seq=$(( $(wc -l < "$BUS_FILE" 2>/dev/null | tr -d ' ') + 1 ))

    if has_jq; then
        line=$(jq -cn \
            --argjson seq "$seq" --arg id "$id" --arg ts "$(now_iso)" --arg from "$from" --arg to "$to" \
            --arg type "$type" --arg task "$task" --arg ref "$ref" --arg summary "$summary" \
            '{seq:$seq, id:$id, ts:$ts, from:$from, to:$to, type:$type, task:$task, ref:$ref, summary:$summary}')
    else
        echo "[board] 警告：未找到 jq，JSON 转义降级（建议 brew install jq）" >&2
        line=$(printf '{"seq":%s,"id":"%s","ts":"%s","from":"%s","to":"%s","type":"%s","task":"%s","ref":"%s","summary":"%s"}' \
            "$seq" "$(json_escape "$id")" "$(now_iso)" "$(json_escape "$from")" "$(json_escape "$to")" \
            "$(json_escape "$type")" "$(json_escape "$task")" "$(json_escape "$ref")" "$(json_escape "$summary")")
    fi
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
    local seen_file="$CURSOR_DIR/$as.seen"
    [ -f "$seen_file" ] || : > "$seen_file"

    local offset=0
    [ -f "$cursor_file" ] && offset=$(cat "$cursor_file" 2>/dev/null || echo 0)
    [ "$all" = "1" ] && offset=0

    local size
    size=$(wc -c < "$BUS_FILE" | tr -d ' ')
    [ -z "$size" ] && size=0

    if [ "$size" -gt "$offset" ]; then
        # 逐行读：半行/坏行跳过（无法解析 id 的行），seen-set 去重（崩溃重放不重复消费）
        tail -c +$((offset+1)) "$BUS_FILE" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            local mid
            mid=$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null || echo "")
            [ -z "$mid" ] && continue
            if grep -Fxq "$mid" "$seen_file" 2>/dev/null; then
                continue
            fi
            printf '%s\n' "$line"
            printf '%s\n' "$mid" >> "$seen_file"
        done
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
    local file="$STATE_DIR/${task_id}.json"

    # fencing：终态（done/failed）不可回 running，防止旧持有者覆盖新状态
    if [ "$status" = "running" ] && [ -f "$file" ]; then
        local cur_status
        cur_status=$(jq -r '.status // ""' "$file" 2>/dev/null || echo "")
        if [ "$cur_status" = "done" ] || [ "$cur_status" = "failed" ]; then
            echo "[board] fencing 拒绝：任务已终态（$cur_status），旧持有者不得重启" >&2
            return 1
        fi
    fi

    # 租约：running 时设 lease_epoch = now + LEASE_SECONDS；终态清空
    local lease_epoch=""
    [ "$status" = "running" ] && lease_epoch=$(( $(now_epoch) + LEASE_SECONDS ))

    local content
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
