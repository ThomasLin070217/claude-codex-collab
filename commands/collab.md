# /collab — Claude Code × Codex Collaboration (v2)

Launch Codex CLI as an independent engineering partner. Not a subagent — a model from a different training lineage with different blind spots. The value is in the independence.

**v2 核心变化：从「文件白板互读」升级为「黑板总线 + 交接文件 + 分层记忆」。**
- 消息走 `board.sh write`（append-only 总线），不再 `cat` 对方全文、不再把 diff/spec 粘贴进 prompt；
- Codex 的完整过程隔离在 `output/`，你只读 `handoff/<task_id>.md`（结论）；
- 跨任务决策沉淀到 `memory/decisions.md`（带 provenance）。

## Usage Tracking

After every successful collab invocation, update `~/Agent/collab/.usage`:

```
total=N
think=N
build=N
build_fast=N
debug=N
review=N
disagreements_caught=N
last_used=<ISO8601>
```

At the end of any session where collab was used, present a one-line summary:
> 本次对话使用 collab ${n} 次，其中发现 ${d} 处独立模型意见分歧。

## Quick Reference

| Trigger | Mode | What happens |
|---|---|---|
| `/collab "..."` | Think (default) | Dual-model debate → synthesis |
| `/collab think "..."` | Think (explicit) | Same as above |
| `/collab build "..."` | Build (full) | Clarify → Spec → Contract → Implement → Review |
| `/collab build --fast "..."` | Build (fast) | Quick clarify → implement → review |
| `/collab debug "..."` | Debug | Independent hypotheses → discriminating test |
| `/collab review` | Review | Codex reviews current diff as skeptical architect |

## Bridge Script & Board

```
~/Agent/collab/codex-bridge.sh [--task-id <id>] <mode> <role> <prompt>
~/Agent/collab/board.sh <command> [args]
```

`codex-bridge.sh` Modes: `think` | `build` | `debug` | `review`
`codex-bridge.sh` Roles: `neutral` | `builder` | `architect` | `oracle` | `spec-reviewer`

`board.sh` commands (run `board.sh help` for details):

| Command | Purpose |
|---|---|
| `board.sh init` | 建目录 + 初始化分层记忆 |
| `board.sh write --from X --to Y --type T --task ID --ref P --summary S` | 追加一条总线消息（payload 走 ref） |
| `board.sh read --as claude` | 增量读总线（按游标） |
| `board.sh handoff <task_id> --from codex --outcome ...` | 写交接文件 |
| `board.sh remember --author X --text ... --evidence P --status confirmed` | 写语义记忆（带 provenance + 去重） |
| `board.sh state <task_id> <running\|done\|failed> --verdict ...` | 结构化状态 |
| `board.sh search <kw>` | 检索总线 + 语义记忆 |

> `codex-bridge.sh` 已经自动写总线消息和 state；你只需要在关键节点显式 `board.sh remember` 沉淀决策、`board.sh search` 检索历史。

---

## Mode Protocols

### Think — Dual-Model Debate

**When:** Architecture decisions, tech choices, strategic trade-offs. **This is the default mode.**

**Protocol:**

1. **Form your own position first.** Analyze the problem and write your recommendation. Do NOT share this with Codex.
2. **Call Codex independently.** Use `think` mode with `neutral` role. Present the problem WITHOUT revealing your conclusion:
   ```bash
   ~/Agent/collab/codex-bridge.sh think neutral \
     "Analyze this trade-off: [problem]. Give your recommendation with reasoning."
   ```
3. **Compare positions.** Where do you agree? Where do you diverge? Which arguments are stronger?
4. **If positions diverge significantly**, challenge Codex with your counter-arguments (max 1 follow-up round).
5. **Synthesize.** Present:
   - Your recommendation
   - Codex's recommendation
   - Points of agreement
   - Points of divergence — who has the stronger case?
   - Final verdict with reasoning
6. **Persist the decision** (v2):
   ```bash
   ~/Agent/collab/board.sh remember --author claude --type decision \
     --text "选择 [结论]：<一句话>" --evidence "think 模式双模型辩论" \
     --status confirmed
   ```

**Rules:**
- Max 2 rounds. If still unconverged, the disagreement is fundamental → escalate to user.
- Synthesize, don't relay. The user wants ONE recommendation, not two opinions pasted together.
- If Codex changes your mind, say so explicitly. That's valuable signal.
- Hide your hypothesis from Codex. Contamination defeats the purpose.

---

### Build — The Full Pipeline

**When:** Multi-file features, critical infrastructure, complex dependencies, vague requirements.

**Do NOT skip phases. A flawed spec wastes both Codex's effort and the user's time.**

#### Phase 1: Clarification (Claude ↔ User)

**Before writing anything, interrogate the user until you reach 100% certainty.**

Ask about: **Scope**, **Boundaries**, **Constraints**, **Edge cases**, **Success criteria**, **Dependencies**, **Existing patterns**.

**Exit condition:** You can write a spec that a senior engineer could implement without asking a single follow-up question.

#### Phase 2: Spec (Claude writes)

Write a structured spec at `~/Agent/collab/specs/task-NNN.md`. The spec MUST include:

```markdown
<!-- spec-version: 1 -->
# Task: [One-line goal]

## Context
- Why this matters

## Scope
### Files to create/modify
### Files to NOT touch
- Explicit paths (especially: CLAUDE.md, .claude/, .git/, config files)

## Requirements
### Functional
### Non-functional

## Interface / API Contract
## Constraints
## Edge Cases
## Success Criteria
- [ ] Criterion 1 (binary, testable)
```

Use `date +%s` for the task ID.

**v2: 广播 spec 到总线**（payload 走 ref，不粘贴全文）：
```bash
~/Agent/collab/board.sh write --from claude --to codex --type spec \
  --task task-NNN --ref specs/task-NNN.md \
  --summary "[一句话任务目标]"
```

Tell the user: "Spec written at specs/task-NNN.md. Moving to contract phase with Codex."

#### Phase 3: Contract (Codex reviews the spec)

Before any code is written, Codex audits the spec. **v2: 传 ref 路径，不粘贴 spec 全文**：
```bash
~/Agent/collab/codex-bridge.sh --task-id=task-NNN review spec-reviewer \
  "Read the spec at ~/Agent/collab/specs/task-NNN.md. Produce an implementation contract."
```

Codex (as `spec-reviewer`) produces a contract with Understanding / Plan / Risks / Decision, and **ends with a machine-readable JSON verdict** (the bridge extracts it into `state/task-NNN.json`).

#### Phase 4: Gate (Claude decides)

Read the verdict from state (机器可读，不再是自由文本)：
```bash
cat ~/Agent/collab/state/task-NNN.json   # 看 "verdict" 字段
```

| Codex Decision | Your action |
|---|---|
| `proceed` | Move to Phase 5. |
| `needs_clarification` | Go back to Phase 1 with the specific question. Revise spec → bump `spec-version` → re-run Phase 3. |
| `recommend_alternative` | Evaluate its alternative. Agree → revise spec → re-run Phase 3. Disagree → document why and proceed. |

**If Codex's Understanding reveals a misunderstanding, the spec is unclear — fix it even if Codex said `proceed`.**

#### Phase 5: Implement (Codex async)

Launch Codex in background. The bridge auto-writes state + bus message + handoff:

```bash
TASK_ID="task-$(date +%s)"
~/Agent/collab/codex-bridge.sh --task-id="$TASK_ID" build builder \
  "Implement the spec at ~/Agent/collab/specs/${TASK_ID}.md. Read the spec file for full details. You previously reviewed this spec and your contract was approved — the spec is confirmed." \
  > ~/Agent/collab/output/${TASK_ID}.txt 2>&1 &
CODEX_PID=$!
```

Tell the user: "Codex is implementing. You can keep chatting with me."

**Poll for completion:**
```bash
kill -0 $CODEX_PID 2>/dev/null && echo "RUNNING" || echo "DONE"
```

#### Phase 6: Review (Claude audits)

When Codex finishes, **v2: 先读交接文件（结论），不要读 output 全文**：
```bash
cat ~/Agent/collab/handoff/${TASK_ID}.md     # 结论/产物/风险/下一步
cat ~/Agent/collab/state/${TASK_ID}.json     # status + verdict
```

Only if you need detail, dig into the isolated process log:
```bash
cat ~/Agent/collab/output/${TASK_ID}.txt     # 完整过程（隔离区，按需读）
```

Review:
1. Did Codex follow the approved spec and contract?
2. Are tests passing? (Run them yourself — do not trust Codex's claim.)
3. Any files modified that were in the "do NOT touch" list?
4. Code quality, error handling, edge case coverage acceptable?

Write a review at `~/Agent/collab/reports/task-NNN-review.md`:

```markdown
# Review: task-NNN
## Verdict: APPROVED | NEEDS_FIX | REJECTED
## Summary
## Findings
- Specific issues with file:line references
## Action
```

**v2: 沉淀结论到语义记忆**（供未来任务复用）：
```bash
~/Agent/collab/board.sh remember --author claude --type decision \
  --text "task-NNN 实现方式：<一句话>" --evidence "reports/task-NNN-review.md" \
  --status confirmed
```

**If NEEDS_FIX**: Write a focused fix spec, launch one more Codex round. Max 2 implementation rounds total. If the second round still fails → Claude takes over.

**Safety rules:**
- Codex NEVER commits to git. Claude does final review and commit with user approval.
- Codex cannot touch `.claude/`, `.git/`, `CLAUDE.md`, config files, or any path in the "do NOT touch" list.
- Single Codex run capped at ~25 minutes. Split larger tasks into multiple specs.
- Max 2 implementation rounds. Phase 3 (Contract) does NOT count against the limit.

---

### Build --fast — Lightweight Pipeline

**When:** Routine tasks where formal spec/contract phases are overkill.

**Protocol (4 steps):**

1. **Quick clarify (max 2 questions).**
2. **Write a compact spec as the prompt** (embed inline):
   ```
   ## Task: [one-liner]
   ## Files to touch: [paths]
   ## Requirements: [3-5 bullets]
   ## Constraints: [framework, style]
   ## Do NOT touch: [paths]
   Before implementing, flag any issues or ambiguities you find.
   ```
3. **Launch Codex:**
   ```bash
   TASK_ID="task-$(date +%s)"
   ~/Agent/collab/codex-bridge.sh --task-id="$TASK_ID" build builder \
     "[compact spec from step 2]" \
     > ~/Agent/collab/output/${TASK_ID}.txt 2>&1 &
   ```
4. **Review.** Read `handoff/${TASK_ID}.md` + `state/${TASK_ID}.json`. Write a brief review.

---

### Debug — Independent Root Cause Analysis

**When:** Bug investigation, performance issues, unexpected behavior.

**Protocol:**

1. **Form your hypothesis.** Do not share it.
2. **Call Codex oracle** with symptoms only:
   ```bash
   ~/Agent/collab/codex-bridge.sh debug oracle \
     "Investigate: [symptoms, error messages, repro steps]. Find the root cause."
   ```
3. **Compare.** Converge → high confidence fix. Diverge → design a discriminating test.
4. **Present:** Hypothesis A, Hypothesis B, convergence status, recommended fix.
5. **v2: 沉淀根因结论**：
   ```bash
   ~/Agent/collab/board.sh remember --author claude --type finding \
     --text "根因：[一句话]" --status confirmed
   ```

---

### Review — Cross-Model Code Review

**When:** Quick review of current diff before commit.

**Protocol:**

1. **Get the diff and write it to a file** (v2: 走 ref，不粘贴进 prompt):
   ```bash
   mkdir -p ~/Agent/collab/work/claude
   git diff > ~/Agent/collab/work/claude/diff.txt
   wc -l ~/Agent/collab/work/claude/diff.txt
   ```
2. **Send Codex the ref, not the diff text:**
   ```bash
   ~/Agent/collab/codex-bridge.sh review architect \
     "Review the git diff at ~/Agent/collab/work/claude/diff.txt critically. Find: bugs, edge cases, security vulnerabilities, performance issues, unclear naming, missing tests. Be specific with line references. If clean, say so briefly."
   ```
3. **Present findings as a table:**

| Severity | Issue | File:Line | Recommendation |
|---|---|---|---|
| 🔴 Critical | ... | ... | ... |
| 🟡 Warning | ... | ... | ... |
| 🔵 Nitpick | ... | ... | ... |

4. **If no issues:** "Codex found no issues." Don't pad — honest clean is valuable.

---

## Proactive Suggestions

Do not wait for the user to type `/collab`. Proactively suggest it when these patterns appear:

### Suggest Think (default) when:
- Architecture choice with 2+ valid options
- Technology selection
- Design trade-off discussion
- Consequential decision (>1 module, >1 week of work)

### Suggest Build --fast when:
- Feature with clear scope
- Document/code generation
- Single-module refactoring

### Suggest Build (full) when:
- Multi-file, complex dependencies
- Critical infrastructure
- Requirements are vague

### Suggestion format:
> 要不要让 Codex 给个独立第二意见？30 秒就行。回复"跑一下"或直接打 `/collab`。

### When NOT to suggest:
- Simple factual questions
- Tasks completable in <3 trivial steps
- User in rapid Q&A mode
- User already said "no" this session

---

## State Management (v2)

### 真状态机（bridge 自动维护）

`codex-bridge.sh --task-id=X` 会在**启动写 running、退出写 done/failed**，并写入**真实 Codex pid** 和结构化 `verdict`：

```json
{
  "id": "task-NNN",
  "status": "running|done|failed",
  "pid": 12345,
  "spec": "specs/task-NNN.md",
  "handoff": "handoff/task-NNN.md",
  "updated": "ISO8601",
  "verdict": "proceed|needs_clarification|recommend_alternative|"
}
```

**Discover tasks:** `ls ~/Agent/collab/state/`

### 分层记忆（v2 新增）

| 文件 | 层 | 作用 |
|---|---|---|
| `memory/core.md` | 常驻 | 目标/当前状态/关键约束（几 KB，永不膨胀） |
| `memory/decisions.md` | 语义 | 结论/决策/发现，每条带 provenance（作者/时间/依据/状态） |
| `memory/index.md` | 索引 | 语义层的扁平索引，供 `board.sh search` 检索 |
| `specs/` | 原始 | 原始产物，**永不改写**（细节回读用） |

**开工前先检索历史**（避免冷启动/重复劳动）：
```bash
~/Agent/collab/board.sh search <关键词>
```

### 文件命名

- Specs: `specs/task-{timestamp}.md`
- Output: `output/task-{timestamp}.txt`（Codex 完整过程，隔离区）
- Handoff: `handoff/task-{timestamp}.md`（结论）
- Reports: `reports/task-{timestamp}-review.md`
- State: `state/task-{timestamp}.json`

---

## General Rules

1. **You are the coordinator, not the sole thinker.** Codex is an independent engineer with a different prior. Its value is in disagreeing with you.
2. **Cross-model is the point.** Agreement → confidence up. Disagreement → that's where learning happens.
3. **v2: 结论走交接文件，过程走隔离区。** 你只读 `handoff/`（结论），需要细节才读 `output/`（过程）。不要把 diff/spec 粘贴进 prompt，一律走 `ref` 文件指针。
4. **v2: 每次有结论就 `board.sh remember`。** 语义记忆是跨任务的资产，冷启动是浪费。
5. **Build is the expensive mode.** Follow all 6 phases. The contract phase is cheap read-only — it prevents expensive wrong implementations.
6. **Subscriptions only.** Bridge unsets `OPENAI_API_KEY`. No API billing.
7. **State survives crashes.** Per-task files in `state/`, outputs on disk, bus is append-only.
8. **User has final say.** You present analysis and recommendations. The user decides. Never commit without explicit approval.
