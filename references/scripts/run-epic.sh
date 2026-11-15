#!/usr/bin/env bash
# run-epic.sh — deterministic epic orchestrator.
#
# Runs every not-yet-merged subtask of an epic through the FULL pipeline, one at a time in
# dependency order, FULLY AUTONOMOUSLY (auto-approve plan, auto-merge on reviewer APPROVE).
# Each subtask runs in a fresh instance of the initiating host (Codex or Claude), with
# a driver-assigned PIPELINE_SESSION_ID shared by all of that subtask's shell calls.
#
# The single fuzzy step (parsing the epic's checklist + rough dependency graph into a
# topological order) is done ONCE by the epic stage, which freezes the result into a
# manifest and hands it here. THIS script is fully deterministic: it reads the frozen order
# and, per subtask, spawns the session, waits, and advances only after tracker completion.
# YouTrack completion additionally requires a verified GitHub PR merge.
#
# Usage: run-epic.sh <manifest.json>
#   manifest shape:
#     { "epic": 44, "order": [48, 49, 50], "deps": { "49": [48] }, "host": "codex", "model": null }
#
# Resumable + idempotent: re-running skips any subtask whose issue is already CLOSED.
# Halts (never cascades) if a subtask fails to merge or reports SUBTASK_BLOCKED.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"

MANIFEST="${1:?usage: run-epic.sh <manifest.json>}"
[ -f "$MANIFEST" ] || pipeline_die "manifest not found: $MANIFEST"
pipeline_require python3 git

PROMPT_TMPL="$SKILL_DIR/references/prompts/subtask.md"
[ -f "$PROMPT_TMPL" ] || pipeline_die "prompt template missing: $PROMPT_TMPL"

# Validate the manifest up front — a typo here otherwise surfaces as a mystery halt.
MANIFEST_JSON="$MANIFEST" python3 - <<'PY' || exit 2
import json, os, re, sys
try:
    m = json.load(open(os.environ["MANIFEST_JSON"]))
except Exception as e:
    sys.exit(f"run-epic: manifest is not valid JSON: {e}")
if not isinstance(m, dict):
    sys.exit("run-epic: manifest must be a JSON object")
tracker = m.get("tracker", "github")
if tracker not in ("github", "youtrack"):
    sys.exit("run-epic: tracker must be github or youtrack")
def issue_number(x):
    pattern = r"[A-Z][A-Z0-9_]*-[1-9][0-9]*" if tracker == "youtrack" else r"[1-9][0-9]*"
    return isinstance(x, (str, int)) and not isinstance(x, bool) and re.fullmatch(pattern, str(x))
if not issue_number(m.get("epic")):
    sys.exit("run-epic: epic ID does not match the selected tracker (YouTrack needs tracker=youtrack)")
if tracker == "youtrack":
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", m.get("repository", "")):
        sys.exit("run-epic: YouTrack manifests require a GitHub repository owner/name")
    fields = m.get("youtrack", {}).get("doneFields")
    if not isinstance(fields, dict) or not fields or not all(isinstance(k, str) and isinstance(v, str) for k, v in fields.items()):
        sys.exit("run-epic: YouTrack manifests require youtrack.doneFields from the project schema")
if m.get("host") not in (None, "codex", "claude"):
    sys.exit("run-epic: 'host' must be codex or claude")
if m.get("model") is not None and not isinstance(m["model"], str):
    sys.exit("run-epic: 'model' must be a string or null (a model for the selected host)")
order = m.get("order")
if not isinstance(order, list) or not all(issue_number(x) for x in order):
    sys.exit("run-epic: manifest 'order' must be a list of tracker issue IDs")
if len(set(map(str, order))) != len(order):
    sys.exit("run-epic: manifest 'order' contains duplicates")
deps = m.get("deps") or {}
if not isinstance(deps, dict):
    sys.exit("run-epic: manifest 'deps' must be an object")
known = {str(x) for x in order}
for k, v in deps.items():
    if not issue_number(k) or not isinstance(v, list) or not all(issue_number(x) for x in v):
        sys.exit(f"run-epic: deps[{k}] must be a list of tracker issue IDs")
    if str(k) not in known:
        print(f"run-epic: note — deps key #{k} is not in 'order' (already closed?)", file=sys.stderr)
PY

j() { python3 -c 'import json,sys;v=json.load(open(sys.argv[1])).get(sys.argv[2]);print("" if v is None else v)' "$MANIFEST" "$1"; }
HOST="$(j host)"
if [ -n "$HOST" ]; then export PIPELINE_HOST="$HOST"; fi
pipeline_init
pipeline_require "$PIPELINE_HOST" gh
# Epic mode merges every subtask on its own, so it is only for someone allowed to merge here.
pipeline_may_merge || pipeline_die "epic mode merges every subtask, and only ${PIPELINE_MERGERS} may merge in this repo"
TRACKER="$(j tracker)"; TRACKER="${TRACKER:-github}"
EPIC="$(j epic)"
MODEL="$(j model)"
ORDER="$(python3 -c 'import json,sys;print(" ".join(str(x) for x in json.load(open(sys.argv[1]))["order"]))' "$MANIFEST")"

deps_of() { # print space-separated deps for an issue (empty if none)
  python3 -c 'import json,sys;print(" ".join(str(x) for x in (json.load(open(sys.argv[1])).get("deps") or {}).get(sys.argv[2],[])))' "$MANIFEST" "$1"
}
yt() {
  uv run --script "$SKILL_DIR/references/scripts/youtrack_mcp.py" "$@" \
    --host "$PIPELINE_HOST" --root "$ROOT" --manifest "$MANIFEST" --base "$PIPELINE_BASE_BRANCH"
}
issue_state() {
  if [ "$TRACKER" = youtrack ]; then yt state "$1" || echo UNKNOWN
  else gh issue view "$1" --json state -q .state 2>/dev/null || echo UNKNOWN; fi
}

LOGDIR="$ROOT/$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC"
mkdir -p "$LOGDIR"
EPIC_LOG="$LOGDIR/epic.log"
log() { echo "[epic #$EPIC] $*" | tee -a "$EPIC_LOG" >&2; }

# Post a comment on the EPIC issue so its own timeline records what the orchestrator did —
# especially the halts. Best-effort: never let a comment failure abort the run.
comment_epic() {
  if [ "$TRACKER" = youtrack ]; then
    local file rc=0
    file="$(mktemp "${TMPDIR:-/tmp}/pipeline-comment.XXXXXX")" || return 0
    printf '%s' "$1" > "$file"
    yt comment "$EPIC" --file "$file" >/dev/null 2>&1 || rc=$?
    rm -f "$file"
    [ "$rc" = 0 ] || log "note: could not comment on epic #$EPIC"
  else
    gh issue comment "$EPIC" --body "$1" >/dev/null 2>&1 \
      || log "note: could not comment on epic #$EPIC (post it manually)"
  fi
}
halt() {
  log "HALT — $*"
  comment_epic "**Epic orchestrator halted** — $*"
  exit 1
}

if [ "$TRACKER" = youtrack ]; then
  pipeline_require uv
  REPOSITORY="$(j repository)"
  ACTUAL_REPOSITORY="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  [ "$ACTUAL_REPOSITORY" = "$REPOSITORY" ] || pipeline_die "manifest repository does not match the current checkout"
  yt preflight "$EPIC" >/dev/null || pipeline_die "YouTrack MCP preflight failed"
fi

# Fail fast on a bad gh auth/repo rather than halting on the first subtask.
gh auth status >/dev/null 2>&1 || pipeline_die "gh is not authenticated (run: gh auth login)"
[ "$(issue_state "$EPIC")" != "UNKNOWN" ] \
  || pipeline_die "cannot read epic issue #$EPIC via $TRACKER (wrong connection, or no such issue)"

# Tick the epic checklist box for a merged subtask. GitHub closes the referenced issue on
# merge (via `Closes #N`) but does NOT auto-check the `- [ ] #N` box in the umbrella body.
tick_checkbox() { # $1 = merged issue number
  [ "$TRACKER" = youtrack ] && return 0  # linked children are authoritative in YouTrack
  local body new
  body="$(gh issue view "$EPIC" --json body -q .body 2>/dev/null)" \
    || { log "note: couldn't read epic #$EPIC body to tick #$1"; return 0; }
  new="$(EPIC_BODY="$body" TICK="$1" python3 - <<'PY'
import os, re, sys
body = os.environ["EPIC_BODY"]; issue = os.environ["TICK"]
# `[*_~`]*` because a checklist routinely bolds the ref (`- [ ] **#42** — …`); without it the
# sub matches nothing, every box stays unchecked, and the run still reports success.
pat = re.compile(r'(?m)^(\s*[-*] )\[ \]([ \t]+[*_~`]*#%s\b)' % re.escape(issue))
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

log "start — tracker: $TRACKER  host: $PIPELINE_HOST  order: [$ORDER]  model: ${MODEL:-<cli default>}  manifest: $MANIFEST"

for ISSUE in $ORDER; do
  STATE="$(issue_state "$ISSUE")"
  RECEIPT="$LOGDIR/subtask-$ISSUE.merged.json"
  if [ "$TRACKER" = youtrack ] && [ "$STATE" = OPEN ] && [ -f "$RECEIPT" ]; then
    log "retry tracker completion for #$ISSUE from its merged PR receipt"
    yt complete "$ISSUE" --state "$RECEIPT" --receipt "$RECEIPT" \
      || halt "could not complete #$ISSUE in YouTrack; not starting dependents"
    STATE="$(issue_state "$ISSUE")"
  fi
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
  PROMPT_FILE="$LOGDIR/subtask-$ISSUE.prompt.md"
  sed -e "s/{{ISSUE}}/$ISSUE/g" -e "s/{{EPIC}}/$EPIC/g" \
    -e "s/{{HOST}}/$PIPELINE_HOST/g" -e "s/{{TRACKER}}/$TRACKER/g" "$PROMPT_TMPL" > "$PROMPT_FILE"
  log "spawn #$ISSUE — isolated session (sid=$SID) -> $SLOG"

  # Fresh session id guarantees state isolation regardless of inherited env.
  # $PIPELINE_AUTO_ENV=auto makes the pipeline auto-approve the plan and auto-merge on
  # reviewer APPROVE (both gates non-interactive). PIPELINE_SKILL_DIR + PIPELINE_CONFIG are
  # forwarded so the child session resolves the SAME bundle and config this driver used
  # (without them a global skill + per-repo config would not be found from a fresh session).
  # Arrays, not ${x:+...} strings, so paths containing spaces survive.
  ENVV=( "$PIPELINE_AUTO_ENV=auto" "PIPELINE_SKILL_DIR=$SKILL_DIR"
    "PIPELINE_HOST=$PIPELINE_HOST" "PIPELINE_SESSION_ID=$SID" "PIPELINE_TRACKER=$TRACKER" "PIPELINE_REVIEWER=$PIPELINE_REVIEWER" )
  if [ -n "${PIPELINE_CONFIG_FILE:-}" ]; then ENVV+=( "PIPELINE_CONFIG=$PIPELINE_CONFIG_FILE" ); fi
  case "$PIPELINE_HOST" in
    claude)
      SESSION_ARGS=( claude -p --session-id "$SID" --dangerously-skip-permissions )
      if [ -n "$MODEL" ]; then SESSION_ARGS+=( --model "$MODEL" ); fi
      ;;
    codex)
      SESSION_ARGS=( codex exec -c 'approval_policy="never"' -s danger-full-access )
      if [ -n "$MODEL" ]; then SESSION_ARGS+=( --model "$MODEL" ); fi
      SESSION_ARGS+=( - )
      ;;
  esac

  # `set +e` around the spawn only: a non-zero CLI exit is DATA here (it feeds the halt
  # message), not a reason to abort before the SUBTASK_BLOCKED / issue-state checks below.
  set +e
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE -u CODEX_THREAD_ID -u CODEX_CI \
    "${ENVV[@]}" "${SESSION_ARGS[@]}" < "$PROMPT_FILE" 2>&1 | tee "$SLOG"
  RC=${PIPESTATUS[0]}
  set -e

  if grep -qaE "^SUBTASK_BLOCKED: #$ISSUE" "$SLOG"; then
    REASON="$(grep -aE "^SUBTASK_BLOCKED: #$ISSUE" "$SLOG" | tail -1 | sed -E "s/^SUBTASK_BLOCKED: #$ISSUE[[:space:]]*(—|-)?[[:space:]]*//")"
    log "HALT — #$ISSUE reported SUBTASK_BLOCKED. See $SLOG. Not starting dependents."
    comment_epic "**Epic orchestrator halted** — subtask #$ISSUE reported \`SUBTASK_BLOCKED\`: ${REASON:-see the subtask log}. Not starting dependents. Log: \`$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC/subtask-$ISSUE.log\`."
    exit 1
  fi

  if [ "$TRACKER" = youtrack ]; then
    if [ "$RC" -ne 0 ]; then
      halt "#$ISSUE implementer exited with rc=$RC; see $SLOG"
    fi
    yt complete "$ISSUE" --state "$ROOT/$PIPELINE_RUNTIME_DIR/sessions/$SID/state.json" --receipt "$RECEIPT" \
      || halt "#$ISSUE merge verification or YouTrack completion failed; not starting dependents"
  fi

  # Authoritative advance condition: tracker confirms completion after the merge.
  # Do not trust the session's exit code or self-report alone.
  STATE="$(issue_state "$ISSUE")"
  if [ "$STATE" != "CLOSED" ]; then
    log "HALT — #$ISSUE did not merge ($PIPELINE_HOST rc=$RC, issue state=$STATE). See $SLOG."
    comment_epic "**Epic orchestrator halted** — subtask #$ISSUE did not merge (session rc=$RC, issue still \`$STATE\`). Not starting dependents. Log: \`$PIPELINE_RUNTIME_DIR/epics/epic-$EPIC/subtask-$ISSUE.log\`."
    exit 1
  fi
  log "merged #$ISSUE (issue CLOSED)."
  tick_checkbox "$ISSUE"
  git -C "$ROOT" fetch -q origin "$PIPELINE_BASE_BRANCH" 2>/dev/null || true
done


# An epic with nothing left open is finished, so close it. The manifest is NOT the condition:
# it holds only the subtasks that were open at launch, and someone may have added a box since.
# Re-read the body and require EVERY checklist issue to be CLOSED, so a subtask added mid-run
# leaves the epic open instead of being silently buried under a closed umbrella.
close_epic_if_done() {
  if [ "$TRACKER" = youtrack ]; then
    yt finish-epic "$EPIC" || halt "could not verify/complete YouTrack epic"
    return 0
  fi
  local body remaining=""
  body="$(gh issue view "$EPIC" --json body -q .body 2>/dev/null)" \
    || { log "note: couldn't read epic #$EPIC body to decide on closing"; return 0; }
  for i in $(EPIC_BODY="$body" python3 - <<'PY'
import os, re
for m in re.finditer(r'(?m)^\s*[-*] \[[ xX]\][ \t]+.*?#(\d+)', os.environ["EPIC_BODY"]):
    print(m.group(1))
PY
  ); do
    [ "$(issue_state "$i")" = "CLOSED" ] || remaining="$remaining #$i"
  done
  if [ -n "$remaining" ]; then
    log "epic #$EPIC left OPEN — still open on the checklist:$remaining"
    return 0
  fi
  if gh issue close "$EPIC" --reason completed >/dev/null 2>&1; then
    log "closed epic #$EPIC (every checklist subtask is CLOSED)"
  else
    log "note: could not close epic #$EPIC (close it manually)"
  fi
}
close_epic_if_done

log "DONE — all subtasks in the manifest are complete."
comment_epic "**Epic orchestrator complete** — every subtask in this run completed: $ORDER."
