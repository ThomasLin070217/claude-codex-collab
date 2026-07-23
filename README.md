# claude-codex-collab

A dual-agent collaboration system that makes **Claude Code** and **Codex CLI** work together as independent engineering partners — not as a subagent, but as a model from a different training lineage with different blind spots. The value is in the independence.

> **Claude is the brain (plan / review / decide). Codex is the hands (implement / second opinion).**

Communication happens over plain Bash. The filesystem is the only state. Zero new dependencies.

---

## Why

A single model has systematic blind spots. Two models from different training lineages, asked independently and then compared, catch what either would miss alone. This repo packages that into a concrete, reusable workflow with three pieces:

1. **`codex-bridge.sh`** — a Bash bridge that calls Codex CLI with role-aware prompts, sandbox modes, retry, and per-task state.
2. **`/collab`** — a Claude Code slash command implementing five collaboration modes (Think / Build / Build --fast / Debug / Review).
3. **`/collab-review`** — a lightweight slash command for a fast Codex second opinion on the current git diff.

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
# The bridge script — put it somewhere stable and make it executable
mkdir -p ~/collab
cp codex-bridge.sh ~/collab/
chmod +x ~/collab/codex-bridge.sh

# The slash commands — drop into your Claude Code commands dir
cp commands/collab.md        ~/.claude/commands/
cp commands/collab-review.md ~/.claude/commands/
```

The bridge writes its runtime state under `$HOME/collab/` by default (`state/`, `output/`, `reports/`, `specs/`). That directory is created on first use. Adjust `COLLAB_DIR` at the top of `codex-bridge.sh` if you want it elsewhere.

### 3. Update the paths in `collab.md`

The slash command references `~/collab/codex-bridge.sh`. If you placed the bridge elsewhere, update the path in `~/.claude/commands/collab.md`.

---

## Usage

### `/collab "..."` — Think (default)

Dual-model debate → synthesis. For architecture decisions, tech choices, strategic trade-offs.

1. Claude forms its own position **without sharing it** with Codex.
2. Codex is called independently and gives its recommendation.
3. Claude compares, synthesizes, and presents one verdict.

### `/collab build "..."` — Build (full pipeline)

Six phases: **Clarify → Spec → Contract → Implement → Review**.

The Contract phase (Phase 3) is the key — Codex audits the spec *before* any code is written and produces an implementation contract (`proceed` | `needs_clarification` | `recommend_alternative`). This catches flawed specs while they're still cheap to fix.

### `/collab build --fast "..."` — Build (lightweight)

Four steps: quick clarify → inline spec → Codex implements → Claude reviews. For routine tasks where the full ceremony isn't justified.

### `/collab debug "..."` — Debug

Both models form independent root-cause hypotheses. If they diverge, design a discriminating test to settle it with evidence.

### `/collab review` — Review

Codex reviews the current `git diff` as a skeptical architect. Findings are presented as a severity-ranked table.

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
5. **State survives crashes.** Per-task files on disk; nothing in memory.
6. **The user has final say.** Never commit without explicit approval.

---

## License

MIT
