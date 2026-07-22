# Stage: implement

You are running the **implement** step. **You (Claude Code) implement — the reviewer is not involved
here.** Optional argument: a plan-path override (`$ARGUMENTS`).

## 1. Guard
```bash
ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
for c in "${PIPELINE_SKILL_DIR:-}" "$HOME/.claude/skills/dev-pipeline" "$ROOT/.claude/skills/dev-pipeline"; do
  [ -n "$c" ] && [ -f "$c/references/scripts/pipeline-lib.sh" ] && { SKILL_DIR="$c"; break; }
done
source "$SKILL_DIR/references/scripts/pipeline-lib.sh" && pipeline_init
STATE="$SKILL_DIR/references/scripts/state.sh"
bash "$STATE" show
APPROVED="$(bash "$STATE" get planApproved)"
PLAN="${ARGUMENTS:-$(bash "$STATE" get planPath)}"
```
If `planApproved` is not `true`, **STOP**: tell the user to run spec-review first. Do not implement an
unapproved plan.

## 2. Resolve the worktree (already created before planning)
In the default loop the worktree was created **before** planning, so it already exists — just resolve
it from state; do NOT create another:
```bash
WT="$(bash "$STATE" get worktree)"
BRANCH="$(bash "$STATE" get branch)"
bash "$STATE" set phase=implementing
```
**Fallback only** (manual run, or a plan authored in the main checkout with no worktree yet): create
one now. Derive a branch slug from the plan path — strip a leading `YYYY-MM-DD-`, drop the extension,
prefix `feat/`; for a multi-file plan **folder**, use the folder name (minus the date).
`create-worktree.sh` does the whole setup deterministically (branch off the latest base, configured
symlinks, and the project setup hook — deps + fresh generated client). Its last stdout line is the path:
```bash
if [ -z "$WT" ]; then
  BRANCH="feat/<slug>"
  WT="$(bash "$SKILL_DIR/references/scripts/create-worktree.sh" "$BRANCH" | tail -1)"
  bash "$STATE" set branch="$BRANCH" worktree="$WT"
fi
```
Do all implementation work inside the worktree's app dir (`$WT` + `$PIPELINE_APP_SUBDIR` if set).

## 3. Implement
Follow the approved plan. Use the `test-driven-development` and `executing-plans` skills if available.
Run the project's tooling with its direct binaries from the worktree (not a package-manager `exec`
wrapper if that would trigger a reinstall in your stack). Do not proceed while tests fail
(`verification-before-completion`).

## 4. Commit, push, open a draft PR
```bash
cd "$WT"
git add -A && git commit -m "<concise message>"
git push -u origin "$BRANCH"
gh pr create --draft --base "$PIPELINE_BASE_BRANCH" --fill
PR="$(gh pr view --json number -q .number)"
bash "$STATE" set prNumber="$PR" phase=code-review
```
If this run came from the epic orchestrator, the PR body **must** contain `Closes #<issue>` so the
squash-merge closes the subtask issue — that is the orchestrator's only advance signal. `--fill` uses
the commit messages, so put it there (or pass `--body`).

**Immediately run the code-review stage** (`references/stages/code-review.md`, or the `/…:code-review`
shim) on the new PR — do not wait for the user. (Code review is the terminal stage; it stops for the
user only at the merge gate.)
