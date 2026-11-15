#!/usr/bin/env bash
# epic-progress.sh — print ONE compact progress snapshot for a running epic.
#
# Combines the orchestrator's milestone log (epic.log — subtasks spawned / merged / skipped
# / HALT / DONE) with the *live* pipeline stage of the currently-active subtask, read from
# that subtask's own per-session state.json (keyed by the session id the driver logs on each
# spawn). Read-only; safe to call repeatedly.
#
# Usage: epic-progress.sh <epic-number>
# Exit:  0 = epic still running  (poll again later)
#        3 = terminal            (epic.log shows DONE or HALT — stop polling)
#        2 = usage / not-found error
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"

EPIC="${1:?usage: epic-progress.sh <epic-number>}"
[[ "$EPIC" =~ ^([1-9][0-9]*|[A-Z][A-Z0-9_]*-[1-9][0-9]*)$ ]] \
  || pipeline_die "epic must be a GitHub number or full YouTrack ID"
pipeline_init

LOGDIR="$ROOT/$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC"
EPIC_LOG="$LOGDIR/epic.log"

if [ ! -f "$EPIC_LOG" ]; then
  echo "epic #$EPIC: no epic.log yet ($EPIC_LOG) — driver still bootstrapping."
  exit 0
fi

# The driver appends across relaunches (halt -> recover -> resume), so BOTH the printed
# history and the terminal/active detection must look only at the segment after the LAST
# "start —" line; otherwise a resumed epic shows a stale HALT from the previous run.
RUN_SEG="$(awk '/start —/{buf=""} {buf=buf $0 ORS} END{printf "%s", buf}' "$EPIC_LOG")"

echo "-- epic #$EPIC --------------------------------------"
grep -aE '(start —|spawn #|merged #|already CLOSED|HALT —|DONE —)' <<<"$RUN_SEG" \
  | sed 's/^\[epic #[A-Z0-9_-]*\] //' || true

if grep -qaE 'DONE —' <<<"$RUN_SEG"; then
  echo "-- status: COMPLETE  all subtasks merged"
  exit 3
fi
if grep -qaE 'HALT —' <<<"$RUN_SEG"; then
  echo "-- status: HALTED  (inspect the subtask log named above)"
  exit 3
fi

# A dead driver with a non-terminal log means the detached process crashed — say so rather
# than reporting "RUNNING" forever.
PIDF="$LOGDIR/run.pid"
if [ -f "$PIDF" ] && ! kill -0 "$(cat "$PIDF" 2>/dev/null || echo 0)" 2>/dev/null; then
  echo "-- status: DRIVER NOT RUNNING (pid $(cat "$PIDF" 2>/dev/null) is gone, log is not terminal)"
  echo "   check $LOGDIR/run.out — the detached driver likely crashed; re-launch to resume."
  exit 3
fi

active_line="$(grep -aE 'spawn #[A-Z0-9_-]+' <<<"$RUN_SEG" | tail -1 || true)"
if [ -z "$active_line" ]; then
  echo "-- status: RUNNING (no subtask spawned yet)"
  exit 0
fi

issue="$(sed -nE 's/.*spawn #([A-Z0-9_-]+).*/\1/p' <<<"$active_line")"
sid="$(sed -nE 's/.*sid=([0-9a-fA-F-]+).*/\1/p' <<<"$active_line")"

if grep -qaE "merged #$issue" <<<"$RUN_SEG"; then
  echo "-- status: RUNNING — #$issue merged, advancing to next subtask…"
  exit 0
fi

sf="$ROOT/$PIPELINE_RUNTIME_DIR/sessions/$sid/state.json"
if [ -z "$sid" ] || [ ! -f "$sf" ]; then
  echo "-- active: #$issue — session starting up…"
  exit 0
fi

python3 - "$sf" "$issue" <<'PY' || echo "-- active: #$issue — (state file unreadable)"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
issue = sys.argv[2]
phase = d.get("phase", "(starting)")
labels = {
    "planning":     "writing plan",
    "plan-review":  "reviewer spec-review",
    "approved":     "plan approved — starting implementation",
    "implementing": "implementing (TDD)",
    "code-review":  "reviewer code-review",
    "done":         "merged",
}
extra = []
if d.get("planRounds"): extra.append(f"plan rounds: {d['planRounds']}")
if d.get("prNumber"):   extra.append(f"PR #{d['prNumber']}")
if d.get("codeRounds"): extra.append(f"review rounds: {d['codeRounds']}")
suffix = f"  ({', '.join(extra)})" if extra else ""
print(f"-- active: #{issue} — {labels.get(phase, phase)}{suffix}")
if d.get("branch"):
    print(f"   branch: {d['branch']}")
PY
echo "-- status: RUNNING"
exit 0
