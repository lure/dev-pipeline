#!/usr/bin/env bash
# create-worktree.sh — deterministically create an isolated implementation worktree off
# the latest origin/<base>, with the configured symlinks and whatever per-worktree setup
# the project needs (deps install, client generation) via the pipeline_worktree_setup hook.
#
# Usage: create-worktree.sh <branch> [base-branch]
#   <branch>       e.g. feat/unified-thing
#   [base-branch]  defaults to $PIPELINE_BASE_BRANCH
#
# Prints helper hints to stderr and the absolute worktree path as the LAST stdout line
# (so a caller can capture it: WT="$(create-worktree.sh feat/foo | tail -1)").
#
# Lessons baked in (see the config for the project-specific hook):
#   * node_modules / generated clients are NOT shared — a worktree that shares the main
#     checkout's installed deps can repoint the main checkout's symlinks into the worktree,
#     so teardown dangles them and breaks main. The setup hook installs fresh, isolated.
#   * Never symlink a generated client — a shared, stale client silently breaks tests
#     (missing models/types added by later migrations). The setup hook generates fresh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"

BRANCH="${1:?usage: create-worktree.sh <branch> [base-branch]}"
pipeline_init

BASE="${2:-$PIPELINE_BASE_BRANCH}"
APP="$PIPELINE_APP_DIR"
WT="$PIPELINE_WORKTREE_ROOT/$BRANCH"
WTAPP="$WT${PIPELINE_APP_SUBDIR:+/$PIPELINE_APP_SUBDIR}"

# Reject branch names git would refuse (or that would escape the worktree root) up front,
# so we fail with a clear message instead of a half-created worktree.
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 \
  || pipeline_die "invalid branch name: $BRANCH"
case "$BRANCH" in *..*|/*) pipeline_die "refusing branch name: $BRANCH" ;; esac

[ -e "$WT" ] && pipeline_die "worktree path already exists: $WT"
[ -d "$APP" ] || pipeline_die "app dir not found: $APP (check PIPELINE_APP_SUBDIR)"
git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" \
  && pipeline_die "branch already exists: $BRANCH"

# Base the new branch on a CURRENT base (prefer origin/<base> so the worktree starts from
# the freshest pushed code; fall back to the local ref when offline or remote-less).
git -C "$ROOT" fetch -q origin "$BASE" 2>/dev/null || true
if git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/origin/$BASE" >/dev/null; then
  STARTPOINT="origin/$BASE"
elif git -C "$ROOT" rev-parse --verify --quiet "refs/heads/$BASE" >/dev/null; then
  STARTPOINT="$BASE"
else
  pipeline_die "base branch not found locally or on origin: $BASE (set PIPELINE_BASE_BRANCH)"
fi
mkdir -p "$(dirname "$WT")"
git -C "$ROOT" worktree add "$WT" -b "$BRANCH" "$STARTPOINT" >&2

# Symlink only the gitignored bits that are SAFE to share (from PIPELINE_WORKTREE_SYMLINKS).
for p in $PIPELINE_WORKTREE_SYMLINKS; do
  if [ ! -e "$APP/$p" ]; then
    echo "  skip $p (absent in main checkout)" >&2
  elif [ -e "$WTAPP/$p" ]; then
    echo "  skip $p (already present in worktree)" >&2
  else
    mkdir -p "$(dirname "$WTAPP/$p")"
    ln -s "$APP/$p" "$WTAPP/$p" && echo "  linked $p" >&2
  fi
done

# Project-defined per-worktree setup (deps install, client generation, …).
if pipeline_worktree_setup "$WTAPP"; then
  echo "  worktree setup hook ok" >&2
else
  echo "  WARN: pipeline_worktree_setup failed — run your install/generate in the worktree before testing" >&2
fi

echo "worktree ready at $WTAPP (branch $BRANCH off $STARTPOINT)" >&2

# LAST stdout line: the worktree path, for capture by the caller.
echo "$WT"
