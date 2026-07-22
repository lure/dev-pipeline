# dev-pipeline

A portable, project-agnostic two-gate development pipeline and autonomous epic orchestrator, packaged
as a Claude Code skill. A second model — the **reviewer**, headless `codex` by default but
configurable — judges the plan and the PR; Claude Code orchestrates, implements, and addresses
findings. Everything deterministic (git worktree lifecycle, per-session state, epic sequencing) is
owned by small bash scripts. The model does the fuzzy part; bash owns the repeatable part; GitHub is
the source of truth for "done."

## What you get

- **Workflow 1 — two-gate pipeline** for a single change: worktree → plan → 🛑 GATE 1 → reviewer
  spec-review → implement (TDD, draft PR) → reviewer code-review → 🛑 GATE 2 → squash-merge + cleanup.
  Each change is isolated in its own git worktree; state threads between stages per session id.
- **Workflow 2 — autonomous epic orchestrator**: parse an umbrella GitHub issue's checklist +
  dependency graph into a frozen manifest, then run every open subtask through Workflow 1 sequentially
  in dependency order, fully autonomously (both gates non-interactive), each in its own isolated
  `claude` session. Advances only on real merges; halts (never cascades) on failure; resumable.

## Requirements

- `git`, `python3`, `bash`, and the GitHub CLI `gh` (authenticated) on PATH.
- Your chosen reviewer CLI on PATH (default: `codex`, configured + authenticated). Swap it in your
  repo config → `reviewer_invoke`.
- The `claude` CLI on PATH (for Workflow 2's per-subtask sessions).
- GitHub issues used for epics (Workflow 2 only).

No coreutils needed: the `REVIEWER_TIMEOUT` cap is enforced by a built-in process-group watchdog, so
it works on stock macOS where GNU `timeout` is absent.

## Install

**Once per machine** — install the skill globally:

```bash
bash install.sh global
# -> ~/.claude/skills/dev-pipeline
```

Re-run it any time to update the bundle; it never touches your repos.

**Once per repo** — wire it in:

```bash
cd /path/to/your/repo
bash ~/.claude/skills/dev-pipeline/install.sh init          # or: init <namespace>
```

`init` is idempotent and non-destructive. It:
1. seeds `.claude/pipeline.config.sh` (never overwrites an existing one) with the base branch
   auto-detected from `origin/HEAD`;
2. merges the PostToolUse plan-recording hook into `.claude/settings.json` — and **refuses** to touch
   that file if it is not valid JSON, rather than replacing it;
3. writes four slash-command shims under `.claude/commands/<namespace>/` (default namespace
   `pipeline`), with the absolute skill path baked in;
4. adds `.claude/dev-pipeline/` to `.gitignore`.

Then:
1. Edit `.claude/pipeline.config.sh` — at minimum `PIPELINE_BASE_BRANCH`, `PIPELINE_APP_SUBDIR`,
   `PIPELINE_PLAN_GLOB`, and `pipeline_worktree_setup` (your deps-install + client generation for a
   fresh worktree).
2. Optionally write `.claude/REVIEW_RULES.md` (see `references/REVIEW_RULES.example.md`) — it is
   appended to both reviewer prompts as load-bearing repo rules.
3. Run `bash ~/.claude/skills/dev-pipeline/install.sh doctor` to verify CLIs, auth, hook, and what
   your config actually resolves to.
4. **Start a new Claude Code session** — settings and hooks are read at startup.
5. Drive a change with `/pipeline:spec-review` after you've written a plan, or run an epic with
   `/pipeline:epic <issue>`. Or just describe the change and point the model at the `dev-pipeline`
   skill — the stage files carry the exact steps.

## Configuration surface (`<repo>/.claude/pipeline.config.sh`)

Defaults live in the bundle's `pipeline.config.defaults.sh` (never edit that); your repo file is
sourced on top and only needs the deltas. `PIPELINE_CONFIG=/path/to/file.sh` overrides the location.

| Knob | Meaning |
|---|---|
| `PIPELINE_RUNTIME_DIR` | where per-session state, epic logs, manifests live (default `.claude/dev-pipeline`) |
| `PIPELINE_BASE_BRANCH` | branch PRs target + worktrees fork from (default: `origin/HEAD`) |
| `PIPELINE_WORKTREE_ROOT` | where isolated worktrees are created (default: sibling `<repo>-wt`) |
| `PIPELINE_APP_SUBDIR` | sub-dir the app lives in (`""` = repo root) |
| `PIPELINE_PLAN_GLOB` | path fragment identifying a plan file (drives the record-plan hook) |
| `PIPELINE_AUTO_ENV` | env var name the epic driver sets to `auto` for non-interactive gates |
| `REVIEWER_MODEL/EFFORT/SANDBOX/TIMEOUT` | reviewer knobs used by the default `reviewer_invoke` |
| `reviewer_invoke <prompt-file>` | **the reviewer command** — swap to change reviewers entirely |
| `REVIEW_RULES_FILE` | optional file appended to both reviewer prompts (default `.claude/REVIEW_RULES.md`) |
| `pipeline_worktree_setup <appdir>` | per-worktree deps install / client generation |
| `pipeline_worktree_teardown <appdir>` | cleanup hook before worktree removal |
| `PIPELINE_WORKTREE_SYMLINKS` | gitignored paths safe to symlink into a worktree (never node_modules / generated clients) |

## How the pieces relate

```
slash-command shim  ──runs──▶  references/stages/<stage>.md   (orchestration prose; the model follows it)
                                        │
                                        │  every stage first sources:
                                        ├─ references/scripts/pipeline-lib.sh  → ROOT, SKILL_DIR, config
                                        │        └─ pipeline.config.defaults.sh + <repo>/.claude/pipeline.config.sh
                                        ├─ references/scripts/state.sh          per-session JSON state (keyed by session id)
                                        ├─ references/scripts/run-reviewer.sh   ─▶ reviewer_invoke (your config)
                                        │        └─ references/prompts/*.md  (+ REVIEW_RULES.md appended)
                                        ├─ references/scripts/create-worktree.sh / cleanup-worktree.sh  (calls the setup/teardown hooks)
                                        └─ (epic) run-epic.sh ──spawns──▶ claude --session-id (prompts/subtask.md) ──▶ Workflow 1
```

## Notes / gotchas baked in

- **State is per session id**, and always lives in the MAIN repo — resolved through git's *common*
  dir, so it is the same file whether you call it from the main checkout or a linked worktree.
  Concurrent changes in separate sessions never collide.
- **`planPath` is relative to the checkout that contains it.** The default loop plans inside the
  worktree, so stages resolve it as `$WORKTREE/$planPath`.
- **Never symlink a generated client or node_modules into a worktree** — a shared stale client
  silently breaks tests. `pipeline_worktree_setup` builds fresh ones; teardown repairs the main
  checkout if a per-worktree install ever repointed it.
- **Code-review verdict comes from the `PIPELINE_REVIEW_DONE` log marker**, not the GitHub review
  state — if the reviewer runs under the PR author's account GitHub 422s a self-approve and it falls
  back to a COMMENTED review. Give the reviewer its own bot account and the GitHub state becomes
  authoritative.
- **The reviewer sandbox default is `danger-full-access` on purpose**: code review needs network for
  `gh`, and plan review writes its verdict into the main repo while its cwd is the worktree.
- **Headless subtasks must never end their turn while the reviewer runs** — nothing re-invokes a
  `claude -p` session. `prompts/subtask.md` blocks with foreground waits instead.
- **`cleanup-worktree.sh` only removes paths git reports as registered worktrees** of this repo, and
  never the main checkout — a wrong or empty path is refused, not force-removed.

## Tests

The bundle ships no test runner, but two harnesses were used to validate it and are worth re-running
after changes (they need no network, no `gh`, and no real reviewer):

- a smoke suite covering install/init idempotence, ROOT resolution, state, worktree create/cleanup,
  the plan hook, and reviewer timeout enforcement;
- an orchestrator suite that drives `run-epic.sh` against fake `gh` and `claude` binaries, covering
  the happy path, resume, dependency guard, `SUBTASK_BLOCKED`, and non-merging sessions.
