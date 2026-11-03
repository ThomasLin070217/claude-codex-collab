# 执行权、续租与回归验证

`job-create` 在同一个 `BEGIN IMMEDIATE` 事务内写入 job 和全部依赖。依赖允许前向引用；递归 CTE 触发器拒绝自环及闭环，并回滚整个创建事务。缺失依赖继续等待。上游重试期间下游等待；上游进入 `dead` 后，在 create / ready / fail / reap 中递归传播 `dead`。

`job-claim --id X --agent A` 现在同时写入唯一派发消息（`dispatch:<job_id>:<token>`），调用者不要再单独发任务消息。认领必须有在线 agent，并绑定当时的 `owner_session`。`MAX_INFLIGHT_PER_AGENT` 默认 1，容量检查在认领事务中完成，可抵御并发 scheduler。调度器会遍历所有 ready job，跳过暂时无法匹配的任务。

worker 启动时调用 `agent-heartbeat --agent A --session S --register`；之后续期省略 `--register`，旧进程不能用心跳覆盖新 session。`job-guard`、`job-heartbeat`、`job-done` 和 `job-fail` 均必须带 `--id X --agent A --session S --token T`，校验当前 session、agent 健康、租约和 token。新启动的 worker 使用独立消费游标，避免旧 session 确认新 session 的任务消息。

worker 在执行前校验执行权，执行中默认每秒续租，失权时终止 mock 子进程。`job-reap` 会回收租约过期、agent 失联或 session 被替换的任务，递增 token 和尝试次数。原有数据库会自动增加 `owner_session`；旧的 running job 没有 session，由 reap 回收后重派。

当前 worker 的执行体仍是 `sleep` mock，其结果写入 `job_effects`，以 `job_id` 为唯一幂等键，与 done 在同一事务提交。重复投递不会重复提交结果。另提供稳定的 `COLLAB_IDEMPOTENCY_KEY=job:<job_id>` 给未来执行适配器。真实 API / 文件写入需要在接收端或发布产物时实现幂等和 fencing；单独调用 guard 无法消除检查与外部副作用之间的竞态。替换 mock 时也需管理实际命令的整个进程树。

`board start` 只向相同 owner 返回 running token；bridge 每次调用使用独立 owner。bridge 支持两种 `--task-id` 形式，拒绝无 token 执行，显式捕获 Codex 返回码并提交 failed。用于文件名的 task ID 拒绝路径分隔符、`.`、`..`、换行和记录分隔符。

运行验证（需要 Bash、sqlite3、jq、Python 3；不会调用真实 Codex）：

```bash
bash -n board.sh scheduler.sh agent-worker.sh codex-bridge.sh
COLLAB_DIR=/tmp/a-fix python3 tests/regression.py
git diff --check
```

测试在 `/tmp/a-fix/case-*` 下创建独立数据库并保留现场，覆盖事务故障回滚、环检测、依赖成功与重试、dead 传播、owner 校验、并发 ready/claim、session 替换、失联回收、调度公平性、长任务续租、失权终止、重复投递、bridge 失败路径、路径穿越和旧 schema 升级。
