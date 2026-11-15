# Stage: implement

You are running the **implement** step. **You (the initiating Codex or Claude session) implement — the reviewer is not involved
here.** Optional argument: a plan-path override (`$ARGUMENTS`).

## 1. Guard
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
prefix it with `$PIPELINE_BRANCH_PREFIX`; for a multi-file plan **folder**, use the folder name
(minus the date).
`create-worktree.sh` does the whole setup deterministically (branch off the latest base, configured
symlinks, and the project setup hook — deps + fresh generated client). Its last stdout line is the path:
```bash
if [ -z "$WT" ]; then
  BRANCH="${PIPELINE_BRANCH_PREFIX}<slug>"
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

**Comments say why, briefly.** One or two lines: why this way, and what breaks otherwise. Never
restate what the code does, re-tell the ticket, or narrate how the fix came about. Anything needing a
paragraph goes in the area docs, with the comment pointing at it.

    // Wordy: re-tells the ticket
    // The job is scheduled a grace period after the notification is created, so the recipient has a
    // real chance to see it in the app first. Anything other than UNREAD by now means they already
    // dealt with it -- opened it, marked all read, or acted on the invite it carried -- and the
    // email would be noise. This replaces the old "is the recipient online?" check at creation time,
    // which suppressed mail for anyone with a tab open anywhere.

    // Brief: the essence
    // The job runs a grace period (`mail.delay`) after creation, so anything but UNREAD
    // means the recipient already dealt with it in the app and the mail would be noise.

## 4. Commit, push, open a draft PR
```bash
cd "$WT"
git add -A && git commit -m "<concise message>"
git push -u origin "$BRANCH"
gh pr create --draft --base "$PIPELINE_BASE_BRANCH" --fill
PR="$(gh pr view --json number -q .number)"
bash "$STATE" set prNumber="$PR" phase=code-review
```
For an epic subtask, GitHub PR bodies must contain `Closes #<issue>`. For a YouTrack subtask
(`PIPELINE_TRACKER=youtrack`), include its full ID and YouTrack URL in the PR body; never strip the
project prefix. Record `prNumber` and `branch` in state. The driver verifies this PR's repository,
branch, base, issue reference, and merged status before completing YouTrack through MCP.

**Immediately run the code-review stage** (`references/stages/code-review.md`, or the `/…:code-review`
shim) on the new PR — do not wait for the user. (Code review is the terminal stage; it stops for the
user only at the merge gate.)
