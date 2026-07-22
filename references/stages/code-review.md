# Stage: code-review (code-review gate — terminal stage)

You are running the **code-review gate**. The reviewer is headless; you orchestrate and make the
fixes. Optional argument: a PR-number override (`$ARGUMENTS`).

## 1. Resolve context
```bash
ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
for c in "${PIPELINE_SKILL_DIR:-}" "$HOME/.claude/skills/dev-pipeline" "$ROOT/.claude/skills/dev-pipeline"; do
  [ -n "$c" ] && [ -f "$c/references/scripts/pipeline-lib.sh" ] && { SKILL_DIR="$c"; break; }
done
source "$SKILL_DIR/references/scripts/pipeline-lib.sh" && pipeline_init
STATE="$SKILL_DIR/references/scripts/state.sh"
SDIR="$(bash "$STATE" dir)"
bash "$STATE" show
PR="${ARGUMENTS:-$(bash "$STATE" get prNumber)}"
WT="$(bash "$STATE" get worktree)"
BRANCH="$(bash "$STATE" get branch)"
PLAN="$(bash "$STATE" get planPath)"
# Smart fallback when state is empty (e.g. a fresh session): resolve the PR from the branch.
if [ -z "$PR" ]; then
  BR="${BRANCH:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)}"
  PR="$(gh pr list --head "$BR" --state open --json number -q '.[0].number' 2>/dev/null)"
fi
[ -z "$BRANCH" ] && [ -n "$PR" ] && BRANCH="$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null)"
[ -z "$WT" ] && [ -n "$BRANCH" ] && WT="$PIPELINE_WORKTREE_ROOT/$BRANCH"
[ -d "$WT" ] || { echo "worktree not found: $WT — run implement first, or pass the right branch"; }
```
If there is no PR, **STOP** (run implement first).

## 2. Run the reviewer
```bash
PROMPT="$SDIR/code-review.prompt.md"
sed -e "s|{{PR}}|$PR|g" -e "s|{{BRANCH}}|$BRANCH|g" -e "s|{{BASE}}|$PIPELINE_BASE_BRANCH|g" \
    -e "s|{{REPO_ROOT}}|$WT|g" -e "s|{{PLAN_PATH}}|$WT/$PLAN|g" \
    "$SKILL_DIR/references/prompts/code-review.md" > "$PROMPT"
if [ -n "${REVIEW_RULES_FILE:-}" ] && [ -f "$REVIEW_RULES_FILE" ]; then
  printf '\n\n---\n# PROJECT REVIEW RULES\n\n' >> "$PROMPT"; cat "$REVIEW_RULES_FILE" >> "$PROMPT"
fi
bash "$SKILL_DIR/references/scripts/run-reviewer.sh" "$WT" "$PROMPT" 2>&1 | tee "$SDIR/code-review.log"
```
The reviewer posts inline comments to the PR via `gh` and submits a review with state APPROVE or
REQUEST_CHANGES.

> **Headless caveat:** as in spec-review — if this session is headless, never end your turn while the
> reviewer runs. Background it and block with foreground waits until the log marker appears.

## 3. Read the verdict (deterministic stop signal)
**Trust the log marker, not the GitHub review state** — if the reviewer runs under the account that
OWNS the PR, GitHub rejects a formal APPROVE/REQUEST_CHANGES from the owner (HTTP 422) and it falls
back to a COMMENTED review, so `reviews[-1].state` is unreliable. The authoritative verdict is the
marker the prompt prints:
```bash
grep -aE "^PIPELINE_REVIEW_DONE event=(APPROVE|REQUEST_CHANGES)" "$SDIR/code-review.log" | tail -1
# APPROVE  → gate satisfied (proceed to the user merge gate)
# REQUEST_CHANGES → address the inline comments, then re-run
```
If the marker is absent, the run didn't finish (or hit a usage limit / `REVIEWER_TIMEOUT` — grep the
log); re-run rather than guessing from the GitHub state. (If your reviewer runs under its own bot
account, the GitHub review state is authoritative and this marker is just a convenience.)

## 4. Address comments
Fetch them: `gh api repos/{owner}/{repo}/pulls/$PR/comments` (resolve owner/repo via
`gh repo view --json owner,name`). For each comment, verify before agreeing, then either:
- **incorporate** — fix in the worktree, commit, and reply on the thread
  (`gh api .../comments/<id>/replies` with `Fixed in <sha>`), or
- **reject** — reply with a clear rationale.

Push fixes to the same branch and bump the round counter:
```bash
cd "$WT" && git push
bash "$STATE" set codeRounds=<n>
```

## 5. Iterate
Re-run step 2 on the updated diff until the marker (step 3) is `APPROVE`. Stop only when it approves,
or when you and the user have deliberately rejected the remaining comments with rationale.
**Hard cap: 5 rounds.** At the cap, stop and report (in autonomous mode print `SUBTASK_BLOCKED`)
rather than looping forever.

## 6. Merge gate (GATE 2)
**Autonomous mode:** if the autonomous-mode env var is set (an epic-orchestrated subtask — see
`run-epic.sh`), there is **no user to ask**; reviewer APPROVE (step 3) is the gate. Proceed straight
to the sync + merge + cleanup below without stopping.
```bash
[ "$(printenv "$PIPELINE_AUTO_ENV" 2>/dev/null)" = "auto" ] && AUTO=1 || AUTO=0
```
**Interactive mode (default):** summarize the outcome and **ask the user** before finishing.

Either way, **first sync with the base branch** so a stale branch doesn't surface a conflict only at
`gh pr merge`:
```bash
cd "$WT" && git fetch -q origin "$PIPELINE_BASE_BRANCH"
if ! git merge --no-edit "origin/$PIPELINE_BASE_BRANCH"; then
  echo "conflict with base — resolve in $WT, commit, re-run the reviewer (step 2), then merge" >&2
  # In auto mode a conflict you cannot cleanly resolve is a blocker: print
  # `SUBTASK_BLOCKED: #<issue> — base conflict` and stop.
fi
git push
```
On sign-off (interactive) **or** immediately (auto mode, after APPROVE):
```bash
gh pr ready "$PR"
gh pr merge "$PR" --squash
bash "$SKILL_DIR/references/scripts/cleanup-worktree.sh"
bash "$STATE" set phase=done
```
`cleanup-worktree.sh` must run from the MAIN checkout, not from inside `$WT` — it `cd`s to the repo
root itself, but a shell whose cwd is the removed worktree afterwards is confusing; `cd "$ROOT"` first.

(If the user merges via the GitHub UI later instead, run `cleanup-worktree.sh` once the PR is merged.)
