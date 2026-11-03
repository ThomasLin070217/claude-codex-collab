# V4 详细设计（最终版）

> 本文件是 V4 的落地级设计，已整合**三方 Codex 评审**（schema/幂等、fencing/故障注入、N-agent）的修正意见。修正点以 `[Codex]` 标注。高层决策见 [v4-architecture.md](v4-architecture.md)。

---

## 1. 设计目标

1. **强一致下沉 SQLite**：消息顺序、消费进度、租约抢占、幂等去重，全部由 SQLite 事务保证。
2. **CLI 接口不变**：agent 无感迁移，v3.1 → v4 平滑。
3. **可读性不丢**：文件投影从 SQLite 重建，人依然能 `cat`/`grep`。
4. **先过故障注入再扩 N**：8 项测试（已按 Codex 扩充）全过后才接 N-agent。

---

## 2. SQLite Schema（最终）

数据库：`$COLLAB_DIR/board.db`

```sql
-- 每连接均设
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=FULL;          -- [Codex] NORMAL 断电可丢已提交事务，协作消息不能丢
PRAGMA foreign_keys=ON;

-- ① 消息队列
CREATE TABLE IF NOT EXISTS messages (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,   -- 顺序；AUTOINCREMENT 保证删除后不复用
    id           TEXT NOT NULL UNIQUE,                -- 幂等键（同 id 异内容=报错，见 §5）
    ts           INTEGER NOT NULL,                    -- [Codex] epoch 整数，排序只认 seq 不认时间
    from_agent   TEXT NOT NULL,
    to_agent     TEXT,
    type         TEXT NOT NULL,
    task_id      TEXT,
    ref          TEXT,                                -- 文件指针（payload 不内嵌）
    summary      TEXT,
    payload_hash TEXT,
    created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);
CREATE INDEX IF NOT EXISTS idx_messages_task ON messages(task_id, seq);
CREATE INDEX IF NOT EXISTS idx_messages_to   ON messages(to_agent, seq);  -- [Codex] 按接收者+顺序

-- ② 消费进度（事务推进 = 幂等消费）
CREATE TABLE IF NOT EXISTS consumption (
    agent       TEXT PRIMARY KEY,
    last_seq    INTEGER NOT NULL DEFAULT 0,
    updated_at  INTEGER NOT NULL
);

-- ③ 任务状态 + fencing
CREATE TABLE IF NOT EXISTS tasks (
    task_id       TEXT PRIMARY KEY,
    status        TEXT NOT NULL CHECK (status IN ('running','done','failed')),  -- [Codex] 状态约束
    fencing_token INTEGER NOT NULL DEFAULT 0,          -- 单调递增，永不回退、永不删行
    lease_epoch   INTEGER,                             -- 租约到期（epoch 秒）
    owner         TEXT,                                -- [Codex] 当前持有者（审计/排障）
    verdict       TEXT,
    pid           INTEGER,
    updated_at    INTEGER NOT NULL
);

-- ④ 语义记忆
CREATE TABLE IF NOT EXISTS memory (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    context     TEXT NOT NULL DEFAULT 'general',       -- [Codex] 加 context，避免全局 text 误去重
    author      TEXT NOT NULL,
    type        TEXT NOT NULL,
    text        TEXT NOT NULL,
    evidence    TEXT,
    status      TEXT,
    created_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS memory_dedup ON memory(context, type, text);  -- [Codex] 按 context 去重
```

---

## 3. 命令实现（SQL）

### 3.1 `board write`

```sql
INSERT INTO messages (id, ts, from_agent, to_agent, type, task_id, ref, summary, payload_hash)
VALUES (:id, :epoch, :from, :to, :type, :task, :ref, :summary, :hash);
```
- 返回 `last_insert_rowid()` 作为 seq。
- `id UNIQUE` 冲突：**再比对内容**——相同则幂等忽略，不同则报错（`[Codex]` 防同 id 异内容静默丢）。

### 3.2 `board read`（消费）

```sql
BEGIN IMMEDIATE;
  SELECT seq,id,ts,from_agent,to_agent,type,task_id,ref,summary
  FROM messages WHERE seq > (SELECT COALESCE(last_seq,0) FROM consumption WHERE agent=:agent)
  ORDER BY seq;
  UPDATE consumption SET last_seq=:new_seq, updated_at=:now WHERE agent=:agent;  -- 事务内推进
COMMIT;
```
- 读+推进**同一事务**，崩溃回滚 → at-least-once，不丢不重。
- 消费方处理消息的「库内效果 + 处理记录 + 确认」也应在**同一事务**（`[Codex]`）。

### 3.3 `board state`（状态机 + fencing）

**启动**：
```sql
INSERT INTO tasks (task_id,status,fencing_token,lease_epoch,owner,pid,updated_at)
VALUES (:id,'running',1,:lease,:owner,:pid,:now) ON CONFLICT(task_id) DO NOTHING;
```

**提交终态（CAS + lease 有效期）**：
```sql
UPDATE tasks SET status=:status, fencing_token=fencing_token+1, verdict=:verdict, updated_at=:now
WHERE task_id=:id AND fencing_token=:token AND status='running' AND lease_epoch >= :now;
-- [Codex] 加 lease_epoch>=now：过期即失权，旧持有者不得再提交
-- 1 行=成功；0 行=已失权/被抢占 → 拒绝
```

### 3.4 `board heartbeat`（续租，带 token + 有效期）

```sql
UPDATE tasks SET lease_epoch=:lease, updated_at=:now
WHERE task_id=:id AND fencing_token=:token AND status='running' AND lease_epoch >= :now;
```

### 3.5 `board claim`（抢占孤儿任务，RETURNING 取新 token）

```sql
UPDATE tasks
SET status='running', fencing_token=fencing_token+1, lease_epoch=:lease, owner=:owner, pid=:pid, updated_at=:now
WHERE task_id=:id AND status='running' AND lease_epoch < :now
RETURNING fencing_token;
-- [Codex] 用 RETURNING 直接拿新 token，别事后 SELECT（避免竞态）
-- 有返回 = 抢占成功（token 已 +1）；无返回 = 未过期或已被抢
```

### 3.6 `board check`

```sql
SELECT status, lease_epoch, fencing_token FROM tasks WHERE task_id=:id;
```
- `running && lease_epoch < now` → 输出 `orphaned`（+ 当前 token，供 claim 参考）。

### 3.7 `board remember`

```sql
INSERT INTO memory (context, author, type, text, evidence, status, created_at) VALUES (...);
-- (context,type,text) 唯一冲突 → 幂等忽略
```

### 3.8 `board export`（文件投影，只读可重建）

```bash
sqlite3 "$DB" "SELECT json_object('seq',seq,'id',id,'ts',ts,'from',from_agent,'to',to_agent,'type',type,'task',task_id,'ref',ref,'summary',summary) FROM messages ORDER BY seq;" > bus/log.ndjson
```
- 文件层 = 只读镜像，删了可重建；真相只在 `board.db`。

---

## 4. fencing 状态机（最终，含 Codex 修正）

```
INSERT(启动, token=1)
   │
   ▼
running ──heartbeat(带token+lease未过期)──▶ 续租
   │
   │ lease 过期（clock 判）
   ▼
orphaned（派生）──claim(RETURNING token+1)──▶ 新持有者
   │
   │ 提交(带token + lease>=now 的 CAS)
   ▼
done / failed
```

**关键不变量**（`[Codex]` 强化）：
1. `fencing_token` 只增不减、**永不删行**（避免 token ABA）；
2. 任何写操作都必须带调用方 token，`WHERE fencing_token=?` 匹配才生效；
3. **提交与续租额外要求 `lease_epoch >= now`**——过期即失权，堵住「过期后旧持有者仍提交/续租」的双执行路径；
4. `claim` 用 `RETURNING` 原子取新 token；
5. 外部副作用（写代码/发请求）必须携带 fencing/幂等键，由下游校验——**库内正确 ≠ 副作用正确**（`[Codex]`）。

> 时钟说明：lease 用 epoch 秒（wall clock）。单机分钟级租约下 NTP 秒级跳变风险可控；如需严格，lease 改由 `python3 -c "import time;print(int(time.monotonic()))"` 取单调时钟（进程重启会归零，需结合 owner 代次）。V4 先用 epoch + owner，标注该权衡。

---

## 5. 幂等设计（三层，含 Codex 修正）

| 层 | 机制 | 防什么 |
|---|---|---|
| 插入 | `messages.id UNIQUE`（冲突后**比对内容**） | 重复写 / 同 id 异内容静默丢 |
| 消费 | `consumption.last_seq` 事务推进（读+处理+确认同事务） | 重复读 / 漏读 |
| 副作用 | **业务幂等键**（下游校验），非 payload_hash | 重复执行外部动作 |

> `[Codex]`：`payload_hash` 只能证明「内容相同」，不能代表「业务操作已执行」。外部副作用必须用下游的业务幂等键（如「该文件已由 task-X 写入」）。

---

## 6. 故障注入测试矩阵（扩充后，上线门槛）

| # | 注入 | 期望 |
|---|---|---|
| F1 | kill -9 写消息 | 事务回滚，无半条 |
| F2 | kill -9 消费（读+推进） | 回滚，不丢不重 |
| F3 | kill -9 持锁 | busy_timeout 后接管，无死锁 |
| F4 | kill -9 提交 | 要么 running 要么 done，无中间态 |
| F5 | SIGSTOP 暂停→恢复 | lease 过期可 claim，旧持有者提交被 fencing 拒 |
| F6 | 两进程并发 claim | 只有一个 RETURNING 有值，另一个空 |
| F7 | 重放已消费日志 | 幂等：id 冲突忽略，consumption 不重复 |
| F8 | 旧持有者 lease 过期后仍提交 | 提交 0 行（lease 条件）→ 拒绝 |
| F9 | 时钟前跳/回拨 | `[Codex]` 前跳→误抢（靠 owner+token 收敛）；回拨→延迟抢占（可接受，记录） |
| F10 | 进程重启 | `[Codex]` 重启后 owner 代次变化，旧 token 失效 |
| F11 | 磁盘满 / I/O 错误 | `[Codex]` 写失败不破坏已提交数据，可恢复 |
| F12 | 提交成功但回执丢失 | `[Codex]` 重试按 id/seq 幂等，不重复副作用 |

**验收：12 项全过，才接 N-agent。**

---

## 7. N-agent 扩展（最小可行配置）

`[Codex]` 建议的最小 N-agent：**规划 / 执行 / 审查** 三个 agent + 确定性调度器 + SQLite + 文件仓库。

```
planner（规划）→ 生成任务依赖图
     ↓
scheduler（调度器，自身也持 fencing+租约）
     ↓ 按「依赖就绪 + 能力 + 优先级 + 配额」发租约
executor（执行）→ 写产物 + 回传结果
     ↓
reviewer（审查）→ 验收 / 带意见返工
     ↓
终止：根任务验收通过 且 无未决子任务 且 无在途消息
      OR 预算/截止耗尽 → 取消剩余 + 报告未完成
```

还缺的机制（`[Codex]`，V4 之后按需补）：
- **能力路由**（名片卡 → 匹配任务）
- **任务依赖图** + 聚合屏障 + 超时
- **广播接收者快照 + 独立 ACK**
- **冲突裁决**、验收标准、轮次/成本上限
- **有界队列 + 并发配额 + 优先级老化**
- **重试 / 死信 / 取消传播**

---

## 8. 迁移路径

1. `board.sh` 检测 `sqlite3`（macOS 自带 3.43.2）；
2. 写命令切 SQLite 事务（write/state/heartbeat/claim/check/remember）；读命令切 SQLite 消费；
3. `export` 投影保持文件层可读；`search` 仍 grep 投影；
4. 跑 §6 的 12 项故障注入；
5. 全过后接 §7 的三 agent 最小配置。

---

## 9. 评审来源

- Codex #1（schema + 幂等）：时间戳 epoch、memory 按 context 去重、synchronous=FULL、消费/处理/确认同事务、outbox + 业务幂等键、WAL 单写者注意点。
- Codex #2（fencing + 故障注入）：提交/续租加 lease 有效期、claim 用 RETURNING、禁止删行防 ABA、单调时钟+代次、扩充故障注入（时钟跳变/重启/磁盘满/回执丢失）。
- Codex #3（N-agent）：能力路由、依赖图、聚合屏障、验收/成本上限、死信/取消；最小三 agent（规划/执行/审查）+ 调度器（自身 fencing）。
