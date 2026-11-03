# 项目演进史：从「白板」到「N-agent 协作」

> 本文记录 claude-codex-collab 从 v1 到 v5 的完整演进，以及每一步被独立模型评审（Codex / Claude Code / DeepSeek）揪出的 bug 与修复。核心方法论：**每改一版，就交给独立模型评审，根据反馈修 bug，再改下一版。**

---

## 总览

| 版本 | 核心变化 | 被揪出的关键 bug |
|---|---|---|
| v1 | 朴素白板：两 agent 互读文件 | 「读→转写→写」每轮有损，信息磨损 |
| v2 | 黑板总线（board.sh 文件版） | sed/grep 解析 JSON、无 id、锁死锁、行号游标 |
| v3 | 双模型评审 → 6 处修复 | （修复 v2 的 6 个 bug） |
| v3.1 | 三通道复盘 → 5 处修复 | 锁双 breaker、无 seq、不幂等、状态覆盖 |
| v4 | **SQLite 事务核心 + fencing** | 消费语义错（at-most-once）、墙钟 fencing、副作用 fencing |
| v4.x | 三通道评价 → P0 修复 | at-least-once（read/ack）、grace period、guard |
| v5 | **N-agent 调度** | 能力声明 ≠ 在线（健康心跳缺失） |

---

## v1 → v2：白板的病根

**v1 问题**：两个 agent 靠「写文件 → 互读全文 → 用自己的话再写一遍」协作。每轮都是一次有损转写，几轮后像传话游戏一样漂移。

**诊断（11 个磨损点）**：
- 传输通道：diff/spec 粘贴进 prompt 会截断、转义损坏
- 状态：state.json 是假状态（verdict 永远空、pid 写错）
- 扩展：hub-and-spoke 中心化，Claude 是唯一枢纽 + 单点
- 协议：无 schema、无版本、无握手

**核心一句话**：把「消息/状态/知识」降维成了「文件字节」，把「协议」降维成了「模型自觉」。

---

## v2：黑板总线（board.sh 文件版）

引入 append-only 总线 + 游标增量读 + 交接文件 + 分层记忆。**这是第一次从「白板」走向「结构化」**。

---

## v3：双模型评审 → 6 处修复

用自建 bridge + subagent 让 Codex、Claude Code 独立评审，**收敛出 6 个共识 bug**：

| bug | 修复 |
|---|---|
| sed/grep 解析 LLM JSON 脆弱 | 换 jq（macOS 自带） |
| 消息无唯一 id | 加 msg-<epoch>-<pid>-<rand> |
| mkdir 锁进程被杀→死锁 | stale 检测 |
| 行号游标截断失效 | 字节偏移 + compact |
| 状态机弱、pid 判活不可靠 | lease + heartbeat |
| 读到半截文件 | tmp + mv 原子写 |

**AB test：before 2/7 → after 7/7。**

---

## v3.1：三通道复盘 → 5 处修复

三个通道（自建 Codex + subagent Codex + subagent Claude）一致指出残留硬伤：

| bug | 修复 |
|---|---|
| 锁「超时强删」误删活锁→双写 | owner token + 原子 rename 抢占 |
| 有 id ≠ 幂等 | seen-set 去重 |
| 无消息序号 | seq 单调递增 |
| 终态可被回滚 | 状态转换防护 |
| 原子写缺 fsync | fsync |

---

## v4：SQLite 事务核心 + fencing（分水岭）

**三个模型一致结论**：bash + 文件黑板扛不住分布式一致性（split-brain / 幂等 / fencing），一致建议 SQLite 事务队列。

**核心决策**：强一致下沉 SQLite(WAL)，文件层退化为「可读投影」。

- `messages` 表：seq 主键 + id UNIQUE（顺序 + 幂等）
- `consumption` 表：事务推进 last_seq（消费进度）
- `tasks` 表：fencing_token（DB 单调递增）做 CAS（抢占/提交）
- `memory` 表：(context,type,text) 去重

**fencing 状态机**：`start(INSERT token=1) → claim(RETURNING token+1) → state done/failed(CAS: WHERE token=? AND lease>=now)`。

---

## v4.x：三通道评价 → P0 修复

三个模型再次一致，揪出一个**真 bug + 两个设计权衡**：

| 问题 | 修复 |
|---|---|
| **消费语义错了**：先推进游标后处理 = 崩溃丢消息（at-most-once） | read 不推进 + 显式 ack（真 at-least-once） |
| 墙钟 fencing 有 GC/漂移问题 | grace period + 明确 fencing_token 为权威 |
| token 只挡 DB 写，挡不住副作用 | `board guard` 副作用前置校验 |

---

## v5：N-agent 调度

从「双 agent」到「多 agent」：

- `jobs` 表：依赖图（deps）+ 调度状态 + fencing + 死信（attempts/max_attempts）
- `scheduler.sh`：就绪检测（依赖满足）→ 能力路由（名片卡 skill）→ 发租约 → 收敛
- `agent-worker.sh`：通用 worker（read --to 过滤 + 执行 + ack + job-done）
- 名片卡：planner / executor / reviewer

**demo 验证**：3 job 依赖链（plan→exec→review）+ 3 worker，能力路由正确、7 轮收敛、死信 3 次失败后转 dead。

---

## 仍未做的（三个模型一致列出的「生产级」需求）

按优先级（都是「上生产 / 上多机」才需要，单机双 agent 已够用）：

1. **agent 健康心跳**：能力声明（名片卡）≠ 在线状态，需区分「谁会做」和「谁现在在线」
2. **竞争消费语义**：当前是定向 `--to`，还没做「谁抢到谁做」的竞争消费
3. **背压 / 优先级老化 / 因果序 / 观测**：N 变大时的队列治理
4. **多机换 Postgres**：SQLite WAL 不支持跨机共享文件，多机需服务端数据库（FOR UPDATE SKIP LOCKED）

---

## 方法论总结

这套项目的真正价值不在某个版本，而在**「改一版 → 独立模型评审 → 修 bug → 再改」的闭环**：

- 每轮评审都收敛出真实 bug（不是客套）；
- 独立模型（Codex = OpenAI / Claude Code = DeepSeek 后端）从不同训练谱系看同一份代码，盲点互补；
- AB test / 故障注入把「修好了」从口头变成可验证的 14 项全过。
