---
name: dev-pipeline
description: Use when a code change is big enough to deserve a written plan and an independent review before it merges, when the user asks for a reviewed or worktree-isolated dev loop, or when a whole epic of GitHub subtask issues should be carried to merge unattended. Covers plan gates, headless second-model review of the plan and the PR, isolated git worktrees, and autonomous multi-issue orchestration.
---

# dev-pipeline

A two-gate development pipeline plus an autonomous epic orchestrator, portable across projects.
A second model (the **reviewer** — `codex` by default, configurable) judges the plan and the PR
headlessly; **you** (Claude Code) orchestrate, implement, and address findings; everything
deterministic (worktree lifecycle, per-session state, epic sequencing) is owned by small bash scripts.

**The core idea:** the model does the one fuzzy step, freezes it into a JSON artifact (per-session
`state.json`, or an epic `manifest.json`), then hands off to a deterministic bash driver. GitHub is
the source of truth for "done."

## Before anything: locate the bundle

Every stage begins with this preamble. It works whether the skill is installed globally
(`~/.claude/skills/dev-pipeline`) or vendored into the repo, and it fails loudly outside a git repo
instead of silently resolving the repo root to `/`:

```bash
ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
for c in "${PIPELINE_SKILL_DIR:-}" "$HOME/.claude/skills/dev-pipeline" "$ROOT/.claude/skills/dev-pipeline"; do
  [ -n "$c" ] && [ -f "$c/references/scripts/pipeline-lib.sh" ] && { SKILL_DIR="$c"; break; }
done
source "$SKILL_DIR/references/scripts/pipeline-lib.sh" && pipeline_init
```
`pipeline_init` sets `ROOT`, `SKILL_DIR`, `PIPELINE_*`, `reviewer_invoke`, and the worktree hooks by
loading `pipeline.config.defaults.sh` then the repo's `.claude/pipeline.config.sh` on top.

If the repo has no `.claude/pipeline.config.sh`, say so and offer to run
`bash "$SKILL_DIR/install.sh" init` — the pipeline runs on defaults, but base branch, app subdir, and
the worktree setup hook are almost always project-specific.

## Workflow 1 — the two-gate pipeline (one change)
Run these stages in order; each auto-continues to the next. There are exactly two human stops.

1. **Triage** — trivial change (docs/config, nothing load-bearing) → just do it; else pipeline.
2. **Create the worktree** (`references/scripts/create-worktree.sh <branch>`) off the latest base,
   record branch+worktree in state, **before** planning.
3. **Brainstorm + write the plan** at a path matching `$PIPELINE_PLAN_GLOB`. → 🛑 **GATE 1** (user approves).
4. **spec-review** (`references/stages/spec-review.md`) — reviewer judges the plan; iterate to approve.
   📣 report, keep going.
5. **implement** (`references/stages/implement.md`) — TDD in the worktree; push; open a draft PR.
6. **code-review** (`references/stages/code-review.md`) — reviewer reviews the PR; address every
   comment; iterate to APPROVE. → 🛑 **GATE 2** (user approves merge) → squash-merge + cleanup.

The stage files carry the exact commands. State threads between stages via
`references/scripts/state.sh`, keyed by `$CLAUDE_CODE_SESSION_ID` (so concurrent sessions never
collide). The reviewer is always invoked through `references/scripts/run-reviewer.sh`.

## Workflow 2 — the autonomous epic orchestrator
`references/stages/epic.md`: parse an umbrella issue's checklist + dependency graph into a frozen
`manifest.json` (the one fuzzy step), then launch the deterministic driver
`references/scripts/run-epic.sh`, which runs every open subtask through Workflow 1 **sequentially in
dependency order, fully autonomously** — each in its own isolated `claude --session-id` session with
the autonomous-mode env var set (both gates non-interactive). It advances only when GitHub confirms a
subtask issue is CLOSED by its merge; halts (never cascades) on any failure; is resumable.
`epic-progress.sh` gives a live progress snapshot.

## Files
- `pipeline.config.defaults.sh` — shipped defaults. **Never edit**; they are overlaid per repo.
- `<repo>/.claude/pipeline.config.sh` — the only file you edit per project (seeded by `install.sh init`).
- `<repo>/.claude/REVIEW_RULES.md` — optional repo rules appended to both reviewer prompts.
- `references/scripts/` — `pipeline-lib.sh` (shared resolver, sourced by all), `state.sh`,
  `run-reviewer.sh`, `create-worktree.sh`, `cleanup-worktree.sh`, `run-epic.sh`, `epic-progress.sh`,
  `record-plan.sh` (the PostToolUse plan hook).
- `references/prompts/` — `plan-review.md`, `code-review.md`, `subtask.md`.
- `references/stages/` — `spec-review.md`, `implement.md`, `code-review.md`, `epic.md`.

## Gotchas that are easy to get wrong
- **State is per session id**, and always lives in the MAIN repo even when you are working inside a
  worktree. `planPath` is recorded relative to the checkout that contains it, so resolve it as
  `$WORKTREE/$planPath`.
- **Never symlink a generated client or node_modules into a worktree** — a shared stale client
  silently breaks tests. `pipeline_worktree_setup` builds fresh ones.
- **The code-review verdict comes from the `PIPELINE_REVIEW_DONE` log marker**, not the GitHub review
  state: a reviewer running as the PR author gets a 422 on self-approve and silently falls back to a
  COMMENTED review. Give the reviewer its own bot account and the GitHub state becomes authoritative.
- **Headless sessions must never end their turn while the reviewer runs** — nothing re-invokes a
  `claude -p` session. Block with foreground waits; see `references/prompts/subtask.md`.
- **Reviewer sandbox needs network + writes outside the worktree** (`gh`, and the verdict file in the
  main repo). That is why the default is `danger-full-access`.
