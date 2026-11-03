# claude-codex-collab

A dual-agent collaboration system that makes **Claude Code** and **Codex CLI** work together as independent engineering partners — not as a subagent, but as a model from a different training lineage with different blind spots. The value is in the independence.

> **Claude is the brain (plan / review / decide). Codex is the hands (implement / second opinion).**

Communication happens over plain Bash. The filesystem is the only state. Zero new dependencies.

> **v2**: the naive "whiteboard" (both agents `cat` each other's files and paste diffs into prompts) is replaced by a **shared blackboard bus**: append-only message log + per-agent read cursors + handoff files + layered memory. This stops information loss (有损转写) and context bloat, and is the stepping stone to N-agent collaboration.

---

## Why

A single model has systematic blind spots. Two models from different training lineages, asked independently and then compared, catch what either would miss alone. This repo packages that into a concrete, reusable workflow with four pieces:

1. **`board.sh`** — a shared blackboard bus (v2): append-only `bus/log.ndjson` + per-agent read cursors, handoff files (conclusion only), layered memory (`memory/core.md` + `decisions.md` + index), and a JSON state machine.
2. **`codex-bridge.sh`** — a Bash bridge that calls Codex CLI with role-aware prompts, sandbox modes, retry, structured verdict/handoff extraction, and per-task state. It auto-writes bus messages and state on every call.
3. **`/collab`** — a Claude Code slash command implementing five collaboration modes (Think / Build / Build --fast / Debug / Review).
4. **`/collab-review`** — a lightweight slash command for a fast Codex second opinion on the current git diff.

---

## Install

### 1. Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- [Codex](https://openai.com/codex) CLI, authenticated with a ChatGPT subscription (the bridge forces subscription auth and unsets `OPENAI_API_KEY` to avoid silent API billing)

Verify Codex is on your PATH (or at one of the auto-detected locations: `/Applications/Codex.app/Contents/Resources/codex`, `/opt/homebrew/bin/codex`, `~/.npm-global/bin/codex`):

```bash
codex --version
```

### 2. Place the files

```bash
mkdir -p ~/Agent/collab

# The two scripts — put them somewhere stable and make them executable
cp board.sh        ~/Agent/collab/
cp codex-bridge.sh ~/Agent/collab/
chmod +x ~/Agent/collab/board.sh ~/Agent/collab/codex-bridge.sh

# Agent cards (capability discovery — the seed for N-agent) + handoff template
cp -R agents      ~/Agent/collab/
cp -R handoff     ~/Agent/collab/

# Initialize the blackboard (directories + layered memory)
~/Agent/collab/board.sh init

# The slash commands — drop into your Claude Code commands dir
cp commands/collab.md        ~/.claude/commands/
cp commands/collab-review.md ~/.claude/commands/
```

The blackboard lives under `~/Agent/collab/` by default. Set the `COLLAB_DIR` env var (or edit the top of the scripts) to relocate it.

### 3. Update the paths in `collab.md`

The slash command references `~/Agent/collab/codex-bridge.sh` and `~/Agent/collab/board.sh`. If you placed them elsewhere, update those paths in `~/.claude/commands/collab.md`.

---

## The blackboard (v2)

```
~/Agent/collab/
├── bus/log.ndjson       # append-only message bus (single source of truth)
├── cursor/<agent>       # each agent's read cursor (incremental reads, no cat-full-file)
├── memory/
│   ├── core.md          # resident layer: goals/state/constraints (few KB, never grows)
│   ├── decisions.md     # semantic layer: conclusions with provenance (author/time/evidence/status)
│   └── index.md         # flat index for `board.sh search`
├── handoff/<task>.md    # handoff = CONCLUSION ONLY; process stays isolated
├── work/<agent>/        # private per-agent scratch (not shared)
├── specs/               # immutable original artifacts
├── output/<task>.txt    # Codex full process log (isolated; read on demand)
├── state/<task>.json    # machine-readable task state + verdict
└── agents/*.md          # agent cards (capability discovery)
```

`board.sh` commands:

| Command | Purpose |
|---|---|
| `board.sh init` | create directories + layered memory |
| `board.sh write --from X --to Y --type T --task ID --ref P --summary S` | append a bus message (payload goes by `ref`, never pasted) |
| `board.sh read --as X [--all]` | incrementally read the bus (advances cursor) |
| `board.sh handoff <task_id> --from X --outcome ...` | write a handoff file (conclusion only) |
| `board.sh remember --author X --text ... --evidence P --status confirmed` | write to semantic memory (provenance + dedup) |
| `board.sh state <task_id> <running\|done\|failed> --verdict V --pid N` | structured task state (running sets a lease) |
| `board.sh heartbeat <task_id>` | renew the running task's lease |
| `board.sh check <task_id>` | liveness: `running\|done\|failed\|orphaned\|unknown` |
| `board.sh compact` | fold the old log into `archive/`, reset cursors |
| `board.sh search <kw>` | search bus + memory (ripgrep, or grep fallback) |
| `board.sh agents` | list agent cards |

Run `board.sh help` for details.

---

## Usage

### `/collab "..."` — Think (default)

Dual-model debate → synthesis. For architecture decisions, tech choices, strategic trade-offs.

1. Claude forms its own position **without sharing it** with Codex.
2. Codex is called independently and gives its recommendation.
3. Claude compares, synthesizes, and presents one verdict.
4. The decision is persisted to `memory/decisions.md` via `board.sh remember`.

### `/collab build "..."` — Build (full pipeline)

Six phases: **Clarify → Spec → Contract → Implement → Review**.

The Contract phase (Phase 3) is the key — Codex audits the spec *before* any code is written and produces an implementation contract (`proceed` | `needs_clarification` | `recommend_alternative`), now machine-readable as a JSON verdict in `state/<task>.json`. This catches flawed specs while they're still cheap to fix.

### `/collab build --fast "..."` — Build (lightweight)

Four steps: quick clarify → inline spec → Codex implements → Claude reviews. For routine tasks where the full ceremony isn't justified.

### `/collab debug "..."` — Debug

Both models form independent root-cause hypotheses. If they diverge, design a discriminating test to settle it with evidence.

### `/collab review` — Review

Codex reviews the current `git diff` as a skeptical architect. Findings are presented as a severity-ranked table. The diff is passed **by file ref**, not pasted into the prompt.

### `/collab-review` — Quick review

Lightweight version of `/collab review` for a fast second opinion before a commit.

---

## The bridge script

```
codex-bridge.sh [--task-id <id>] <mode> <role> <prompt>
```

| Mode    | Sandbox              | Use for                         |
|---------|----------------------|---------------------------------|
| `think` | read-only            | Analysis & debate               |
| `build` | danger-full-access   | Full implementation             |
| `debug` | read-only            | Root cause analysis             |
| `review`| read-only            | Code review                     |

| Role           | Shapes Codex into a…                            |
|----------------|--------------------------------------------------|
| `neutral`      | No role shaping (think mode)                     |
| `architect`    | Skeptical code reviewer (review mode)           |
| `oracle`       | Root-cause analyst (debug mode)                  |
| `builder`      | Independent implementer (build mode)            |
| `spec-reviewer`| Pre-implementation spec auditor (contract step) |

Built-in safety: retry with exponential backoff, per-task timeout (default 600s), and Codex never commits to git — Claude reviews and the user commits.

---

## Design principles

1. **Independence is the point.** Agreement → confidence up. Disagreement → that's where learning happens.
2. **Hide your hypothesis from the other model.** Contamination defeats the purpose.
3. **The contract phase is cheap and read-only.** It prevents expensive wrong implementations.
4. **Subscriptions only.** No API billing — the bridge forces ChatGPT subscription auth.
5. **State survives crashes.** Per-task files on disk; the bus is append-only; nothing in memory.
6. **Original layer ≠ semantic layer.** Raw artifacts (`specs/`) never change; reuse goes through the condensed semantic layer (`memory/decisions.md`).
7. **Handoff = conclusion only.** The process stays isolated in `output/`; the brain reads `handoff/`.
8. **The user has final say.** Never commit without explicit approval.

---

## License

MIT
