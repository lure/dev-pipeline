#!/usr/bin/env bash
# cleanup-worktree.sh — after the PR is merged: run the project teardown hook, remove the
# implementation worktree, delete its now-merged local branch, and bring the main checkout's
# base branch current with origin.
#
# Usage: cleanup-worktree.sh [branch] [worktree-path]
#   Both default to the values recorded in state by the implement stage.
#
# Safe by design: it only ever removes a path git itself reports as a registered worktree of
# THIS repo (never the main checkout), the branch delete is best-effort, and the base branch
# is brought forward with --ff-only (never a merge commit, never loses work).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"
pipeline_init
cd "$ROOT"   # never run from inside the worktree we're about to remove

STATE="$SKILL_DIR/references/scripts/state.sh"
BRANCH="${1:-}"
WT="${2:-}"
# Fall back to state ONLY when no branch was passed explicitly (otherwise an explicit branch
# must win, and its worktree path is derived from it, not from state). With no session id at all,
# state.sh fails and both values stay empty.
if [ -z "$BRANCH" ] && [ -f "$STATE" ]; then
  BRANCH="$(bash "$STATE" get branch 2>/dev/null || true)"
  [ -z "$WT" ] && WT="$(bash "$STATE" get worktree 2>/dev/null || true)"
fi
[ -z "$WT" ] && [ -n "$BRANCH" ] && WT="$PIPELINE_WORKTREE_ROOT/$BRANCH"
[ -n "$WT" ] && WT="$(pipeline_abspath "$WT")"

# Is $WT actually a linked worktree of this repo? Anything else we refuse to touch — this is
# the guard that keeps a bad/empty path from turning `worktree remove --force` into damage.
is_linked_worktree() {
  [ -n "${1:-}" ] || return 1
  [ "$1" != "$ROOT" ] || return 1
  git -C "$ROOT" worktree list --porcelain \
    | awk -v want="$1" '/^worktree /{ if (substr($0,10) == want) found=1 } END{ exit !found }'
}

if [ -n "$WT" ] && ! is_linked_worktree "$WT"; then
  echo "cleanup: '$WT' is not a registered worktree of $ROOT — skipping removal" >&2
  WT=""
fi

# 0. Project teardown hook (repair anything a per-worktree install repointed in main, etc.).
if [ -n "$WT" ] && [ -d "$WT" ]; then
  pipeline_worktree_teardown "$WT${PIPELINE_APP_SUBDIR:+/$PIPELINE_APP_SUBDIR}" \
    || echo "cleanup: teardown hook failed (continuing)" >&2
fi

# 1. Remove the worktree (--force handles untracked generated clients + symlinks).
if [ -n "$WT" ]; then
  if git -C "$ROOT" worktree remove --force "$WT"; then
    echo "removed worktree: $WT"
  else
    echo "cleanup: could not remove worktree: $WT" >&2
  fi
else
  echo "no worktree path resolved — skipping worktree removal"
fi
git -C "$ROOT" worktree prune

# 2. Delete the merged local branch (best-effort).
if [ -n "$BRANCH" ] && git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  if git -C "$ROOT" branch -D "$BRANCH"; then echo "deleted local branch: $BRANCH"; fi
fi

# 3. Bring the main checkout's base branch current with origin.
cur="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [ "$cur" != "$PIPELINE_BASE_BRANCH" ]; then
  git -C "$ROOT" checkout "$PIPELINE_BASE_BRANCH" || {
    echo "cleanup: could not switch to $PIPELINE_BASE_BRANCH (uncommitted changes on $cur?) — resolve, then 'git checkout $PIPELINE_BASE_BRANCH && git pull --ff-only'" >&2
    exit 1
  }
fi
if ! git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  echo "no 'origin' remote — leaving $PIPELINE_BASE_BRANCH as-is"
  exit 0
fi
git -C "$ROOT" fetch -q origin "$PIPELINE_BASE_BRANCH" || true
if git -C "$ROOT" pull --ff-only origin "$PIPELINE_BASE_BRANCH"; then
  echo "$PIPELINE_BASE_BRANCH is now: $(git -C "$ROOT" log --oneline -1)"
else
  echo "cleanup: 'git pull --ff-only origin $PIPELINE_BASE_BRANCH' failed (local diverged?) — resolve manually" >&2
  exit 1
fi
