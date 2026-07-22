#!/usr/bin/env bash
# run-epic.sh — deterministic epic orchestrator.
#
# Runs every not-yet-merged subtask of an epic through the FULL pipeline, one at a time in
# dependency order, FULLY AUTONOMOUSLY (auto-approve plan, auto-merge on reviewer APPROVE).
# Each subtask runs in its OWN fresh, isolated `claude` session (forced `--session-id`), so
# state.sh — keyed by $CLAUDE_CODE_SESSION_ID — stays isolated per subtask and the
# per-session pipeline machinery works untouched.
#
# The single fuzzy step (parsing the epic's checklist + rough dependency graph into a
# topological order) is done ONCE by the epic stage, which freezes the result into a
# manifest and hands it here. THIS script is fully deterministic: it reads the frozen order
# and, per subtask, spawns the session, waits, and advances only once GitHub confirms the
# subtask issue is CLOSED (i.e. its PR merged).
#
# Usage: run-epic.sh <manifest.json>
#   manifest shape:
#     { "epic": 44, "order": [48, 49, 50], "deps": { "49": [48] }, "model": null }
#
# Resumable + idempotent: re-running skips any subtask whose issue is already CLOSED.
# Halts (never cascades) if a subtask fails to merge or reports SUBTASK_BLOCKED.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"

MANIFEST="${1:?usage: run-epic.sh <manifest.json>}"
[ -f "$MANIFEST" ] || pipeline_die "manifest not found: $MANIFEST"
pipeline_init
pipeline_require claude gh python3 git

PROMPT_TMPL="$SKILL_DIR/references/prompts/subtask.md"
[ -f "$PROMPT_TMPL" ] || pipeline_die "prompt template missing: $PROMPT_TMPL"

# Validate the manifest up front — a typo here otherwise surfaces as a mystery halt.
MANIFEST_JSON="$MANIFEST" python3 - <<'PY' || exit 2
import json, os, sys
try:
    m = json.load(open(os.environ["MANIFEST_JSON"]))
except Exception as e:
    sys.exit(f"run-epic: manifest is not valid JSON: {e}")
if not isinstance(m, dict):
    sys.exit("run-epic: manifest must be a JSON object")
if not str(m.get("epic", "")).strip():
    sys.exit("run-epic: manifest is missing 'epic'")
order = m.get("order")
if not isinstance(order, list) or not all(str(x).strip().isdigit() for x in order):
    sys.exit("run-epic: manifest 'order' must be a list of issue numbers")
if len(set(map(str, order))) != len(order):
    sys.exit("run-epic: manifest 'order' contains duplicates")
deps = m.get("deps") or {}
if not isinstance(deps, dict):
    sys.exit("run-epic: manifest 'deps' must be an object")
known = {str(x) for x in order}
for k, v in deps.items():
    if not isinstance(v, list):
        sys.exit(f"run-epic: deps[{k}] must be a list")
    if str(k) not in known:
        print(f"run-epic: note — deps key #{k} is not in 'order' (already closed?)", file=sys.stderr)
PY

j() { python3 -c 'import json,sys;v=json.load(open(sys.argv[1])).get(sys.argv[2]);print("" if v is None else v)' "$MANIFEST" "$1"; }
EPIC="$(j epic)"
MODEL="$(j model)"
ORDER="$(python3 -c 'import json,sys;print(" ".join(str(x) for x in json.load(open(sys.argv[1]))["order"]))' "$MANIFEST")"

deps_of() { # print space-separated deps for an issue (empty if none)
  python3 -c 'import json,sys;print(" ".join(str(x) for x in json.load(open(sys.argv[1])).get("deps",{}).get(sys.argv[2],[])))' "$MANIFEST" "$1"
}
issue_state() { gh issue view "$1" --json state -q .state 2>/dev/null || echo UNKNOWN; }

LOGDIR="$ROOT/$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC"
mkdir -p "$LOGDIR"
EPIC_LOG="$LOGDIR/epic.log"
log() { echo "[epic #$EPIC] $*" | tee -a "$EPIC_LOG" >&2; }

# Post a comment on the EPIC issue so its own timeline records what the orchestrator did —
# especially the halts. Best-effort: never let a comment failure abort the run.
comment_epic() { gh issue comment "$EPIC" --body "$1" >/dev/null 2>&1 \
  || log "note: could not comment on epic #$EPIC (post it manually)"; }

# Fail fast on a bad gh auth/repo rather than halting on the first subtask.
gh auth status >/dev/null 2>&1 || pipeline_die "gh is not authenticated (run: gh auth login)"
[ "$(issue_state "$EPIC")" != "UNKNOWN" ] \
  || pipeline_die "cannot read epic issue #$EPIC via gh (wrong repo, or no such issue)"

# Tick the epic checklist box for a merged subtask. GitHub closes the referenced issue on
# merge (via `Closes #N`) but does NOT auto-check the `- [ ] #N` box in the umbrella body.
tick_checkbox() { # $1 = merged issue number
  local body new
  body="$(gh issue view "$EPIC" --json body -q .body 2>/dev/null)" \
    || { log "note: couldn't read epic #$EPIC body to tick #$1"; return 0; }
  new="$(EPIC_BODY="$body" TICK="$1" python3 - <<'PY'
import os, re, sys
body = os.environ["EPIC_BODY"]; issue = os.environ["TICK"]
pat = re.compile(r'(?m)^(\s*[-*] )\[ \]([ \t]+#%s\b)' % re.escape(issue))
sys.stdout.write(pat.sub(r'\1[x]\2', body))
PY
)"
  if [ "$new" = "$body" ]; then
    log "note: no unchecked '#$1' box in epic #$EPIC body (already ticked or absent)"
  elif printf '%s' "$new" | gh issue edit "$EPIC" --body-file - >/dev/null 2>&1; then
    log "checked epic #$EPIC checklist box for #$1"
  else
    log "note: failed to tick epic #$EPIC box for #$1 (tick it manually)"
  fi
}

log "start — order: [$ORDER]  model: ${MODEL:-<inherit>}  manifest: $MANIFEST"

for ISSUE in $ORDER; do
  STATE="$(issue_state "$ISSUE")"
  if [ "$STATE" = "CLOSED" ]; then
    log "#$ISSUE already CLOSED — skip (resumable)."
    continue
  fi
  if [ "$STATE" != "OPEN" ]; then
    log "HALT — #$ISSUE state=$STATE (expected OPEN). Investigate before continuing."
    comment_epic "**Epic orchestrator halted** at #$ISSUE — its state is \`$STATE\` (expected \`OPEN\`). Not starting dependents. Investigate #$ISSUE before re-running the epic."
    exit 1
  fi

  # Dependency guard — every listed dependency must already be merged (CLOSED).
  for DEP in $(deps_of "$ISSUE"); do
    DSTATE="$(issue_state "$DEP")"
    if [ "$DSTATE" != "CLOSED" ]; then
      log "HALT — #$ISSUE depends on #$DEP which is $DSTATE (not merged). Stopping."
      comment_epic "**Epic orchestrator halted** before #$ISSUE — it depends on #$DEP which is \`$DSTATE\` (not merged). Not starting dependents."
      exit 1
    fi
  done

  SID="$(pipeline_uuid)"        # portable: uuidgen / /proc / python (macOS has no /proc)
  SLOG="$LOGDIR/subtask-$ISSUE.log"
  PROMPT="$(sed -e "s/{{ISSUE}}/$ISSUE/g" -e "s/{{EPIC}}/$EPIC/g" "$PROMPT_TMPL")"
  log "spawn #$ISSUE — isolated session (sid=$SID) -> $SLOG"

  # Fresh session id guarantees state isolation regardless of inherited env.
  # $PIPELINE_AUTO_ENV=auto makes the pipeline auto-approve the plan and auto-merge on
  # reviewer APPROVE (both gates non-interactive). PIPELINE_SKILL_DIR + PIPELINE_CONFIG are
  # forwarded so the child session resolves the SAME bundle and config this driver used
  # (without them a global skill + per-repo config would not be found from a fresh session).
  # Arrays, not ${x:+...} strings, so paths containing spaces survive.
  ENVV=( "$PIPELINE_AUTO_ENV=auto" "PIPELINE_SKILL_DIR=$SKILL_DIR" )
  if [ -n "${PIPELINE_CONFIG_FILE:-}" ]; then ENVV+=( "PIPELINE_CONFIG=$PIPELINE_CONFIG_FILE" ); fi
  CLAUDE_ARGS=( -p "$PROMPT" --session-id "$SID" --dangerously-skip-permissions )
  if [ -n "$MODEL" ]; then CLAUDE_ARGS+=( --model "$MODEL" ); fi

  # `set +e` around the spawn only: a non-zero claude exit is DATA here (it feeds the halt
  # message), not a reason to abort before the SUBTASK_BLOCKED / issue-state checks below.
  set +e
  env -u CLAUDE_CODE_SESSION_ID "${ENVV[@]}" claude "${CLAUDE_ARGS[@]}" 2>&1 | tee "$SLOG"
  RC=${PIPESTATUS[0]}
  set -e

  if grep -qaE "^SUBTASK_BLOCKED: #$ISSUE" "$SLOG"; then
    REASON="$(grep -aE "^SUBTASK_BLOCKED: #$ISSUE" "$SLOG" | tail -1 | sed -E "s/^SUBTASK_BLOCKED: #$ISSUE[[:space:]]*(—|-)?[[:space:]]*//")"
    log "HALT — #$ISSUE reported SUBTASK_BLOCKED. See $SLOG. Not starting dependents."
    comment_epic "**Epic orchestrator halted** — subtask #$ISSUE reported \`SUBTASK_BLOCKED\`: ${REASON:-see the subtask log}. Not starting dependents. Log: \`$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC/subtask-$ISSUE.log\`."
    exit 1
  fi

  # Authoritative advance condition: GitHub says the issue is closed (PR merged).
  # Do not trust the session's exit code or self-report alone.
  STATE="$(issue_state "$ISSUE")"
  if [ "$STATE" != "CLOSED" ]; then
    log "HALT — #$ISSUE did not merge (claude rc=$RC, issue state=$STATE). See $SLOG."
    comment_epic "**Epic orchestrator halted** — subtask #$ISSUE did not merge (session rc=$RC, issue still \`$STATE\`). Not starting dependents. Log: \`$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC/subtask-$ISSUE.log\`."
    exit 1
  fi
  log "merged #$ISSUE (issue CLOSED)."
  tick_checkbox "$ISSUE"
  git -C "$ROOT" fetch -q origin "$PIPELINE_BASE_BRANCH" 2>/dev/null || true
done

log "DONE — all subtasks in the manifest are merged. Epic #$EPIC complete."
comment_epic "**Epic orchestrator complete** — every subtask in this run merged: $(for i in $ORDER; do printf '#%s ' "$i"; done). Checklist boxes ticked above."
