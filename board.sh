#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  board.sh — 共享黑板总线 (v4 · SQLite 事务核心)
#
#  v4：把强一致（消息顺序/消费进度/租约抢占/幂等）下沉到 SQLite(WAL)，
#      文件层退化为「可读投影」（export 从 SQLite 重建）。
#
#  依赖：bash + sqlite3（macOS 自带）。jq 仅用于投影/校验，缺失降级。
#  可作库 source，也可直接执行 `board.sh <command> ...`。
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── 目录布局 ──────────────────────────────────────────────────────
COLLAB_DIR="${COLLAB_DIR:-$HOME/Agent/collab}"
DB="$COLLAB_DIR/board.db"
BUS_FILE="$COLLAB_DIR/bus/log.ndjson"
CURSOR_DIR="$COLLAB_DIR/cursor"       # v4 保留目录，但消费进度在 consumption 表
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

LEASE_SECONDS="${LEASE_SECONDS:-1800}"
# 时钟漂移容忍：lease 过期判断再宽限这几秒（权威仍是 fencing_token CAS，时钟只做粗粒度超时）
GRACE_SECONDS="${GRACE_SECONDS:-5}"

# ── 工具 ──────────────────────────────────────────────────────────
now_iso() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }
now_epoch() { date +%s; }
has_jq() { command -v jq >/dev/null 2>&1; }
has_sqlite3() { command -v sqlite3 >/dev/null 2>&1; }

# 生成唯一消息 id：msg-<epoch>-<pid>-<random>
gen_msg_id() { printf 'msg-%s-%s-%s' "$(date +%s)" "$$" "$RANDOM"; }

# SQL 字符串转义（单引号 → 两单引号）。信任边界：本地 agent 协作，非对抗环境。
sql_quote() {
    local s="$1"
    s="${s//\'/\'\'}"
    printf "'%s'" "$s"
}

# db：执行写/更新（PRAGMA busy_timeout 更可靠；awk 滤掉其返回值 "5000"）
# 注意用 PIPESTATUS 保留 sqlite3 的真实退出码，供 || 错误处理。
db() {
    sqlite3 -bail "$DB" "PRAGMA busy_timeout=5000; $1" 2>&1 | awk 'NR==1 && $0=="5000" {next} {print}'
    return "${PIPESTATUS[0]}"
}

# dbq：查询，返回 stdout（同样滤掉 PRAGMA 返回值）
dbq() {
    sqlite3 "$DB" "PRAGMA busy_timeout=5000; $1" 2>&1 | awk 'NR==1 && $0=="5000" {next} {print}'
}

# payload_hash：ref 指向的文件内容哈希（不可变产物关联）
payload_hash_of() {
    local ref="$1"
    [ -z "$ref" ] && { echo ""; return 0; }
    local f="$COLLAB_DIR/$ref"
    if [ -f "$f" ]; then
        shasum -a 256 "$f" 2>/dev/null | awk '{print $1}' \
            || sha256sum "$f" 2>/dev/null | awk '{print $1}'
    else
        echo ""
    fi
}

# ── init：建目录 + SQLite schema ──────────────────────────────────
board_init() {
    mkdir -p "$(dirname "$BUS_FILE")" "$CURSOR_DIR" "$MEMORY_DIR" \
             "$HANDOFF_DIR" "$WORK_DIR" "$SPECS_DIR" "$ARCHIVE_DIR" \
             "$CHECKPOINT_DIR" "$STATE_DIR" "$AGENTS_DIR"

    if ! has_sqlite3; then
        echo "[board] 错误：需要 sqlite3（macOS 自带 /usr/bin/sqlite3）" >&2
        return 1
    fi

    sqlite3 "$DB" >/dev/null 2>&1 <<'SQL'
PRAGMA busy_timeout=5000;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS messages (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,
    id           TEXT NOT NULL UNIQUE,
    ts           INTEGER NOT NULL,
    from_agent   TEXT NOT NULL,
    to_agent     TEXT,
    type         TEXT NOT NULL,
    task_id      TEXT,
    ref          TEXT,
    summary      TEXT,
    payload_hash TEXT,
    created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE INDEX IF NOT EXISTS idx_messages_task ON messages(task_id, seq);
CREATE INDEX IF NOT EXISTS idx_messages_to   ON messages(to_agent, seq);

CREATE TABLE IF NOT EXISTS consumption (
    agent       TEXT PRIMARY KEY,
    last_seq    INTEGER NOT NULL DEFAULT 0,
    updated_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
    task_id       TEXT PRIMARY KEY,
    status        TEXT NOT NULL CHECK (status IN ('running','done','failed')),
    fencing_token INTEGER NOT NULL DEFAULT 0,
    lease_epoch   INTEGER,
    owner         TEXT,
    verdict       TEXT,
    pid           INTEGER,
    updated_at    INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS memory (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    context     TEXT NOT NULL DEFAULT 'general',
    author      TEXT NOT NULL,
    type        TEXT NOT NULL,
    text        TEXT NOT NULL,
    evidence    TEXT,
    status      TEXT,
    created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS memory_dedup ON memory(context, type, text);
SQL

    # core.md 模板（文件投影仍保留给人看）
    [ -f "$CORE_FILE" ] || cat > "$CORE_FILE" <<'CORE'
# core.md — 常驻层（投影，真相在 board.db）

> 目标、当前状态、关键约束。人工 + agent 双写。

## 目标
## 当前状态
## 关键约束
- 不 commit 到 git（由用户决定）
- 不碰 .git/ .claude/ CLAUDE.md
CORE
}

# ── write：INSERT 消息（幂等）─────────────────────────────────────
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
    local id hash
    id=$(gen_msg_id)
    hash=$(payload_hash_of "$ref")

    # id UNIQUE 冲突：比对 summary 判断是否同内容（幂等 vs 报错）
    local existing
    existing=$(dbq "SELECT summary FROM messages WHERE id=$(sql_quote "$id");" 2>/dev/null || true)
    if [ -n "$existing" ]; then
        if [ "$existing" = "$summary" ]; then
            dbq "SELECT seq FROM messages WHERE id=$(sql_quote "$id");"
            return 0
        fi
        echo "[board] 错误：id 冲突且内容不同（$id）" >&2
        return 1
    fi

    db "INSERT INTO messages (id, ts, from_agent, to_agent, type, task_id, ref, summary, payload_hash)
        VALUES ($(sql_quote "$id"), $(now_epoch), $(sql_quote "$from"), $(sql_quote "$to"),
                $(sql_quote "$type"), $(sql_quote "$task"), $(sql_quote "$ref"), $(sql_quote "$summary"),
                $(sql_quote "$hash"));" || {
        # 并发下 UNIQUE 冲突：幂等返回已存在的 seq
        existing=$(dbq "SELECT seq FROM messages WHERE id=$(sql_quote "$id");" 2>/dev/null || true)
        if [ -n "$existing" ]; then
            printf '%s\n' "$existing"
            return 0
        fi
        return 1
    }
    dbq "SELECT seq FROM messages WHERE id=$(sql_quote "$id");"
}

# ── read：事务消费（at-least-once，读+推进同一事务）────────────────
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

    if [ "$all" = "1" ]; then
        # 调试/重建：读全部（不推进游标）
        dbq "SELECT json_object('seq',seq,'id',id,'ts',ts,'from',from_agent,'to',to_agent,'type',type,'task',task_id,'ref',ref,'summary',summary)
             FROM messages ORDER BY seq;"
        return 0
    fi

    # at-least-once：只读不推进游标。agent 处理完须显式 `board ack` 推进。
    # 崩溃时游标未推进 → 重读（可能重复，靠消息 id 幂等）。
    dbq "SELECT json_object('seq',seq,'id',id,'ts',ts,'from',from_agent,'to',to_agent,'type',type,'task',task_id,'ref',ref,'summary',summary)
         FROM messages
         WHERE seq > COALESCE((SELECT last_seq FROM consumption WHERE agent=$(sql_quote "$as")), 0)
         ORDER BY seq;"
}

# ── ack：处理完成后推进游标（幂等，只增不减）──────────────────────
# board ack --as X --seq N
board_ack() {
    local as="" seq=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --as) as="$2"; shift 2 ;;
            --seq) seq="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$as" ] && [ -n "$seq" ] || { echo "[board] ack 需要 --as 和 --seq" >&2; return 1; }

    board_init
    # 幂等推进：MAX 防回退（重复 ack 无害）
    db "INSERT INTO consumption(agent,last_seq,updated_at)
        VALUES($(sql_quote "$as"), $seq, $(now_epoch))
        ON CONFLICT(agent) DO UPDATE SET last_seq=MAX(last_seq, excluded.last_seq), updated_at=excluded.updated_at;"
    echo "[board] ack: $as 已确认到 seq=$seq"
}

# ── start：启动新任务（token=1），返回 token ───────────────────────
board_start() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || { echo "[board] start 需要 <task_id>" >&2; return 1; }
    board_init
    local owner="${2:-${BOARD_OWNER:-unknown}}"
    local lease=$(( $(now_epoch) + LEASE_SECONDS ))

    local existing
    existing=$(dbq "SELECT status FROM tasks WHERE task_id=$(sql_quote "$task_id");" 2>/dev/null || true)
    if [ -n "$existing" ]; then
        case "$existing" in
            running)
                # 已在运行：幂等返回现有 token
                dbq "SELECT fencing_token FROM tasks WHERE task_id=$(sql_quote "$task_id");"
                return 0 ;;
            done)
                echo "[board] 拒绝：任务已 done，不可重启（fencing）" >&2; return 1 ;;
            failed)
                # 失败允许重试：重置 running，token 递增
                db "UPDATE tasks SET status='running', fencing_token=fencing_token+1, lease_epoch=$lease,
                    owner=$(sql_quote "$owner"), pid=$$, updated_at=$(now_epoch)
                    WHERE task_id=$(sql_quote "$task_id");"
                dbq "SELECT fencing_token FROM tasks WHERE task_id=$(sql_quote "$task_id");"
                return 0 ;;
        esac
    fi

    # 不存在：INSERT（token=1）
    db "INSERT INTO tasks(task_id,status,fencing_token,lease_epoch,owner,pid,updated_at)
        VALUES($(sql_quote "$task_id"),'running',1,$lease,$(sql_quote "$owner"),$$,$(now_epoch));"
    dbq "SELECT fencing_token FROM tasks WHERE task_id=$(sql_quote "$task_id");"
}

# ── claim：抢占孤儿任务（lease 过期 + grace），RETURNING 新 token ──
board_claim() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || { echo "[board] claim 需要 <task_id>" >&2; return 1; }
    board_init
    local owner="${2:-${BOARD_OWNER:-unknown}}"
    local lease=$(( $(now_epoch) + LEASE_SECONDS ))
    # 判活加 grace period（容忍时钟漂移）；fencing_token+1 才是权威抢占
    local expired_ts=$(( $(now_epoch) - GRACE_SECONDS ))
    db "UPDATE tasks
        SET status='running', fencing_token=fencing_token+1, lease_epoch=$lease,
            owner=$(sql_quote "$owner"), pid=$$, updated_at=$(now_epoch)
        WHERE task_id=$(sql_quote "$task_id") AND status='running' AND lease_epoch < $expired_ts
        RETURNING fencing_token;"
}

# ── state：提交终态（CAS：token 匹配 + lease 未过期）───────────────
board_state() {
    local task_id="${1:-}"; local status="${2:-}"
    [ -n "$task_id" ] && [ -n "$status" ] || { echo "[board] state 需要 <task_id> <done|failed>" >&2; return 1; }

    local verdict="" token="" pid=""
    shift 2 || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --verdict) verdict="$2"; shift 2 ;;
            --token) token="$2"; shift 2 ;;
            --pid) pid="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    # running 别名 → start
    if [ "$status" = "running" ]; then
        board_start "$task_id" "${BOARD_OWNER:-unknown}"
        return $?
    fi

    [ "$status" = "done" ] || [ "$status" = "failed" ] || { echo "[board] state 状态必须是 done|failed" >&2; return 1; }

    board_init
    local now; now=$(now_epoch)

    if [ -n "$token" ]; then
        # fencing CAS：token 匹配 + 当前 running + lease 未过期（UPDATE + changes() 同连接）
        local affected
        affected=$(sqlite3 -bail "$DB" "PRAGMA busy_timeout=5000;
            UPDATE tasks SET status='$status', fencing_token=fencing_token+1, verdict=$(sql_quote "$verdict"), updated_at=$now
            WHERE task_id=$(sql_quote "$task_id") AND fencing_token=$token AND status='running' AND lease_epoch >= $now;
            SELECT changes();" 2>&1 | awk 'NR==1 && $0=="5000" {next} {print}')
        if [ "$affected" != "1" ]; then
            echo "[board] fencing 拒绝：token 不匹配或已失权（旧持有者）" >&2
            return 1
        fi
    else
        # 无 token：宽松提交（兼容旧调用，仅限无竞争场景）
        db "UPDATE tasks SET status='$status', fencing_token=fencing_token+1, verdict=$(sql_quote "$verdict"), updated_at=$now
            WHERE task_id=$(sql_quote "$task_id") AND status='running';"
    fi
}

# ── heartbeat：续租（带 token + lease 未过期）──────────────────────
board_heartbeat() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || { echo "[board] heartbeat 需要 <task_id>" >&2; return 1; }
    shift || true
    local token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --token) token="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    board_init
    local lease now; lease=$(( $(now_epoch) + LEASE_SECONDS )); now=$(now_epoch)
    if [ -n "$token" ]; then
        db "UPDATE tasks SET lease_epoch=$lease, updated_at=$now
            WHERE task_id=$(sql_quote "$task_id") AND fencing_token=$token AND status='running' AND lease_epoch >= $now;"
    else
        db "UPDATE tasks SET lease_epoch=$lease, updated_at=$now
            WHERE task_id=$(sql_quote "$task_id") AND status='running' AND lease_epoch >= $now;"
    fi
}

# ── check：判活（派生 orphaned）────────────────────────────────────
board_check() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || { echo "[board] check 需要 <task_id>" >&2; return 1; }
    board_init
    local row status lease token
    row=$(dbq "SELECT status, COALESCE(lease_epoch,0), fencing_token FROM tasks WHERE task_id=$(sql_quote "$task_id");" 2>/dev/null || true)
    [ -z "$row" ] && { echo "unknown"; return 0; }
    status=$(echo "$row" | cut -d'|' -f1)
    lease=$(echo "$row" | cut -d'|' -f2)
    token=$(echo "$row" | cut -d'|' -f3)
    if [ "$status" = "running" ] && [ -n "$lease" ] && [ "$lease" != "0" ] && [ "$(now_epoch)" -gt "$lease" ]; then
        echo "orphaned token=$token"
    else
        echo "$status"
    fi
}

# ── guard：副作用前置校验（fencing 覆盖到库外副作用）────────────────
# agent 在执行副作用（写文件/调 API）前调用，确认自己仍持有任务权。
# 返回 0=可继续；1=已被抢占/失权，应停止副作用。
# board guard <task_id> --token X
board_guard() {
    local task_id="${1:-}"
    [ -n "$task_id" ] || { echo "[board] guard 需要 <task_id>" >&2; return 1; }
    shift || true
    local token=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --token) token="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    board_init
    local now expired
    now=$(now_epoch)
    expired=$(( now - GRACE_SECONDS ))

    local ok
    ok=$(dbq "SELECT COUNT(*) FROM tasks
              WHERE task_id=$(sql_quote "$task_id") AND status='running' AND lease_epoch >= $expired"
              2>/dev/null || echo 0)
    if [ "$ok" != "1" ]; then
        echo "[board] guard 拒绝：任务已失权（被抢占/过期）" >&2
        return 1
    fi
    if [ -n "$token" ]; then
        local match
        match=$(dbq "SELECT COUNT(*) FROM tasks WHERE task_id=$(sql_quote "$task_id") AND fencing_token=$token" 2>/dev/null || echo 0)
        if [ "$match" != "1" ]; then
            echo "[board] guard 拒绝：fencing token 不匹配（已被抢占）" >&2
            return 1
        fi
    fi
    echo "[board] guard 通过：可继续副作用"
    return 0
}

# ── remember：语义记忆（按 context 去重）───────────────────────────
board_remember() {
    local author="" type="decision" text="" evidence="" status="proposed" context="general"
    while [ $# -gt 0 ]; do
        case "$1" in
            --author) author="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --text) text="$2"; shift 2 ;;
            --evidence) evidence="$2"; shift 2 ;;
            --status) status="$2"; shift 2 ;;
            --context) context="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$author" ] && [ -n "$text" ] || { echo "[board] remember 需要 --author 和 --text" >&2; return 1; }

    board_init
    if db "INSERT INTO memory(context,author,type,text,evidence,status,created_at)
           VALUES($(sql_quote "$context"),$(sql_quote "$author"),$(sql_quote "$type"),$(sql_quote "$text"),$(sql_quote "$evidence"),$(sql_quote "$status"),$(now_epoch));" 2>/dev/null; then
        echo "[board] 已写入语义记忆：${text:0:60}"
    else
        echo "[board] 已存在相同条目，跳过：${text:0:60}"
    fi
}

# ── handoff：写交接文件（文件产物）+ 记消息 ────────────────────────
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
    printf '%s' "$content" > "$file"
    echo "[board] handoff 已写：$file"

    board_write --from "$from" --type handoff --task "$task_id" \
        --ref "handoff/${task_id}.md" --summary "${outcome:-交接完成}" >/dev/null || true
}

# ── export：SQLite → 文件投影（只读，可重建）───────────────────────
board_export() {
    board_init
    mkdir -p "$(dirname "$BUS_FILE")" "$STATE_DIR" "$MEMORY_DIR"

    # bus/log.ndjson（消息投影）
    dbq "SELECT json_object('seq',seq,'id',id,'ts',ts,'from',from_agent,'to',to_agent,'type',type,'task',task_id,'ref',ref,'summary',summary)
         FROM messages ORDER BY seq;" > "$BUS_FILE"

    # state/*.json（任务状态投影）
    local f
    while IFS='|' read -r task_id status token verdict lease owner; do
        f="$STATE_DIR/${task_id}.json"
        if has_jq; then
            jq -cn --arg id "$task_id" --arg status "$status" --argjson token "$token" \
                --arg verdict "$verdict" --arg lease "$lease" --arg owner "$owner" \
                '{id:$id,status:$status,fencing_token:$token,verdict:$verdict,lease_epoch:$lease,owner:$owner}' > "$f"
        else
            printf '{"id":"%s","status":"%s","fencing_token":%s,"verdict":"%s","lease_epoch":"%s","owner":"%s"}\n' \
                "$task_id" "$status" "$token" "$verdict" "$lease" "$owner" > "$f"
        fi
    done < <(dbq "SELECT task_id,status,fencing_token,COALESCE(verdict,''),COALESCE(lease_epoch,0),COALESCE(owner,'') FROM tasks;")

    # memory/decisions.md（语义记忆投影）
    dbq "SELECT '## '||type||': '||substr(text,1,80)||char(10)||'- 文本: '||text||char(10)||'- 作者: '||author||char(10)||'- 状态: '||COALESCE(status,'')||char(10)
         FROM memory ORDER BY id;" > "$DECISIONS_FILE"

    echo "[board] export 完成：投影已从 board.db 重建"
}

# ── compact：WAL checkpoint（释放空间）+ 重建投影 ──────────────────
board_compact() {
    board_init
    sqlite3 "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
    board_export
    echo "[board] compact 完成：WAL 已 checkpoint，投影已重建"
}

# ── search：检索（优先 SQLite LIKE，回退 grep 投影）────────────────
board_search() {
    board_init
    local kw="${1:-}"
    [ -n "$kw" ] || { echo "[board] search 需要关键词" >&2; return 1; }
    local hits
    hits=$(dbq "SELECT 'msg seq='||seq||': '||summary FROM messages WHERE summary LIKE '%'||$(sql_quote "$kw")||'%'
                UNION ALL
                SELECT 'memory: '||text FROM memory WHERE text LIKE '%'||$(sql_quote "$kw")||'%'
                LIMIT 50;" 2>/dev/null || true)
    if [ -n "$hits" ]; then
        echo "$hits"
    else
        echo "[board] 无匹配"
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
        ack)        shift; board_ack "$@" ;;
        start)      shift; board_start "$@" ;;
        claim)      shift; board_claim "$@" ;;
        state)      shift; board_state "$@" ;;
        heartbeat)  shift; board_heartbeat "$@" ;;
        check)      shift; board_check "$@" ;;
        guard)      shift; board_guard "$@" ;;
        remember)   shift; board_remember "$@" ;;
        handoff)    shift; board_handoff "$@" ;;
        export)     shift; board_export "$@" ;;
        compact)    shift; board_compact "$@" ;;
        search)     shift; board_search "$@" ;;
        agents)     shift; board_agents "$@" ;;
        help|"")
            cat <<'HELP'
board.sh <command> [args]   (v4 · SQLite)

  init                          建 SQLite schema + 目录
  write  --from X --to Y --type T --task ID [--ref P] [--summary S]   (返回 seq)
  read   --as NAME [--all]      读消息（不推进游标；处理完 ack）
  ack    --as NAME --seq N      确认消费到 seq=N（幂等推进）
  start  <task_id> [owner]      启动任务（token=1），返回 token
  claim  <task_id> [owner]      抢占孤儿任务（lease 过期+grace），RETURNING 新 token
  state  <task_id> <done|failed> [--token T] [--verdict V]   (fencing CAS 提交)
  heartbeat <task_id> [--token T]
  guard  <task_id> [--token T]  副作用前置校验（返回 0=可继续，1=已失权）
  check  <task_id>              判活：running|done|failed|orphaned|unknown
  remember --author X --text T [--context C --type T --status S]
  handoff <task_id> --from X [--outcome O ...]
  export                        从 SQLite 重建文件投影（只读）
  compact                       WAL checkpoint + 重建投影
  search <kw>                   SQLite LIKE 检索
  agents                        列出名片卡
HELP
            ;;
        *) echo "[board] 未知命令: $1" >&2; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    board_main "$@"
fi
