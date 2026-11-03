# V4 架构设计：SQLite 事务核心 + 文件投影层

> 触发条件：三个独立模型（自建 Codex、DSH subagent Codex、DSH subagent Claude）对 v3 复盘时**独立收敛到同一结论**——bash + 文件黑板扛不住分布式一致性（split-brain / 幂等 / fencing），一致建议用 SQLite 事务队列 + fencing token + 幂等键。V4 落实这个结论。

---

## 0. 结论先行

**把「强一致」从 bash + 文件黑板下沉到 SQLite（WAL），board.sh 文件层退化为「人可读审计投影」。**

- 谁持有真相：**SQLite**（source of truth，事务保证）
- 谁负责可读/可追溯：**board.sh 文件投影**（人可 `cat`/`grep`，agent 可直读，随时可从 SQLite 重建）

这样既满足三个模型「换 SQLite」的建议，又不丢你「文件系统即状态、随时能看懂」的初衷。

---

## 1. 为什么必须 V4

| 缺陷 | v3.1 的缓解 | 为什么不够 |
|---|---|---|
| split-brain（双执行） | 锁 token + 状态转换防护 | 锁的 fencing 是「尽力」；状态防护只挡「终态回 running」，挡不住「两个 running 并存」 |
| 幂等 | seen-set 文件 | 文件追加非事务，崩溃窗口仍可能重复 |
| 顺序/背压 | seq 字段 | seq 是「读到的行数 +1」，无事务保证，并发下可能重复 |
| 租约 | lease_epoch 文件 | 无原子抢占，lease 过期后旧进程仍能写 |

**根因**：文件系统提供的是「最终一致 + 无事务」的存储，而 N-agent 协作需要「线性一致 + 事务 + 原子 CAS」。这是存储介质的能力边界，不是 bash 写得不够好。

---

## 2. 核心决策表

| 关注点 | v3.1（现状） | v4 |
|---|---|---|
| 消息队列 | append-only ndjson | `messages` 表（`seq` 主键 + `id UNIQUE`） |
| 消费进度 | 字节偏移游标文件 | `consumption` 表，事务内推进 `last_seq` |
| 幂等 | seen-set 文件 | `id UNIQUE` 约束 + 消费事务 |
| 租约/判活 | lease_epoch 文件 | `tasks` 表 `lease_epoch` + `fencing_token` |
| split-brain | 状态转换防护（尽力） | **fencing token CAS**（WHERE token=? 匹配才写） |
| 可读/审计 | 文件即状态 | board.sh **export** 投影（只读、可重建） |

---

## 3. 架构分层

```
┌────────────────────────────────────────────┐
│  agent（Claude Code / Codex / Cursor / …） │
└───────────────────┬────────────────────────┘
                    │ board.sh CLI（接口不变，agent 无感）
┌───────────────────▼────────────────────────┐
│  SQLite (WAL)  —— source of truth          │
│  messages / consumption / tasks / memory   │
│  （事务 + 幂等 + fencing token + 顺序）      │
└───────────────────┬────────────────────────┘
                    │ export（只读、幂等重建）
┌───────────────────▼────────────────────────┐
│  文件投影层（人可读 / grep / agent 直读）    │
│  bus/log.ndjson · state/*.json ·           │
│  memory/decisions.md · handoff/*.md        │
└────────────────────────────────────────────┘
```

---

## 4. SQLite Schema（WAL 模式）

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

-- 消息队列（强一致核心）
CREATE TABLE IF NOT EXISTS messages (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,  -- 单调递增序号（顺序）
    id          TEXT NOT NULL UNIQUE,               -- 幂等键
    ts          TEXT NOT NULL,
    from_agent  TEXT NOT NULL,
    to_agent    TEXT,
    type        TEXT NOT NULL,
    task_id     TEXT,
    ref         TEXT,                               -- 文件指针（payload 不内嵌）
    summary     TEXT,
    payload_hash TEXT,                              -- 内容哈希（关联不可变产物）
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- 消费进度（事务提交，幂等）
CREATE TABLE IF NOT EXISTS consumption (
    agent       TEXT PRIMARY KEY,
    last_seq    INTEGER NOT NULL DEFAULT 0,
    updated_at  TEXT NOT NULL
);

-- 任务状态 + fencing token
CREATE TABLE IF NOT EXISTS tasks (
    task_id       TEXT PRIMARY KEY,
    status        TEXT NOT NULL,                     -- running|done|failed
    fencing_token INTEGER NOT NULL DEFAULT 0,        -- 单调递增，写操作 CAS
    lease_epoch   INTEGER,                           -- 租约到期（epoch 秒）
    verdict       TEXT,
    pid           INTEGER,
    updated_at    TEXT NOT NULL
);

-- 语义记忆（provenance + 去重）
CREATE TABLE IF NOT EXISTS memory (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    author      TEXT NOT NULL,
    type        TEXT NOT NULL,
    text        TEXT NOT NULL,
    evidence    TEXT,
    status      TEXT,
    created_at  TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS memory_text ON memory(text);
```

---

## 5. fencing token 机制（治 split-brain 的正解）

每个 task 持有一个单调递增的 `fencing_token`。**所有写操作都带 token，用 CAS 更新**：

```sql
-- 抢占（新持有者）
UPDATE tasks SET fencing_token = fencing_token + 1, status='running'
WHERE task_id = ? AND status = 'orphaned';

-- 提交（旧持有者写终态，token 必须匹配）
UPDATE tasks SET status='done', fencing_token = fencing_token + 1
WHERE task_id = ? AND fencing_token = ?;   -- ← 旧 token 匹配才成功
-- 若影响 0 行 → 说明已被抢占 → 拒绝写入 → 双执行被挡住
```

**语义**：lease 过期后，新持有者 `token+1` 抢占；旧持有者再写时 token 已不匹配 → 0 行受影响 → 拒绝。这就是三个模型反复强调的 fencing token。

---

## 6. 幂等机制（治重复执行）

1. **插入幂等**：`messages.id UNIQUE`，重复插入抛约束冲突 → 忽略；
2. **消费幂等**：`BEGIN; SELECT * FROM messages WHERE seq > last_seq; UPDATE consumption SET last_seq=?; COMMIT;` —— at-least-once 投递 + 按 seq 幂等；
3. **副作用幂等**：外部操作（写代码/发请求）携带 `payload_hash`，接收方按哈希去重。

---

## 7. board.sh 的定位变化

- **接口不变**：`board.sh write/read/state/check/...` 命令照旧，agent 无感；
- **真相转移**：写入一律走 SQLite 事务；文件层变成**只读投影**；
- **新增 `board.sh export`**：从 SQLite 重新生成 `bus/log.ndjson`、`state/*.json`、`memory/decisions.md`——文件永远是镜像，删了也能重建，审计/可读性不丢；
- 人依然可以 `cat bus/log.ndjson` 或 `grep` 决策，但改文件不再影响真相。

---

## 8. 迁移路径（v3.1 → v4）

1. `board.sh` 内部检测 `sqlite3`（macOS 自带 `/usr/bin/sqlite3`，Linux 一般也有）；
2. 所有写命令（write/state/heartbeat/remember/handoff）改为 SQLite 事务 + fencing；
3. `read` 改为「SQLite 读 last_seq 之后」+ 事务推进；
4. 文件层改为 `export` 投影，CLI 接口不变；
5. **先过四类故障注入测试再扩 N**：
   - `kill -9` 中断写/消费/持锁各阶段 → 恢复后不丢消息、不重复；
   - 暂停（SIGSTOP）后恢复 → 租约/fencing 正确；
   - 并发抢占（两进程抢同一 task）→ 只有一个生效；
   - 重放（重跑已消费日志）→ 幂等，无重复副作用。

---

## 9. 与 N-agent 的关系

V4 是 N-agent 的地基：有了 SQLite 的 `seq`（顺序）+ `fencing_token`（抢占）+ `UNIQUE id`（幂等），N 个 agent 并发读写的顺序、抢占、去重都有事务保证，**不再依赖「单写者锁 + 文件约定」这种弱约束**。

这也是三个模型一致强调的路线：**「先过故障注入，再扩 N」**——v3.1 修的是单机正确性，V4 才真正补上分布式正确性，之后接 N-agent 才有意义。
