# /collab — Claude Code × Codex Collaboration

Launch Codex CLI as an independent engineering partner. Not a subagent — a model from a different training lineage with different blind spots. The value is in the independence.

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

## Default Behavior

When you type `/collab "your question"` without a mode keyword, it runs **Think mode**:

1. Form your own position first — do NOT share it with Codex
2. Call Codex independently: `codex-bridge.sh think neutral "your question"`
3. Compare positions, synthesize, present verdict

This is the fastest path to value — an independent second opinion in ~30 seconds. Use it for any consequential design or architecture decision.

## Bridge Script

```
~/Agent/collab/codex-bridge.sh [--task-id <id>] <mode> <role> <prompt>
```

Modes: `think` | `build` | `debug` | `review`
Roles: `neutral` | `builder` | `architect` | `oracle` | `spec-reviewer`

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

Ask about:
- **Scope**: What exactly are we building? What are we explicitly NOT building?
- **Boundaries**: Which files/modules are in scope? Which must not be touched?
- **Constraints**: Framework, language, style, performance requirements, compatibility?
- **Edge cases**: What happens on empty input? On failure? At scale? With concurrent access?
- **Success criteria**: How will the user know this is done? What tests would prove it?
- **Dependencies**: What does this depend on? What depends on this?
- **Existing patterns**: Are there similar implementations in the codebase to follow?

**Do not stop asking until you can answer every one of these questions.** If the user's answer is vague, push for specificity.

**Exit condition:** You can write a spec that a senior engineer could implement without asking a single follow-up question.

#### Phase 2: Spec (Claude writes)

Write a structured spec at `~/Agent/collab/specs/task-NNN.md`. The spec MUST include:

```markdown
# Task: [One-line goal]

## Context
- Why this matters
- What problem it solves

## Scope
### Files to create/modify
- Explicit paths

### Files to NOT touch
- Explicit paths (especially: CLAUDE.md, .claude/, .git/, config files, unrelated modules)

## Requirements
### Functional
- What it must do (numbered, testable)

### Non-functional
- Performance, security, error handling, logging

## Interface / API Contract
- Function signatures, types, data shapes, route definitions

## Constraints
- Framework, style guide, test framework, compatibility requirements

## Edge Cases
- How to handle: empty input, invalid input, timeouts, concurrent access, large data

## Success Criteria
- [ ] Criterion 1 (binary, testable)
- [ ] Criterion 2
- ...
```

Use `date +%s` for the task ID. Tell the user: "Spec written at specs/task-NNN.md. Moving to contract phase with Codex."

#### Phase 3: Contract (Codex reviews the spec)

Before any code is written, Codex audits the spec:

```bash
~/Agent/collab/codex-bridge.sh review spec-reviewer \
  "Read the spec at ~/Agent/collab/specs/task-NNN.md. Produce an implementation contract."
```

Codex (as `spec-reviewer`) will produce a structured contract with:
- **Understanding**: What it thinks the task is (in its own words)
- **Plan**: Files/modules likely affected, tests to run
- **Risks**: Ambiguities, missing constraints, hidden assumptions, spec gaps
- **Decision**: Exactly one of — `proceed` | `needs_clarification` | `recommend_alternative`

#### Phase 4: Gate (Claude decides)

Read Codex's contract carefully:

| Codex Decision | Your action |
|---|---|
| `proceed` | Move to Phase 5. |
| `needs_clarification` | Codex found an ambiguity. Go back to Phase 1 with the specific question. Then revise the spec. Then re-run Phase 3. |
| `recommend_alternative` | Codex believes the approach is wrong or risky. Evaluate its alternative. If you agree → revise spec → re-run Phase 3. If you disagree → document why and proceed. |

**If Codex's Understanding section reveals a misunderstanding, the spec is unclear.** Fix it before proceeding — even if Codex said `proceed`.

**Do NOT proceed to implementation until the contract says `proceed` OR you have explicitly overridden a `recommend_alternative` with a documented reason.**

#### Phase 5: Implement (Codex async)

Launch Codex in background:

```bash
TASK_ID="task-$(date +%s)"
~/Agent/collab/codex-bridge.sh --task-id="$TASK_ID" build builder \
  "Implement the spec at ~/Agent/collab/specs/${TASK_ID}.md. Read the spec file for full details. You previously reviewed this spec and your contract was approved — the spec is confirmed." \
  > ~/Agent/collab/output/${TASK_ID}.txt 2>&1 &
CODEX_PID=$!
```

State is auto-written to `~/Agent/collab/state/${TASK_ID}.json` by the bridge script.

Tell the user: "Codex is implementing. You can keep chatting with me."

**Poll for completion:**
```bash
kill -0 $CODEX_PID 2>/dev/null && echo "RUNNING" || echo "DONE"
```

#### Phase 6: Review (Claude audits)

When Codex finishes, read `~/Agent/collab/output/task-NNN.txt`. Review:

1. Did Codex follow the approved spec and contract?
2. Are tests passing? (Run them yourself — do not trust Codex's claim.)
3. Any files modified that were in the "do NOT touch" list?
4. Code quality, error handling, edge case coverage acceptable?

Write a review at `~/Agent/collab/reports/task-NNN-review.md`:

```markdown
# Review: task-NNN

## Verdict: APPROVED | NEEDS_FIX | REJECTED

## Summary
- What worked, what didn't

## Findings
- Specific issues with file:line references

## Action
- If NEEDS_FIX: what to fix, whether another Codex round or Claude takes over
- If REJECTED: why, and what Claude will implement instead
```

**If NEEDS_FIX**: Write a focused fix spec, launch one more Codex round. Max 2 implementation rounds total. If the second round still fails → Claude takes over.

**Safety rules:**
- Codex NEVER commits to git. Claude does final review and commit with user approval.
- Codex cannot touch `.claude/`, `.git/`, `CLAUDE.md`, config files, or any path in the "do NOT touch" list.
- Single Codex run capped at ~25 minutes. Split larger tasks into multiple specs.
- Max 2 implementation rounds. If Codex can't deliver in 2 rounds, Claude takes over.
- Phase 3 (Contract) does NOT count against the 2-round limit — it's cheap (read-only) and prevents expensive mistakes.

---

### Build --fast — Lightweight Pipeline

**When:** Routine tasks where formal spec/contract phases are overkill. Use when:
- The scope is clear and well-understood
- You've built similar things before
- The cost of being wrong is low (easy to revert/iterate)

**Do NOT use --fast when:**
- Multi-system changes or complex dependencies
- Critical infrastructure modifications
- User requirements are vague (use full Build for Phase 1 clarification)

**Protocol (4 steps instead of 6):**

1. **Quick clarify (max 2 questions).** Only the most critical unknowns. Skip questions where the answer is obvious or low-risk to get wrong.

2. **Write a compact spec as the prompt.** Embed it inline rather than a separate file:
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

4. **Review.** When done, Claude audits the output. Write a brief review. No separate report file unless issues found.

**Safety rules (same as full Build):**
- Codex NEVER commits to git
- Cannot touch `.claude/`, `.git/`, `CLAUDE.md`
- Single run cap at ~25 minutes
- Max 2 implementation rounds

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

---

### Review — Cross-Model Code Review

**When:** Quick review of current diff before commit.

**Protocol:**

1. **Get the diff.** `git diff` (unstaged, default) or `git diff --staged` (if user says "staged").
2. **Send to Codex as architect:**
   ```bash
   ~/Agent/collab/codex-bridge.sh review architect \
     "Review this diff critically. Find: bugs, edge cases, security vulnerabilities, performance issues, unclear naming, missing tests. Be specific with line references. If clean, say so briefly.

   [paste diff]"
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

| Pattern | Example |
|---|---|
| Architecture choice with 2+ valid options | "Monorepo or polyrepo?" |
| Technology selection | "React or Vue?" |
| Design trade-off discussion | "How should we structure the API?" |
| Consequential decision (>1 module, >1 week of work) | Any significant design choice |

### Suggest Build --fast when:

| Pattern | Example |
|---|---|
| Feature with clear scope | "Add a /users endpoint" |
| Document/code generation | "Generate a summary report" |
| Single-module refactoring | "Extract this into a helper" |

### Suggest Build (full) when:

| Pattern | Example |
|---|---|
| Multi-file, complex dependencies | "Build the auth system" |
| Critical infrastructure | "Modify the migration framework" |
| Requirements are vague | "I want to improve performance" |

### Suggestion format:

After forming your own analysis, add one line:
> 要不要让 Codex 给个独立第二意见？30 秒就行。回复"跑一下"或直接打 `/collab`。

### When NOT to suggest:

- Simple factual questions ("What does this command do?")
- Tasks completable in <3 trivial steps
- User is in rapid Q&A mode
- User already said "no" this session (don't re-ask unless context changes meaningfully)

---

## State Management

### Per-Task State Files

Each task gets its own state file at `~/Agent/collab/state/task-NNN.json`, auto-written by the bridge script when `--task-id` is provided:

```json
{
  "id": "task-NNN",
  "status": "running|done|failed",
  "pid": 12345,
  "spec": "specs/task-NNN.md",
  "output": "output/task-NNN.txt",
  "contract": "output/task-NNN-contract.txt",
  "report": "reports/task-NNN-review.md",
  "started": "ISO8601",
  "verdict": "APPROVED|NEEDS_FIX|REJECTED|null"
}
```

**Discover tasks:** `ls ~/Agent/collab/state/`

### File Naming

- Specs: `specs/task-{timestamp}.md`
- Contract: `output/task-{timestamp}-contract.txt`
- Output: `output/task-{timestamp}.txt`
- Reports: `reports/task-{timestamp}-review.md`
- State: `state/task-{timestamp}.json`

Use `date +%s` for timestamps.

---

## General Rules

1. **You are the coordinator, not the sole thinker.** Codex is an independent engineer with a different prior. Its value is in disagreeing with you.
2. **Cross-model is the point.** Agreement → confidence up. Disagreement → that's where learning happens.
3. **Don't over-use, but don't under-use either.** Actively suggest collab when patterns match (see Proactive Suggestions above). A 30-second second opinion costs nothing and catches blind spots.
4. **Build is the expensive mode.** Follow all 6 phases. The contract phase (Phase 3) is cheap read-only — it prevents expensive wrong implementations.
5. **Build --fast is for routine tasks.** Use it when the overhead of formal spec/contract isn't justified. It preserves the core value (independent implementation + Claude review) without the ceremony.
6. **Subscriptions only.** Bridge unsets `OPENAI_API_KEY`. No API billing.
7. **State survives crashes.** Per-task files in `state/`, outputs on disk.
8. **User has final say.** You present analysis and recommendations. The user decides. Never commit without explicit approval.
