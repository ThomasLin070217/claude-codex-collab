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

# SQL 字符串转义（单引号 → 两单引号）。
# 注意：bash 3.2（macOS 默认）下 ${s//\'/\'\'} 会错误产生反斜杠，故用变量 q 承载单引号。
sql_quote() {
    local s="$1" q="'"
    s="${s//$q/$q$q}"
    printf "'%s'" "$s"
}

# 校验非负整数（防 SQL 注入：token/seq/priority 等数字字段拼接前必须过这里）
is_int() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# IDs used in filenames and line-oriented routing must remain a single component.
valid_task_id() {
    case "$1" in
        ''|.|..|*/*|*\\*|*'|'*|*$'\n'*|*$'\r'*)
            echo "[board] invalid task_id: expected a single path component" >&2; return 1 ;;
    esac
}

# db：执行写/更新（PRAGMA busy_timeout 更可靠；awk 滤掉其返回值 "5000"）
# 注意用 PIPESTATUS 保留 sqlite3 的真实退出码，供 || 错误处理。
db() {
    sqlite3 -bail "$DB" "PRAGMA busy_timeout=5000; $1" 2>&1 | awk 'NR==1 && $0=="5000" {next} {print}'
    return "${PIPESTATUS[0]}"
}

# dbq：查询，返回 stdout（同样滤掉 PRAGMA 返回值）
dbq() {
    sqlite3 -bail "$DB" "PRAGMA busy_timeout=5000; $1" 2>&1 | awk 'NR==1 && $0=="5000" {next} {print}'
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

    sqlite3 -bail "$DB" >/dev/null <<'SQL' || return 1
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

CREATE TABLE IF NOT EXISTS jobs (
    job_id        TEXT PRIMARY KEY,
    type          TEXT NOT NULL,                       -- 能力类型（plan/execute/review/...）
    payload       TEXT,                                -- 任务内容
    deps          TEXT NOT NULL DEFAULT '',            -- 依赖的 job_id，逗号分隔（空=无依赖）
    owner_session TEXT,
    assigned_to   TEXT,                                -- 指派的 agent
    status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','ready','running','done','failed','dead')),
    priority      INTEGER NOT NULL DEFAULT 0,
    attempts      INTEGER NOT NULL DEFAULT 0,
    max_attempts  INTEGER NOT NULL DEFAULT 3,
    fencing_token INTEGER NOT NULL DEFAULT 0,          -- 执行权（fencing）
    lease_epoch   INTEGER,
    verdict       TEXT,
    result        TEXT,                                -- 幂等结果（--effect），done 时由触发器写入 job_effects
    created_at    INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    updated_at    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status, priority);

-- 依赖关系表（精确等值匹配，避免 deps 逗号串的 LIKE 通配符/缺失依赖放行问题）
CREATE TABLE IF NOT EXISTS job_deps (
    job_id  TEXT NOT NULL,
    dep_id  TEXT NOT NULL,
    PRIMARY KEY (job_id, dep_id)
);

-- Abort the entire creation transaction, including the new job, on a cycle.
CREATE TRIGGER IF NOT EXISTS job_deps_acyclic BEFORE INSERT ON job_deps
BEGIN
    SELECT RAISE(ROLLBACK, 'job dependency cycle') WHERE NEW.job_id=NEW.dep_id
      OR EXISTS (
        WITH RECURSIVE ancestors(id) AS (
          SELECT NEW.dep_id
          UNION
          SELECT d.dep_id FROM job_deps d JOIN ancestors a ON d.job_id=a.id
        ) SELECT 1 FROM ancestors WHERE id=NEW.job_id
      );
END;

-- The demo effect is stored atomically with completion; job_id is its stable idempotency key.
CREATE TABLE IF NOT EXISTS job_effects (
    job_id TEXT PRIMARY KEY,
    result TEXT NOT NULL
);

-- agent 健康表（区分「能力声明」vs「在线状态」；scheduler 只派发给在线 agent）
CREATE TABLE IF NOT EXISTS agents (
    agent      TEXT PRIMARY KEY,
    session    TEXT NOT NULL,             -- 每次启动的会话 id
    expires    INTEGER NOT NULL,          -- 健康到期（epoch），到期即视为离线
    updated_at INTEGER NOT NULL
);

-- 认领即派发：UPDATE jobs（ready→running）后原子插入派发消息。
-- 用触发器而非多语句事务，因为 sqlite3 CLI 的多语句事务在中间出错时回滚不可靠；
-- 触发器内失败会连认领一起回滚（语句级原子）。
CREATE TRIGGER IF NOT EXISTS dispatch_on_claim
AFTER UPDATE OF status ON jobs
WHEN NEW.status='running' AND OLD.status='ready'
BEGIN
    INSERT INTO messages(id,ts,from_agent,to_agent,type,task_id,summary)
    VALUES('dispatch:'||NEW.job_id||':'||NEW.fencing_token,
           strftime('%s','now'), 'scheduler', NEW.assigned_to, 'task', NEW.job_id,
           'token='||NEW.fencing_token);
END;

-- 建 job 即拆 deps：INSERT jobs 后原子拆分逗号分隔的 deps 写入 job_deps。
-- 拆分失败（如注入的触发器）会连 INSERT jobs 一起回滚。
CREATE TRIGGER IF NOT EXISTS split_deps_on_insert
AFTER INSERT ON jobs
WHEN NEW.deps IS NOT NULL AND NEW.deps != ''
BEGIN
    INSERT OR IGNORE INTO job_deps(job_id, dep_id)
    WITH RECURSIVE split(job_id, dep, rest) AS (
        SELECT NEW.job_id, '', NEW.deps || ','
        UNION ALL
        SELECT job_id,
               substr(rest, 1, instr(rest, ',') - 1),
               substr(rest, instr(rest, ',') + 1)
        FROM split WHERE rest != ''
    )
    SELECT job_id, dep FROM split WHERE dep != '';
END;

-- 完成即记结果：UPDATE jobs（status→done）后原子把 result 写入 job_effects。
-- 记录失败会连状态更新一起回滚，保证「结果」与「完成」同生共死。
CREATE TRIGGER IF NOT EXISTS record_effect_on_done
AFTER UPDATE OF status ON jobs
WHEN NEW.status='done' AND NEW.result IS NOT NULL AND NEW.result != ''
BEGIN
    INSERT OR IGNORE INTO job_effects(job_id, result) VALUES(NEW.job_id, NEW.result);
END;
SQL
    # Upgrade existing databases; a concurrent initializer may have added it already.
    if ! dbq "SELECT name FROM pragma_table_info('jobs');" | grep -qx owner_session; then
        db "ALTER TABLE jobs ADD COLUMN owner_session TEXT;" >/dev/null 2>&1 || {
            dbq "SELECT name FROM pragma_table_info('jobs');" | grep -qx owner_session || return 1
        }
    fi
    if ! dbq "SELECT name FROM pragma_table_info('jobs');" | grep -qx result; then
        db "ALTER TABLE jobs ADD COLUMN result TEXT;" >/dev/null 2>&1 || {
            dbq "SELECT name FROM pragma_table_info('jobs');" | grep -qx result || return 1
        }
    fi

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

# ── read：读消息（at-least-once，只读不推进；--to 过滤定向消息）────
board_read() {
    local as="" all=0 to=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --as) as="$2"; shift 2 ;;
            --all) all=1; shift ;;
            --to) to="$2"; shift 2 ;;
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
    # --to：只读发给自己的（或广播 to 为空）的消息，避免吃掉别人的。
    local where
    where="seq > COALESCE((SELECT last_seq FROM consumption WHERE agent=$(sql_quote "$as")), 0)"
    if [ -n "$to" ]; then
        where="$where AND (to_agent=$(sql_quote "$to") OR to_agent='' OR to_agent IS NULL)"
    fi
    dbq "SELECT json_object('seq',seq,'id',id,'ts',ts,'from',from_agent,'to',to_agent,'type',type,'task',task_id,'ref',ref,'summary',summary)
         FROM messages
         WHERE $where
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
    is_int "$seq" || { echo "[board] ack 的 --seq 必须是非负整数" >&2; return 1; }

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
    valid_task_id "$task_id" || return 1
    board_init || return 1
    local owner="${2:-${BOARD_OWNER:-unknown}}" token
    local now; now=$(now_epoch)
    local lease=$(( now + LEASE_SECONDS ))
    # Single transaction: no gap between status/owner checks and token retrieval.
    token=$(db "BEGIN IMMEDIATE;
        INSERT INTO tasks(task_id,status,fencing_token,lease_epoch,owner,pid,updated_at)
        VALUES($(sql_quote "$task_id"),'running',1,$lease,$(sql_quote "$owner"),$$,$now)
        ON CONFLICT(task_id) DO UPDATE SET status='running',
            fencing_token=tasks.fencing_token+1, lease_epoch=$lease,
            owner=excluded.owner,pid=excluded.pid,updated_at=$now
        WHERE tasks.status='failed';
        SELECT fencing_token FROM tasks WHERE task_id=$(sql_quote "$task_id")
          AND status='running' AND owner=$(sql_quote "$owner") AND lease_epoch >= $now;
        COMMIT;") || return 1
    is_int "$token" && [ "$token" -gt 0 ] || {
        echo "[board] start 拒绝：非本人、已完成或租约过期" >&2; return 1;
    }
    printf '%s\n' "$token"
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

    # fencing 必须带 token（去掉宽松分支，防绕过 fencing）
    is_int "$token" || { echo "[board] state 的 --token 必须是非负整数（fencing 必需）" >&2; return 1; }

    board_init
    local now; now=$(now_epoch)

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
    is_int "$token" || { echo "[board] heartbeat 的 --token 必须是非负整数" >&2; return 1; }
    local lease now; lease=$(( $(now_epoch) + LEASE_SECONDS )); now=$(now_epoch)
    db "UPDATE tasks SET lease_epoch=$lease, updated_at=$now
        WHERE task_id=$(sql_quote "$task_id") AND fencing_token=$token AND status='running' AND lease_epoch >= $now;"
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

    is_int "$token" || { echo "[board] guard requires --token" >&2; return 1; }
    board_init || return 1
    local ok
    ok=$(dbq "SELECT COUNT(*) FROM tasks WHERE task_id=$(sql_quote "$task_id")
        AND status='running' AND fencing_token=$token AND lease_epoch >= $(now_epoch);") || return 1
    [ "$ok" = 1 ] || { echo "[board] guard 拒绝：已失权" >&2; return 1; }
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
    valid_task_id "$task_id" || return 1
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
        valid_task_id "$task_id" || return 1
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

# ═════════════════════════════════════════════════════════════════
#  N-agent 调度（jobs：依赖图 + 能力路由 + fencing + 死信）
# ═════════════════════════════════════════════════════════════════

# job-create：创建任务（依赖逗号分隔，空=无依赖）
# board job-create --id X --type T [--payload P --deps "a,b" --priority N]
board_job_create() {
    local id="" type="" payload="" deps="" priority=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --payload) payload="$2"; shift 2 ;;
            --deps) deps="$2"; shift 2 ;;
            --priority) priority="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -n "$id" ] && [ -n "$type" ] || { echo "[board] job-create 需要 --id 和 --type" >&2; return 1; }
    is_int "$priority" || { echo "[board] job-create 的 --priority 必须是非负整数" >&2; return 1; }
    valid_task_id "$id" || return 1
    board_init || return 1
    case "$deps" in *$'\n'*|*$'\r'*) echo "[board] deps must be a single line" >&2; return 1 ;; esac
    # 校验每个 dep 的 task_id 格式（环/自环由 job_deps_acyclic 触发器在插入时拒绝）
    local d
    IFS=',' read -r -a dep_list <<< "$deps"
    for d in "${dep_list[@]+"${dep_list[@]}"}"; do
        [ -n "$d" ] || continue
        valid_task_id "$d" || return 1
    done
    # 单条 INSERT jobs；split_deps_on_insert 触发器原子拆分 deps 写 job_deps，
    # job_deps_acyclic 触发器拒绝环/自环——任一失败都会连 INSERT jobs 一起回滚。
    db "INSERT INTO jobs(job_id,type,payload,deps,priority)
        VALUES($(sql_quote "$id"),$(sql_quote "$type"),$(sql_quote "$payload"),$(sql_quote "$deps"),$priority);" || return 1
    # 依赖已 dead 的新 job 立即标 dead（传播）
    db "$(job_dead_sql)"
}

# Recursive propagation also handles jobs created after an ancestor died.
job_dead_sql() {
    cat <<'SQL'
WITH RECURSIVE blocked(id) AS (
    SELECT job_id FROM jobs WHERE status='dead'
    UNION
    SELECT d.job_id FROM job_deps d JOIN blocked b ON d.dep_id=b.id
)
UPDATE jobs SET status='dead', verdict='dependency dead',
    fencing_token=fencing_token+1, lease_epoch=NULL, owner_session=NULL,
    assigned_to=NULL, updated_at=strftime('%s','now')
WHERE job_id IN (SELECT id FROM blocked) AND status IN ('pending','ready','running','failed');
SQL
}

# job-ready：把依赖已满足的 pending 标记为 ready（scheduler 调用）
board_job_ready() {
    board_init
    # 依赖满足：job_deps 里每个 dep 都存在（LEFT JOIN 非空）且 status='done'
    # 缺失依赖 → dj.job_id IS NULL → NOT EXISTS 为 false → 不放行
    db "BEGIN IMMEDIATE; $(job_dead_sql) UPDATE jobs SET status='ready', updated_at=$(now_epoch)
        WHERE status='pending'
          AND NOT EXISTS (
            SELECT 1 FROM job_deps d
            LEFT JOIN jobs dj ON dj.job_id = d.dep_id
            WHERE d.job_id = jobs.job_id
              AND (dj.job_id IS NULL OR dj.status != 'done')
          ); COMMIT;" || return 1
    dbq "SELECT job_id FROM jobs WHERE status='ready' ORDER BY priority DESC, created_at ASC;"
}

# job-claim：调度器认领 job（ready→running，fencing_token+1，设 lease）
# board job-claim --id X --agent A
board_job_claim() {
    local id="" agent="" limit="${MAX_INFLIGHT_PER_AGENT:-1}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            *) echo "[board] unknown claim option: $1" >&2; return 1 ;;
        esac
    done
    [ -n "$id" ] && [ -n "$agent" ] || return 1
    is_int "$limit" && [ "$limit" -gt 0 ] || return 1
    board_init || return 1
    local now lease token
    now=$(now_epoch); lease=$(( now + LEASE_SECONDS ))
    # 单条 UPDATE 认领；dispatch_on_claim 触发器在同一事务里原子插入派发消息。
    # 触发器失败会连认领一起回滚（job 回到 ready），避免「认领成功但没派发」的卡死。
    token=$(db "UPDATE jobs SET status='running', assigned_to=$(sql_quote "$agent"),
            owner_session=(SELECT session FROM agents WHERE agent=$(sql_quote "$agent")),
            fencing_token=fencing_token+1, lease_epoch=$lease, updated_at=$now
        WHERE job_id=$(sql_quote "$id") AND status='ready'
          AND EXISTS (SELECT 1 FROM agents WHERE agent=$(sql_quote "$agent") AND expires > $now)
          AND (SELECT COUNT(*) FROM jobs WHERE assigned_to=$(sql_quote "$agent") AND status='running') < $limit
        RETURNING fencing_token;") || return 1
    is_int "$token" && [ "$token" -gt 0 ] || return 1
    printf '%s\n' "$token"
}

# All execution operations require the full grant: job, agent, session, token,
# unexpired lease AND current agent health. No optional-owner bypass.
board_job_owned() {
    local action="$1"; shift
    local id="" token="" agent="" session="" verdict="" effect=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --id) id="$2"; shift 2 ;;
            --token) token="$2"; shift 2 ;;
            --agent) agent="$2"; shift 2 ;;
            --session) session="$2"; shift 2 ;;
            --verdict) verdict="$2"; shift 2 ;;
            --effect) effect="$2"; shift 2 ;;
            *) echo "[board] unknown job option: $1" >&2; return 1 ;;
        esac
    done
    [ -n "$id" ] && [ -n "$agent" ] && [ -n "$session" ] && is_int "$token" || return 1
    board_init || return 1
    local now predicate statement affected
    now=$(now_epoch)
    predicate="job_id=$(sql_quote "$id") AND status='running' AND fencing_token=$token
        AND lease_epoch >= $now AND assigned_to=$(sql_quote "$agent")
        AND owner_session=$(sql_quote "$session")
        AND EXISTS (SELECT 1 FROM agents a WHERE a.agent=jobs.assigned_to
                    AND a.session=jobs.owner_session AND a.expires > $now)"
    case "$action" in
        guard) statement="SELECT COUNT(*) FROM jobs WHERE $predicate;" ;;
        heartbeat) statement="UPDATE jobs SET lease_epoch=$((now + LEASE_SECONDS)), updated_at=$now
                             WHERE $predicate; SELECT changes();" ;;
        done)
            # 单条 UPDATE 标记 done + 存 result；record_effect_on_done 触发器
            # 原子把 result 写入 job_effects（记录失败会连状态更新一起回滚）。
            statement="UPDATE jobs SET status='done',result=$(sql_quote "$effect"),verdict=$(sql_quote "$verdict"),updated_at=$now
                WHERE $predicate; SELECT changes();" ;;
        fail)
            statement="UPDATE jobs SET attempts=attempts+1,
                status=CASE WHEN attempts+1 >= max_attempts THEN 'dead' ELSE 'pending' END,
                fencing_token=fencing_token+1,lease_epoch=NULL,owner_session=NULL,assigned_to=NULL,
                verdict=$(sql_quote "$verdict"),updated_at=$now
                WHERE $predicate; SELECT changes(); $(job_dead_sql)" ;;
        *) return 1 ;;
    esac
    affected=$(db "BEGIN IMMEDIATE; $statement COMMIT;") || return 1
    [ "$affected" = 1 ] || { echo "[board] job-$action 拒绝：token/session/租约/健康不匹配" >&2; return 1; }
}
board_job_guard() { board_job_owned guard "$@"; }
board_job_heartbeat() { board_job_owned heartbeat "$@"; }
board_job_done() { board_job_owned done "$@"; }
board_job_fail() { board_job_owned fail "$@"; }

# Reclaim expired leases, lost agents and replaced sessions; revoke old tokens.
board_job_reap() {
    board_init || return 1
    local now; now=$(now_epoch)
    db "BEGIN IMMEDIATE;
        UPDATE jobs SET attempts=attempts+1,
            status=CASE WHEN attempts+1 >= max_attempts THEN 'dead' ELSE 'pending' END,
            fencing_token=fencing_token+1, assigned_to=NULL, owner_session=NULL,
            lease_epoch=NULL, updated_at=$now
        WHERE status='running' AND (COALESCE(lease_epoch,0) < $now
            OR NOT EXISTS (SELECT 1 FROM agents a WHERE a.agent=jobs.assigned_to
                           AND a.session=jobs.owner_session AND a.expires > $now));
        $(job_dead_sql) COMMIT;"
}

# job-list：列 job（可过滤状态）
board_job_list() {
    local status=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --status) status="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    board_init
    if [ -n "$status" ]; then
        dbq "SELECT job_id||'|'||type||'|'||status||'|'||COALESCE(assigned_to,'-')||'|'||attempts FROM jobs WHERE status=$(sql_quote "$status") ORDER BY created_at;"
    else
        dbq "SELECT job_id||'|'||type||'|'||status||'|'||COALESCE(assigned_to,'-')||'|'||attempts FROM jobs ORDER BY created_at;"
    fi
}

# ── agent 健康（区分能力声明 vs 在线状态）──────────────────────────
# agent-heartbeat：注册/续期。worker 启动时调用，之后定期续期。
# board agent-heartbeat --agent X --session S [--ttl N]
board_agent_heartbeat() {
    local agent="" session="" ttl=30 register=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --agent) agent="$2"; shift 2 ;;
            --session) session="$2"; shift 2 ;;
            --ttl) ttl="$2"; shift 2 ;;
            --register) register=1; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$agent" ] && [ -n "$session" ] || { echo "[board] agent-heartbeat 需要 --agent 和 --session" >&2; return 1; }
    is_int "$ttl" || { echo "[board] --ttl 必须是非负整数" >&2; return 1; }
    board_init
    local expires=$(( $(now_epoch) + ttl ))
    local affected
    affected=$(db "INSERT INTO agents(agent,session,expires,updated_at) VALUES($(sql_quote "$agent"),$(sql_quote "$session"),$expires,$(now_epoch))
        ON CONFLICT(agent) DO UPDATE SET session=excluded.session, expires=excluded.expires, updated_at=excluded.updated_at
        WHERE agents.session=excluded.session OR $register=1;
        SELECT changes();") || return 1
    [ "$affected" = 1 ] || { echo "[board] agent session replaced" >&2; return 1; }
}

# agents-online：列在线 agent（expires > now），供 scheduler 路由时只选在线者
board_agents_online() {
    board_init
    dbq "SELECT agent||'|'||session FROM agents WHERE expires > $(now_epoch) ORDER BY agent;"
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
        agent-heartbeat) shift; board_agent_heartbeat "$@" ;;
        agents-online)   shift; board_agents_online "$@" ;;
        job-create) shift; board_job_create "$@" ;;
        job-ready)  shift; board_job_ready "$@" ;;
        job-claim)  shift; board_job_claim "$@" ;;
        job-guard)  shift; board_job_guard "$@" ;;
        job-heartbeat) shift; board_job_heartbeat "$@" ;;
        job-done)   shift; board_job_done "$@" ;;
        job-fail)   shift; board_job_fail "$@" ;;
        job-reap)   shift; board_job_reap "$@" ;;
        job-list)   shift; board_job_list "$@" ;;
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
  guard  <task_id> --token T  副作用前置校验（返回 0=可继续，1=已失权）
  check  <task_id>              判活：running|done|failed|orphaned|unknown
  remember --author X --text T [--context C --type T --status S]
  handoff <task_id> --from X [--outcome O ...]
  export                        从 SQLite 重建文件投影（只读）
  compact                       WAL checkpoint + 重建投影
  search <kw>                   SQLite LIKE 检索
  agents                        列出名片卡
  agent-heartbeat --agent A --session S [--ttl N] [--register]
                                启动时 --register，续期时省略（禁止旧 session 抢回）
  job-create --id X --type T [--deps a,b --payload P --priority N]
  job-ready                     更新 ready / 递归传播 dead
  job-claim --id X --agent A     原子认领并发消息；默认每 agent 最多 1 个在途
  job-guard|job-heartbeat|job-done|job-fail
      --id X --agent A --session S --token T [--verdict V]
  job-done ... [--effect RESULT] 原子记录幂等结果（job_id 唯一）并完成
  job-reap                      回收过期 lease / 失联或被替换的 session
  job-list [--status STATUS]
HELP
            ;;
        *) echo "[board] 未知命令: $1" >&2; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    board_main "$@"
fi
