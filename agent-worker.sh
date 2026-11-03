#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  agent-worker.sh — 通用 agent worker（demo 用 mock）
#
#  循环：read（不推进）→ 逐条执行 → ack（推进游标）→ job-done。
#  真实场景把「执行」这步替换为调 codex-bridge / claude 等真实 agent。
#
#  用法：agent-worker.sh <agent-name> [max_idle_rounds]
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLAB_DIR="${COLLAB_DIR:-$HOME/Agent/collab}"
export COLLAB_DIR

# shellcheck disable=SC1091
source "$SCRIPT_DIR/board.sh"

AGENT="${1:?usage: agent-worker.sh <agent-name>}"
MAX_IDLE="${2:-30}"

board_init >/dev/null 2>&1

# 注册在线状态 + 后台心跳（每 10s 续期，健康 TTL 30s）
SESSION="sess-$(date +%s)-$$-$RANDOM"
board_agent_heartbeat --agent "$AGENT" --session "$SESSION" --ttl 30 >/dev/null 2>&1
(
    while :; do
        sleep 10
        board_agent_heartbeat --agent "$AGENT" --session "$SESSION" --ttl 30 >/dev/null 2>&1 || exit 0
    done
) &
HB_PID=$!
trap 'kill $HB_PID 2>/dev/null || true' EXIT

idle=0
while [ $idle -lt "$MAX_IDLE" ]; do
    msgs=$(board_read --as "$AGENT" --to "$AGENT" 2>/dev/null || true)
    if [ -z "$msgs" ]; then
        idle=$((idle+1)); sleep 0.5; continue
    fi
    idle=0
    last_seq=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        job_id=$(printf '%s' "$line" | jq -r '.task // empty' 2>/dev/null || echo "")
        seq=$(printf '%s' "$line" | jq -r '.seq // empty' 2>/dev/null || echo "")
        summary=$(printf '%s' "$line" | jq -r '.summary // empty' 2>/dev/null || echo "")
        [ -n "$seq" ] && last_seq=$seq
        [ -z "$job_id" ] && continue

        # 从消息里取 claim token（scheduler 派发时携带），不重读 jobs 表（防冒领）
        token=$(printf '%s' "$summary" | grep -o 'token=[0-9]*' | head -1 | cut -d= -f2)

        echo "[$AGENT] 执行 job $job_id (token=$token) ..."
        sleep 0.5   # mock：真实场景替换为 codex-bridge / claude 调用

        if [ -n "$token" ]; then
            board_job_done --id "$job_id" --token "$token" --agent "$AGENT" --verdict "done by $AGENT" >/dev/null 2>&1 \
                || board_job_fail --id "$job_id" --token "$token" --agent "$AGENT" --verdict "failed by $AGENT" >/dev/null 2>&1 \
                || true
        fi
    done <<< "$msgs"

    # ack：确认消费到 last_seq（at-least-once 协议）
    if [ "$last_seq" -gt 0 ] 2>/dev/null; then
        board_ack --as "$AGENT" --seq "$last_seq" >/dev/null 2>&1 || true
    fi
done

echo "[$AGENT] 空闲退出"
