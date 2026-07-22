# Stage: epic (orchestrator — not a pipeline stage)

You are the **epic orchestrator**. Given an epic (umbrella) issue, you carry EVERY open subtask
through the standard dev-pipeline (worktree → plan → spec-review → implement → code-review →
**merge**), **one at a time in dependency order, fully autonomously** — auto-approving each plan
(reviewer spec-review is the real gate) and auto-merging on reviewer APPROVE. Each subtask runs in its
**own isolated `claude` session** so the per-session state machinery works untouched.

Epic issue: `$ARGUMENTS`

The design: **you do the one fuzzy step ONCE** — parse the epic's checklist + rough dependency graph
into a frozen, topologically-sorted manifest — then hand it to the deterministic driver `run-epic.sh`,
which mechanically spawns a session per subtask and refuses to advance until each subtask's issue is
actually CLOSED by its merge. The driver runs **detached**; you surface its progress with a periodic
**watch tick** (§6).

## 0. Already watching this epic? (resumable entry — CHECK FIRST)
The watch tick (§6) reschedules itself by re-firing this stage, so decide up front whether this is a
fresh launch or the next progress check.
```bash
ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
for c in "${PIPELINE_SKILL_DIR:-}" "$HOME/.claude/skills/dev-pipeline" "$ROOT/.claude/skills/dev-pipeline"; do
  [ -n "$c" ] && [ -f "$c/references/scripts/pipeline-lib.sh" ] && { SKILL_DIR="$c"; break; }
done
source "$SKILL_DIR/references/scripts/pipeline-lib.sh" && pipeline_init
EPIC="${ARGUMENTS:?pass the epic issue number}"
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

## 1. Read the epic
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
{ "epic": <EPIC>, "order": [<open subtasks, topo-sorted>], "deps": { "<issue>": [<deps>] }, "model": null }
```
`deps` only needs entries for issues that have dependencies. Leave `model` null to inherit the default.

## 4. Show the plan and confirm scope (NOT a pipeline gate)
Print a compact summary: the ordered list to run, which subtasks are **skipped** (already closed), and
the dependency edges enforced. This is a sanity check on the *orchestration plan*, not a per-subtask
approval. If anything looks wrong, fix the manifest before launching.

## 5. Launch the deterministic driver (detached)
The driver spawns one `claude` session per subtask and can run for hours, so it must outlive this
turn: `nohup` + background, never a foreground call.
```bash
mkdir -p "$LOGDIR"
nohup env PIPELINE_SKILL_DIR="$SKILL_DIR" \
  bash "$SKILL_DIR/references/scripts/run-epic.sh" "$MANIFEST" > "$LOGDIR/run.out" 2>&1 &
DRIVER_PID=$!
echo "$DRIVER_PID" > "$LOGDIR/run.pid"
echo "epic #$EPIC orchestrator started (pid $DRIVER_PID)"
sleep 2; kill -0 "$DRIVER_PID" 2>/dev/null || { echo "driver died immediately:"; cat "$LOGDIR/run.out"; }
```
If it died immediately, read `run.out` — the usual causes are an unauthenticated `gh`, a malformed
manifest, or `claude` not on PATH; all three are reported there explicitly. Then fall through to §6.

## 6. Watch tick — surface progress into the session
```bash
bash "$SKILL_DIR/references/scripts/epic-progress.sh" "$EPIC"; echo "rc=$?"
```
Relay its output verbatim, then act on the exit code:
- **`rc=3` (terminal)** — COMPLETE, HALTED, or DRIVER-CRASHED. Give a short final report (for HALT,
  show the tail of the named `subtask-<n>.log`; for a crash, the tail of `run.out`). **Do not
  reschedule.** On a fresh COMPLETE you may `rm -f "$LOGDIR/run.pid"`.
- **`rc=0` (still running)** — schedule the next check and end the turn: call **ScheduleWakeup** with
  `delaySeconds: 1200` and `prompt: "<the epic stage invocation> $EPIC"`. When it fires, §0 sees
  `WATCHING` and comes straight back here. Keep `reason` specific.

The user can interrupt anytime; the detached driver keeps running, and re-invoking this stage
re-attaches the watch (§0).

## 7. What the driver guarantees (so you can explain it)
- **Sequential, dependency-ordered.** Never starts a subtask whose dependency has not merged.
- **Isolated per subtask.** Each runs in a fresh `claude --session-id …` session with its own state;
  the autonomous-mode env var makes plan-approval and merge non-interactive.
- **Advances only on real merges.** After each session it re-checks the issue via `gh`; if not CLOSED
  (or the subtask printed `SUBTASK_BLOCKED`), it **halts** and does not start dependents.
- **Ticks the epic checklist** and comments on the epic on completion and on every halt.
- **Resumable.** Re-running skips already-merged subtasks and continues from the first open one.

Deterministic: the order, the gating, the advance condition. Not deterministic (inherent to the
model): each plan's prose, the code, and the reviewer's findings.
