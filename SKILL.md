---
name: dev-pipeline
description: Use when a code change deserves a written plan and independent review before merge, for a reviewed or worktree-isolated dev loop, or to carry a GitHub or YouTrack epic through sequential subtasks to merge. Covers plan gates, cross-model review, worktrees, and autonomous epic orchestration.
---

# dev-pipeline

A two-gate development pipeline plus an autonomous epic orchestrator, portable across projects.
A second model (the **reviewer**) judges the plan and the PR headlessly. **You**, the initiating
host, orchestrate, implement, and address findings: **Codex leads → Claude reviews; Claude Code
leads → Codex reviews.** Explicit repo reviewer overrides still win. Everything
deterministic (worktree lifecycle, per-session state, epic sequencing) is owned by small bash scripts.

**The core idea:** the model does the one fuzzy step, freezes it into a JSON artifact (per-session
`state.json`, or an epic `manifest.json`), then hands off to a deterministic bash driver. GitHub
verifies PR merges; the selected issue tracker verifies issue completion.

## Before anything: locate the bundle

Every stage begins with this preamble. It works whether the skill is installed globally
for Codex (`~/.agents/skills/dev-pipeline`), Claude Code (`~/.claude/skills/dev-pipeline`), or
vendored into the repo, and it fails loudly outside a git repo
instead of silently resolving the repo root to `/`:

```bash
ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)" || exit 2
SKILL_DIR=""
for c in "${PIPELINE_SKILL_DIR:-}" "$HOME/.agents/skills/dev-pipeline" \
  "${CODEX_HOME:-$HOME/.codex}/skills/dev-pipeline" "$HOME/.claude/skills/dev-pipeline" \
  "$ROOT/.agents/skills/dev-pipeline" "$ROOT/.codex/skills/dev-pipeline" "$ROOT/.claude/skills/dev-pipeline"; do
  [ -n "$c" ] && [ -f "$c/references/scripts/pipeline-lib.sh" ] && { SKILL_DIR="$c"; break; }
done
[ -n "$SKILL_DIR" ] || { echo "dev-pipeline bundle not found" >&2; exit 2; }
source "$SKILL_DIR/references/scripts/pipeline-lib.sh" && pipeline_init
```
`pipeline_init` sets `ROOT`, `SKILL_DIR`, `PIPELINE_*`, `reviewer_invoke`, and the worktree hooks by
loading `pipeline.config.defaults.sh` then the repo's `.claude/pipeline.config.sh` on top.

Host detection uses `CODEX_THREAD_ID` or the Claude session environment. If unavailable, explicitly
export `PIPELINE_HOST=codex` or `claude` in every shell call. State uses `PIPELINE_SESSION_ID` when
set, otherwise the host's native ID (`CODEX_THREAD_ID` / `CLAUDE_CODE_SESSION_ID`). If neither is
available, generate one UUID once and preserve it as `PIPELINE_SESSION_ID` throughout this run.
After writing a plan, **both hosts** explicitly run `state.sh set planPath=<worktree-relative-path>`;
Codex does not use Claude's PostToolUse hook. Config and runtime paths under `.claude/` are shared
by both modes for compatibility. `install.sh codex` links the bundle for Codex discovery.

## First run in a repo: ask, then write the config

Everything project-specific lives in `<repo>/.claude/pipeline.config.sh`, never in this bundle. When
that file does not exist, set the repo up before any stage runs:

1. Run `bash "$SKILL_DIR/install.sh" init`. It seeds the config with the detected base branch, adds
   the Claude plan hook and the `/pipeline:*` commands, and gitignores the runtime dir.
2. Ask the user the questions below in one batch (use the host's question tool if it has one). Offer
   the detected value or the default as the first answer, so accepting it costs one click.

   | Question | Variable | Default |
   |---|---|---|
   | Which branch do PRs target? | `PIPELINE_BASE_BRANCH` | the remote's default branch |
   | Where should worktrees go? | `PIPELINE_WORKTREE_ROOT` | sibling dir `<repo>-wt` |
   | Does the app live in a subdirectory? | `PIPELINE_APP_SUBDIR` | repo root |
   | What prepares a fresh worktree (install deps, generate clients)? | `pipeline_worktree_setup` | nothing |
   | Which gitignored files are safe to share into worktrees (`.env`)? | `PIPELINE_WORKTREE_SYMLINKS` | none |
   | Where are plans written? | `PIPELINE_PLAN_GLOB` | any path containing `/plans/` |
   | Branch name prefix? | `PIPELINE_BRANCH_PREFIX` | `feat/` |
   | Merge method? | `PIPELINE_MERGE_METHOD` | `squash` |
   | Who may merge (GitHub logins)? | `PIPELINE_MERGERS` | anyone who runs the pipeline |
   | Which CLI reviews? | `PIPELINE_REVIEWER` | `auto`, the other CLI |
   | Most review rounds per gate? | `PIPELINE_MAX_ROUNDS` | `10` |
   | Are epics in YouTrack? If so, which fields mark a subtask done? | `PIPELINE_YOUTRACK_DONE_FIELDS` | GitHub epics only |

   Read the repo first (its README, build files and scripts) and propose a setup command, so the
   user confirms an answer instead of writing one.
3. Write each answer that differs from the default into `.claude/pipeline.config.sh`, and offer to
   create `.claude/REVIEW_RULES.md` from `references/REVIEW_RULES.example.md`.
4. Run `bash "$SKILL_DIR/install.sh" doctor` and show its output.

A headless session (an epic subtask) never asks: it runs on the config that exists, or on the
defaults.

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
   comment; iterate to APPROVE. → 🛑 **GATE 2** (user approves merge) → merge
   (`$PIPELINE_MERGE_METHOD`) + cleanup. When the repo sets `PIPELINE_MERGERS` and you are not in
   it, GATE 2 instead marks the PR ready for their review and stops, and epic mode is not available.

The stage files carry the exact commands. State threads between stages via
`references/scripts/state.sh`, keyed by the current pipeline session ID (so concurrent sessions never
collide). The reviewer is always invoked through `references/scripts/run-reviewer.sh`.

## Workflow 2 — the autonomous epic orchestrator
`references/stages/epic.md`: parse an umbrella issue's subtasks + dependency graph into a frozen
`manifest.json` (the one fuzzy step), then launch the deterministic driver
`references/scripts/run-epic.sh`, which runs every open subtask through Workflow 1 **sequentially in
dependency order, fully autonomously** — each in a fresh instance of the initiating CLI with
the autonomous-mode env var set (both gates non-interactive). It advances only when the selected
tracker confirms a subtask is complete; halts (never cascades) on any failure; is resumable.
`epic-progress.sh` gives a live progress snapshot.

The driver supports numeric GitHub issues and full YouTrack IDs. For YouTrack, read
`references/trackers/youtrack.md`: use linked children, project-specific completion fields, and the
initiating host's MCP configuration. It requires `uv`; credentials stay in the existing host config.
The driver verifies each merged GitHub PR, completes the YouTrack issue through MCP, and reads it
back before advancing. Never strip a YouTrack prefix and pass its number to `gh`.
Freeze `host` (`codex` or `claude`) in the manifest so resume keeps the same implementer and reviewer.

## Files
- `pipeline.config.defaults.sh` — shipped defaults. **Never edit**; they are overlaid per repo.
- `<repo>/.claude/pipeline.config.sh`: the only file you edit per project (seeded by `install.sh init`,
  filled in by the first-run questions above).
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
  headless CLI session. Stay in the turn and poll with waits of at most 30 seconds; see
  `references/prompts/subtask.md`.
- **Reviewer sandbox needs network + writes outside the worktree** (`gh`, and the verdict file in the
  main repo). That is why the default is `danger-full-access`.
