# Stage: epic (orchestrator — not a pipeline stage)

You are the **epic orchestrator**. Given an epic (umbrella) issue, you carry EVERY open subtask
through the standard dev-pipeline (worktree → plan → spec-review → implement → code-review →
**merge**), **one at a time in dependency order, fully autonomously** — auto-approving each plan
(reviewer spec-review is the real gate) and auto-merging on reviewer APPROVE. Each subtask runs in its
**own isolated session of the initiating host** (Codex or Claude); its reviewer uses the other CLI.

Epic issue: `$ARGUMENTS`

Numeric IDs select GitHub; full IDs such as `PROJ-100` select YouTrack. For YouTrack, read
`references/trackers/youtrack.md` and use its discovery/manifest steps instead of §§1–3 below, then
continue at §4. Never reinterpret a YouTrack ID as a GitHub issue number.

Epic mode merges every subtask, so it is only for someone allowed to merge (`PIPELINE_MERGERS` in
the repo config). If `pipeline_may_merge` fails for you, stop and say so: `run-epic.sh` refuses to
start anyway.

The design: **you do the one fuzzy step ONCE** — parse the epic's checklist + rough dependency graph
into a frozen, topologically-sorted manifest — then hand it to the deterministic driver `run-epic.sh`,
which mechanically spawns a session per subtask and refuses to advance until each subtask's issue is
complete after merge. The driver runs **detached**; you surface its progress with a periodic
**watch tick** (§6).

## 0. Already watching this epic? (resumable entry — CHECK FIRST)
On entry or manual re-entry, decide whether this is a fresh launch or the next progress check.
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
EPIC="${ARGUMENTS:?pass the epic issue number}"
if [[ "$EPIC" =~ ^[1-9][0-9]*$ ]]; then TRACKER=github
elif [[ "$EPIC" =~ ^[A-Z][A-Z0-9_]*-[1-9][0-9]*$ ]]; then TRACKER=youtrack
else echo "expected a GitHub issue number or full YouTrack ID" >&2; exit 2; fi
LOGDIR="$ROOT/$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC"
PIDF="$LOGDIR/run.pid"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then echo WATCHING; else echo FRESH; fi
```
(`$LOGDIR` is defined here so the watch tick in §6 has it on a re-entry that skips §§1–5.)
- **`WATCHING`** → driver alive. **Skip §§1–5** and go straight to the **watch tick (§6)**. Do not
  re-parse the epic, do not rewrite the manifest, do not relaunch.
- **`FRESH`** → no live driver. If `epic.log` exists and shows `DONE`/`HALT`, this epic already
  finished (or halted) — run `epic-progress.sh` once (§6), report, and stop. If `epic.log` exists but
  is **not** terminal and the pid is dead, the detached driver **crashed** — show the tail of
  `epics/epic-$EPIC/run.out`, say so, and stop. Otherwise it's a genuine first run → continue to §1.

## 1. Read the epic (GitHub; use the YouTrack reference for that tracker)
```bash
gh issue view "$EPIC" --json number,title,state,body
```
If the issue is not an epic (no subtask checklist), **STOP** and say so.

## 2. Parse the subtasks (freeze the graph — the ONLY fuzzy step)
From the epic body extract:
- **Subtasks** — every `- [ ] #N` / `- [x] #N` checklist line. `[x]` = already done.
- **Dependencies** — the "Rough dependency graph" line(s) (e.g. `#45 → #46 → {#47, #48}`; `#48 → #49`).
  Also honour any explicit `Depends on: #N` in a subtask's own body.

Then, **for each unchecked subtask, confirm its live state** (`gh issue view N --json state`). The set
to run = subtasks that are **OPEN**. Compute the execution **order**: topologically sort the OPEN
subtasks by the dependency graph; use checklist order as the base and only reorder to satisfy an
explicit dependency; tie-break by ascending issue number. **Sequential only** — never parallel.

## 3. Write the frozen manifest
```bash
SDIR="$(bash "$SKILL_DIR/references/scripts/state.sh" dir)"
MANIFEST="$SDIR/epic-$EPIC.manifest.json"
```
Write `$MANIFEST` as JSON:
```json
{ "epic": <EPIC>, "order": [<open subtasks, topo-sorted>], "deps": { "<issue>": [<deps>] }, "host": "<PIPELINE_HOST>", "model": null }
```
`deps` only needs entries for issues that have dependencies. Set `host` to the resolved initiating
host. Leave `model` null to use that CLI's configured default; a pin must belong to that host.
Older manifests without `host` use the detected host; set it explicitly before resuming elsewhere.

## 4. Show the plan and confirm scope (NOT a pipeline gate)
Print a compact summary: the ordered list to run, which subtasks are **skipped** (already closed), and
the dependency edges enforced. This is a sanity check on the *orchestration plan*, not a per-subtask
approval. If anything looks wrong, fix the manifest before launching.

## 5. Launch the deterministic driver (detached)
The driver spawns one session of the manifest's host per subtask and can run for hours, so it must outlive this
turn: `nohup` + background, never a foreground call.
```bash
mkdir -p "$LOGDIR"
nohup env PIPELINE_SKILL_DIR="$SKILL_DIR" PIPELINE_HOST="$PIPELINE_HOST" \
  bash "$SKILL_DIR/references/scripts/run-epic.sh" "$MANIFEST" > "$LOGDIR/run.out" 2>&1 &
DRIVER_PID=$!
echo "$DRIVER_PID" > "$LOGDIR/run.pid"
echo "epic #$EPIC orchestrator started (pid $DRIVER_PID)"
sleep 2; kill -0 "$DRIVER_PID" 2>/dev/null || { echo "driver died immediately:"; cat "$LOGDIR/run.out"; }
```
If it died immediately, read `run.out` — the usual causes are an unauthenticated `gh`, a malformed
manifest, or the selected CLI not on PATH; all three are reported there explicitly. Then fall through to §6.

## 6. Watch tick — surface progress into the session
```bash
bash "$SKILL_DIR/references/scripts/epic-progress.sh" "$EPIC"; echo "rc=$?"
```
Relay its output verbatim, then act on the exit code:
- **`rc=3` (terminal)** — COMPLETE, HALTED, or DRIVER-CRASHED. Give a short final report (for HALT,
  show the tail of the named `subtask-<n>.log`; for a crash, the tail of `run.out`). **Do not
  reschedule.** On a fresh COMPLETE you may `rm -f "$LOGDIR/run.pid"`.
- **`rc=0` (still running)** — in Codex, or any host without a reliable wakeup tool, keep the turn
  active, wait up to 30 seconds, then check again. Use the host's process polling/wait tool where
  available and surface meaningful progress at least once a minute. Interactive Claude Code may
  retain its scheduled watch: call `ScheduleWakeup` (if available) with `delaySeconds: 1200` and
  `prompt: "<the epic stage invocation> $EPIC"`, then end the turn. Never assume this tool exists
  in Codex, or end a headless turn expecting automatic re-entry.

The user can interrupt anytime; the detached driver keeps running, and re-invoking this stage
re-attaches the watch (§0).

## 7. What the driver guarantees (so you can explain it)
- **Sequential, dependency-ordered.** Never starts a subtask whose dependency has not merged.
- **Isolated per subtask.** Each runs in a fresh `claude -p` or `codex exec` session with a unique
  `PIPELINE_SESSION_ID`; inherited parent native session IDs are removed. Codex leads with Claude
  review, and Claude leads with Codex review, unless the project overrides the reviewer;
  the autonomous-mode env var makes plan-approval and merge non-interactive.
- **Advances only on completion.** GitHub issues must be CLOSED. For YouTrack, the driver verifies
  the recorded PR is merged into the configured repository/base, updates only the configured
  completion fields through MCP, and requires a matching resolved read-back. Errors or a subtask's
  `SUBTASK_BLOCKED` marker halt the run before dependents.
- **Records progress** through GitHub checklists or YouTrack linked children and comments.
- **Closes the epic** once nothing is left. The condition is re-read from the body, not taken from
  the manifest (which holds only what was open at launch): every `- [ ] #N` / `- [x] #N` issue must
  be CLOSED. A subtask added mid-run therefore leaves the epic open rather than buried under a
  closed umbrella.
- **Resumable.** Re-running skips already-merged subtasks and continues from the first open one.

Deterministic: the order, the gating, the advance condition. Not deterministic (inherent to the
model): each plan's prose, the code, and the reviewer's findings.
