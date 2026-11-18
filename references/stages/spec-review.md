# Stage: spec-review (plan-review gate)

You are running the **plan-review gate**. The reviewer is headless (see `reviewer_invoke` in the
config); you orchestrate. Optional argument: a plan path (`$ARGUMENTS`).

## 1. Resolve context
Use this preamble verbatim — it is identical in every stage and works whether the skill is installed
for Codex, Claude Code, or vendored into the repo:
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
STATE="$SKILL_DIR/references/scripts/state.sh"
SDIR="$(bash "$STATE" dir)"
bash "$STATE" show
WT="$(bash "$STATE" get worktree)"   # the worktree created before planning
BASE="${WT:-$ROOT}"                  # plan lives in the worktree; fall back to main
```
Determine the plan path — **strictly scoped to THIS session. Never review another session's plan.**
```bash
PLAN="${ARGUMENTS:-$(bash "$STATE" get planPath)}"
```
`$PLAN` is relative to the checkout that CONTAINS it (the worktree in the default loop), so resolve
it as `$BASE/$PLAN`.
- If `$ARGUMENTS` is non-empty, use it.
- Else use `planPath` from **this session's** state (Claude Code can record it via `record-plan.sh`;
  both hosts run an explicit
  `state.sh set planPath=...` right after writing).
- **If `$PLAN` is empty (this session recorded no plan): STOP. Do NOT fall back to a global "latest"
  plan — it may belong to a different session.** List recent plans matching `$PIPELINE_PLAN_GLOB`
  with their mtime and any `sessionId` recorded in `$PIPELINE_RUNTIME_DIR/sessions/*/state.json`,
  then ask which to review (or have the user re-run with an explicit path). Do not guess.
- Verify the file exists (`[ -f "$BASE/$PLAN" ]`) before spending a reviewer run on it.

If the resolved plan is a **multi-file folder** (`…/<plan>/00-overview.md` with siblings), pass the
overview as `{{PLAN_PATH}}` AND append an instruction to the reviewer prompt telling it to read every
sibling `*.md` in that folder before judging.

## 2. Run the reviewer
```bash
PLAN="<resolved plan path>"     # relative to $BASE, from step 1
OUT="$SDIR/plan-review.json"
rm -f "$OUT"
PROMPT="$SDIR/plan-review.prompt.md"
sed -e "s|{{PLAN_PATH}}|$BASE/$PLAN|g" -e "s|{{OUTPUT_PATH}}|$OUT|g" -e "s|{{REPO_ROOT}}|$BASE|g" \
    "$SKILL_DIR/references/prompts/plan-review.md" > "$PROMPT"
# Append project-specific review rules, if configured.
if [ -n "${REVIEW_RULES_FILE:-}" ] && [ -f "$REVIEW_RULES_FILE" ]; then
  printf '\n\n---\n# PROJECT REVIEW RULES\n\n' >> "$PROMPT"; cat "$REVIEW_RULES_FILE" >> "$PROMPT"
fi
# The reviewer's transcript runs to hundreds of KB per round, so it goes to the log only.
# Printing it would fill this session's context with text nobody needs to read.
bash "$SKILL_DIR/references/scripts/run-reviewer.sh" "$BASE" "$PROMPT" > "$SDIR/plan-review.log" 2>&1
echo "reviewer rc=$?"
bash "$STATE" set phase=plan-review
```
(`$BASE` is the worktree when one exists — that is where the plan and code live — else the main root.)

> **Headless caveat:** if THIS session is itself headless (an epic-orchestrated subtask), do NOT end
> your turn while the reviewer runs — nothing will re-invoke you. Launch it in the background and
> block with repeated **foreground** `until [ -f "$OUT" ]` waits until the verdict file exists. See
> `references/prompts/subtask.md`.

## 3. Parse the verdict
Read `$OUT`. If it is missing or not valid JSON, **STOP** and show
`tail -n 50 "$SDIR/plan-review.log"` (never the whole log): the gate failed; do not silently
proceed. Common causes worth checking in the log before re-running: the reviewer CLI is
unauthenticated, hit a usage limit, or was killed by `REVIEWER_TIMEOUT`.

## 4. Present findings (your judgment, not blind agreement)
Verify each finding against the real code/plan before agreeing (apply the `receiving-code-review`
skill if available). Present a compact table — id · severity · confidence · issue · your
recommendation (accept / reject + why).

## 5. Iterate
- Incorporate the findings you accept by editing the plan file directly.
- `bash "$STATE" set planRounds=<n>`
- Re-run step 2. Loop until the reviewer returns `"verdict":"approve"`.
- If it keeps flagging something you deliberately reject, record the rationale and move on — do not
  loop forever. **Hard cap: `$PIPELINE_MAX_ROUNDS` rounds.** At the cap, stop and report (in
  autonomous mode, print `SUBTASK_BLOCKED`) rather than burning reviewer runs indefinitely.

## 6. Report — then keep going (NO user stop)
The user already approved this plan at GATE 1 *before* this stage started, so there is **no user stop
here**. When the verdict is `approve`, post a short FYI summary — rounds taken, what changed, findings
you rejected with rationale — and then **continue straight into implementation**. Stop only if a
finding left you genuinely torn.

## 7. Record approval and auto-continue to implement
- Append a footer to the plan file (`$BASE/$PLAN`): `Status: APPROVED (<N> rounds, <YYYY-MM-DD>)`.
- `bash "$STATE" set planApproved=true phase=approved planPath="$PLAN"`
- **Immediately run the implement stage** (`references/stages/implement.md`, or the `/…:implement`
  shim) to build in the same worktree — do not wait for the user.
