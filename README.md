# dev-pipeline

A portable, project-agnostic two-gate development pipeline and autonomous epic orchestrator, packaged
for Codex and Claude Code. The initiating host orchestrates, implements, and addresses findings;
the other CLI reviews the plan and PR headlessly. **Codex leads → Claude reviews; Claude Code
leads → Codex reviews.** Explicit project reviewer overrides take precedence. Everything
deterministic (git worktree lifecycle, per-session state, epic sequencing) is
owned by small bash scripts. GitHub verifies PR merges; the selected tracker verifies issue completion.

## What you get

- **Workflow 1 — two-gate pipeline** for a single change: worktree → plan → 🛑 GATE 1 → reviewer
  spec-review → implement (TDD, draft PR) → reviewer code-review → 🛑 GATE 2 → merge + cleanup.
  Each change is isolated in its own git worktree; state threads between stages per session id.
- **Workflow 2 — autonomous epic orchestrator**: parse a GitHub checklist or YouTrack linked children +
  dependency graph into a frozen manifest, then run every open subtask through Workflow 1 sequentially
  in dependency order, fully autonomously (both gates non-interactive), each in its own isolated
  session of the initiating CLI. Advances only on real merges; halts (never cascades) on failure; resumable.

## Requirements

- `git`, `python3`, `bash`, and the GitHub CLI `gh` (authenticated) on PATH.
- Both `codex` and `claude` CLIs on PATH, configured and authenticated for the default cross-review.
  Custom `reviewer_invoke` functions can use a different reviewer.
- GitHub or YouTrack issues for epics (Workflow 2 only). YouTrack additionally requires `uv` and
  a configured YouTrack MCP connection in the initiating host. See
  [YouTrack setup and completion rules](references/trackers/youtrack.md).

No coreutils needed: the `REVIEWER_TIMEOUT` cap is enforced by a built-in process-group watchdog, so
it works on stock macOS where GNU `timeout` is absent.

## Install

**Once per machine** — install the skill globally:

```bash
bash install.sh global
# -> ~/.claude/skills/dev-pipeline
bash ~/.claude/skills/dev-pipeline/install.sh codex
# -> ~/.agents/skills/dev-pipeline (symlink to that same bundle)
```

Re-run `global` any time to update the shared bundle; it never touches your repos.
`codex` is idempotent and refuses to overwrite another installation. `CODEX_SKILLS_DIR` overrides
its destination parent directory. Start a new Codex session to refresh discovery, then invoke
`$dev-pipeline` (or read its `SKILL.md` by path in an existing session).

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

You can also skip `init` and just start the skill in the repo. On its first run there it runs `init`
itself, asks you the project-specific questions (base branch, worktree setup, merge method, who may
merge, and the rest of the table below), writes your answers into `.claude/pipeline.config.sh`, and
runs `doctor`. Nothing project-specific lives in the bundle.

Then:
1. Edit `.claude/pipeline.config.sh` if the first-run answers need changing: at minimum
   `PIPELINE_BASE_BRANCH`, `PIPELINE_APP_SUBDIR`, `PIPELINE_PLAN_GLOB`, and `pipeline_worktree_setup`
   (your deps-install + client generation for a fresh worktree).
2. Optionally write `.claude/REVIEW_RULES.md` (see `references/REVIEW_RULES.example.md`) — it is
   appended to both reviewer prompts as load-bearing repo rules.
3. Run `bash ~/.claude/skills/dev-pipeline/install.sh doctor` to verify CLIs, auth, hook, and what
   your config actually resolves to.
4. **Start a new host session** to refresh skill discovery (and Claude settings/hooks).
5. Drive a change with `/pipeline:spec-review` after you've written a plan, or run an epic with
   `/pipeline:epic <issue>`. Or just describe the change and point the model at the `dev-pipeline`
   skill — the stage files carry the exact steps. In Codex, invoke `$dev-pipeline` and name the stage.

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
| `PIPELINE_BRANCH_PREFIX` | prefix of each change's branch (default `feat/`) |
| `PIPELINE_MERGE_METHOD` | `squash` (default), `merge` or `rebase`, passed to `gh pr merge` |
| `PIPELINE_MERGERS` | GitHub logins allowed to merge, space-separated; empty (default) = whoever runs it. Others end GATE 2 at a PR ready for review, and epic mode refuses to start for them |
| `PIPELINE_MAX_ROUNDS` | reviewer rounds per gate before the stage stops (default 10) |
| `PIPELINE_YOUTRACK_MCP_SERVER` | existing MCP connection name (default `youtrack`) |
| `PIPELINE_YOUTRACK_MCP_CONFIG` | optional path to an existing MCP JSON config |
| `PIPELINE_YOUTRACK_TIMEOUT` | timeout per MCP operation (default 120 seconds) |
| `PIPELINE_YOUTRACK_DONE_FIELDS` | JSON fields that mark a subtask done, e.g. `{"Stage":"Done"}`; empty = read the schema and ask |
| `PIPELINE_HOST` | `codex` or `claude`; auto-detected from the native session environment |
| `PIPELINE_SESSION_ID` | explicit stable state key; falls back to the host native session ID |
| `PIPELINE_REVIEWER` | `auto` (opposite host), `codex`, or `claude` |
| `CODEX_REVIEWER_MODEL` / `CLAUDE_REVIEWER_MODEL` | provider-specific pins; empty uses the CLI default |
| `REVIEWER_MODEL` | legacy Codex-only model pin, never forwarded to Claude |
| `REVIEWER_EFFORT/TIMEOUT` | common review effort and wall-clock cap |
| `REVIEWER_SANDBOX` / `CLAUDE_REVIEWER_PERMISSION_MODE` | permissions for each reviewer CLI |
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
                                        └─ (epic) run-epic.sh ──spawns──▶ initiating CLI (prompts/subtask.md) ──▶ Workflow 1
```

## Notes / gotchas baked in

- **State is per session id**, and always lives in the MAIN repo — resolved through git's *common*
  dir, so it is the same file whether you call it from the main checkout or a linked worktree.
  `PIPELINE_SESSION_ID` takes precedence; otherwise Codex uses `CODEX_THREAD_ID`, and Claude uses
  `CLAUDE_CODE_SESSION_ID`. Without a native ID, generate one UUID once and export it in every call.
  The epic driver assigns a fresh ID per child and removes inherited native IDs.
- **`planPath` is relative to the checkout that contains it.** The default loop plans inside the
  worktree, so stages resolve it as `$WORKTREE/$planPath`. Both hosts explicitly record it via
  `state.sh set planPath=...`; Claude also supports the PostToolUse hook. The `.claude/` config
  and runtime paths are shared for compatibility.
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
  headless CLI session. `prompts/subtask.md` uses short foreground waits instead.
- **Epic manifests freeze `host`** (`codex` or `claude`) and optionally `model` for that host.
  Legacy manifests without `host` use detection. Progress polling works in either host without
  requiring a Claude-only wakeup tool.
- **`cleanup-worktree.sh` only removes paths git reports as registered worktrees** of this repo, and
  never the main checkout — a wrong or empty path is refused, not force-removed.

## Tests

Run `python3 -m unittest discover -s tests -v`. The suite uses temporary repositories, stub
`codex`, `claude`, and `gh` CLIs, and a local stdio MCP server; it makes no model or GitHub requests.
YouTrack integration tests require `uv` and its cached SDK dependencies. Prepare the cache once with
`uv run --script references/scripts/youtrack_mcp.py --help`; the tests use offline mode. They verify both host modes,
state isolation, reviewer overrides and model pins, timeout/failure handling, epic routing and halt
conditions, manifest validation, and Codex installation without overwriting existing files.
