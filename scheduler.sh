#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  scheduler.sh — 单写者调度器（N-agent）
#
#  循环：标记就绪（依赖满足）→ 能力路由（名片卡 skill 匹配）→
#        认领 job（fencing token）→ 发租约消息 → 死信/终止检测。
#  调度器自身也持 fencing（job_claim 返回 token），不直接执行。
#
#  用法：scheduler.sh [max_rounds]
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLAB_DIR="${COLLAB_DIR:-$HOME/Agent/collab}"
export COLLAB_DIR

# shellcheck disable=SC1091
source "$SCRIPT_DIR/board.sh"
MAX_INFLIGHT_PER_AGENT="${MAX_INFLIGHT_PER_AGENT:-1}"
export MAX_INFLIGHT_PER_AGENT
is_int "$MAX_INFLIGHT_PER_AGENT" && [ "$MAX_INFLIGHT_PER_AGENT" -gt 0 ] || exit 1
board_init

# ── 能力路由：读名片卡，按 skill 匹配 job type；只匹配「在线」agent ─
match_agent() {
    local type="$1" f name online
    for f in "$AGENTS_DIR"/*.md; do
        [ -f "$f" ] || continue
        name=$(grep -m1 '^name:' "$f" 2>/dev/null | sed 's/^name:[[:space:]]*//' || true)
        [ -n "$name" ] || name=$(basename "$f" .md)
        # 跳过协调者/人类自己
        case "$name" in scheduler|lead|human) continue ;; esac
        # 简单匹配：名片卡 skills 行包含该 type（固定字符串）
        if grep -m1 '^skills:' "$f" 2>/dev/null | grep -qF "$type"; then
            # 只匹配在线 agent（agents 表 expires > now）
            online=$(dbq "SELECT COUNT(*) FROM agents WHERE agent=$(sql_quote "$name") AND expires > $(now_epoch)
                AND (SELECT COUNT(*) FROM jobs WHERE assigned_to=$(sql_quote "$name") AND status='running') < $MAX_INFLIGHT_PER_AGENT;" 2>/dev/null || echo 0)
            if [ "$online" = "1" ]; then
                echo "$name"; return 0
            fi
        fi
    done
    echo ""   # 无在线匹配 → 空（scheduler 跳过，等 agent 上线）
}

# ── 主循环 ────────────────────────────────────────────────────────
run() {
    local max_rounds="${1:-200}"
    local round=0

    while [ $round -lt $max_rounds ]; do
        round=$((round+1))

        # 0. 回收 lease 过期的 running（防永久卡住 + fencing_token+1 使旧持有者失效）
        board_job_reap >/dev/null 2>&1 || true

        # 1. 标记就绪（依赖满足的 pending → ready）
        board_job_ready >/dev/null 2>&1 || true

        # 2. 找 ready job
        local ready job_id type
        ready=$(dbq "SELECT job_id||'|'||type FROM jobs WHERE status='ready' ORDER BY priority DESC, created_at ASC;" 2>/dev/null || true)

        if [ -z "$ready" ]; then
            # 无 ready：判断是否还有 running 或 pending（继续等），否则结束
            local running pending
            running=$(dbq "SELECT COUNT(*) FROM jobs WHERE status='running';" 2>/dev/null || echo 0)
            pending=$(dbq "SELECT COUNT(*) FROM jobs WHERE status IN ('pending','ready');" 2>/dev/null || echo 0)
            if [ "$running" = "0" ] && [ "$pending" = "0" ]; then
                echo "[scheduler] 调度收敛（round $round）：无就绪、无运行、无待办"
                break
            fi
            sleep 1
            continue
        fi

        local agent token dispatched=0
        while IFS='|' read -r job_id type; do
            [ -n "$job_id" ] || continue
            agent=$(match_agent "$type")
            [ -n "$agent" ] || continue
            # job-claim also writes the durable message in the same transaction.
            if token=$(board_job_claim --id "$job_id" --agent "$agent"); then
                echo "[scheduler] 派发 $job_id (type=$type) → $agent (token=$token)"
                dispatched=1
            fi
        done <<< "$ready"
        if [ "$dispatched" = 0 ]; then sleep 1; fi
    done

    # 最终状态
    echo "[scheduler] 最终 job 状态："
    board_job_list || true
}

run "$@"
