#!/usr/bin/env bash
# Demo worker: full session/token guard, renewal while executing, durable result.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export COLLAB_DIR="${COLLAB_DIR:-$HOME/Agent/collab}"
source "$SCRIPT_DIR/board.sh"
AGENT="${1:?usage: agent-worker.sh <agent-name>}"
MAX_IDLE="${2:-30}"
WORKER_POLL_SECONDS="${WORKER_POLL_SECONDS:-0.2}"
WORKER_HEARTBEAT_SECONDS="${WORKER_HEARTBEAT_SECONDS:-1}"
board_init
command -v jq >/dev/null || { echo 'worker requires jq' >&2; exit 1; }
SESSION="sess-$(date +%s)-$$-$RANDOM"
board_agent_heartbeat --agent "$AGENT" --session "$SESSION" --ttl 30 --register
EXEC_PID=""
cleanup() {
    if [ -n "$EXEC_PID" ]; then
        kill "$EXEC_PID" 2>/dev/null || true
        wait "$EXEC_PID" 2>/dev/null || true
    fi
    # Do not retire a newer process's session.
    db "UPDATE agents SET expires=0 WHERE agent=$(sql_quote "$AGENT") AND session=$(sql_quote "$SESSION");" >/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

idle=0
while [ "$idle" -lt "$MAX_IDLE" ]; do
    board_agent_heartbeat --agent "$AGENT" --session "$SESSION" --ttl 30 || exit 1
    msgs=$(board_read --as "$AGENT:$SESSION" --to "$AGENT")
    if [ -z "$msgs" ]; then
        idle=$((idle+1)); sleep "$WORKER_POLL_SECONDS"; continue
    fi
    idle=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        seq=$(printf '%s' "$line" | jq -r '.seq')
        job_id=$(printf '%s' "$line" | jq -r '.task // empty')
        kind=$(printf '%s' "$line" | jq -r '.type')
        sender=$(printf '%s' "$line" | jq -r '.from')
        token=$(printf '%s' "$line" | jq -r '.summary // "" | try capture("^token=(?<t>[0-9]+)$").t // empty')
        if [ "$kind" = task ] && [ "$sender" = scheduler ] && [ -n "$job_id" ] && is_int "$token"; then
            grant=(--id "$job_id" --token "$token" --agent "$AGENT" --session "$SESSION")
            if board_job_guard "${grant[@]}"; then
                # Stable across retries/redelivery. Real API adapters must send this
                # key to a receiver that enforces deduplication and fencing.
                export COLLAB_IDEMPOTENCY_KEY="job:$job_id"
                echo "[$AGENT] 执行 job $job_id (token=$token) ..."
                sleep "${WORKER_MOCK_SECONDS:-0.5}" &
                EXEC_PID=$!
                lost=0
                while kill -0 "$EXEC_PID" 2>/dev/null; do
                    if ! board_agent_heartbeat --agent "$AGENT" --session "$SESSION" --ttl 30 ||
                       ! board_job_heartbeat "${grant[@]}"; then
                        kill "$EXEC_PID" 2>/dev/null || true
                        lost=1
                        break
                    fi
                    sleep "$WORKER_HEARTBEAT_SECONDS"
                done
                rc=0
                wait "$EXEC_PID" || rc=$?
                EXEC_PID=""
                if [ "$lost" = 0 ]; then
                    if [ "$rc" = 0 ]; then
                        # The mock's only effect is a result in SQLite, committed
                        # atomically with done under the grant and a unique job key.
                        board_job_done "${grant[@]}" --verdict "done by $AGENT" \
                            --effect "done by $AGENT" || true
                    else
                        board_job_fail "${grant[@]}" --verdict "execution exit $rc" || true
                    fi
                fi
            fi
        fi
        board_ack --as "$AGENT:$SESSION" --seq "$seq" >/dev/null
    done <<< "$msgs"
done
echo "[$AGENT] 空闲退出"
