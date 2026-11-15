#!/usr/bin/env bash
# run-reviewer.sh — single pinned entry point for a headless review.
#
# Usage: run-reviewer.sh <workdir> <prompt-file>
#   <workdir>     directory the reviewer runs in (repo root for plan review; the worktree for code review)
#   <prompt-file> file whose contents become the reviewer's prompt (piped on stdin)
#
# The actual reviewer command lives in the config as reviewer_invoke(), so a project can
# point this at codex, another model, or Claude headless without touching any driver. This
# wrapper just pins the run: fixed workdir + a bounded timeout.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"

WORKDIR="${1:?usage: run-reviewer.sh <workdir> <prompt-file>}"
PROMPT_FILE="${2:?usage: run-reviewer.sh <workdir> <prompt-file>}"
pipeline_init

[ -d "$WORKDIR" ]     || pipeline_die "workdir not found: $WORKDIR"
[ -f "$PROMPT_FILE" ] || pipeline_die "prompt file not found: $PROMPT_FILE"
[ -s "$PROMPT_FILE" ] || pipeline_die "prompt file is empty: $PROMPT_FILE"

cd "$WORKDIR"

# Export the reviewer hook + its knobs so the timeout wrapper's subshell can see them.
export -f reviewer_invoke
export ROOT PIPELINE_REVIEWER_CLI REVIEWER_MODEL REVIEWER_EFFORT REVIEWER_SANDBOX
export CODEX_REVIEWER_MODEL CLAUDE_REVIEWER_MODEL CLAUDE_REVIEWER_PERMISSION_MODE

# Bound each headless run (default from config; 0 disables). High-effort reviews of a large
# diff can read widely before posting — give them room. Always launch this script via a
# background/detached wrapper in the caller so the harness's own foreground cap doesn't kill
# the run before this limit. Exit 124 means the cap fired (the whole reviewer tree is dead).
pipeline_run_timeout "${REVIEWER_TIMEOUT:-0}" \
  env -u PIPELINE_SESSION_ID -u CODEX_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE \
    -u CODEX_CI PIPELINE_HOST="$PIPELINE_REVIEWER_CLI" \
    bash -c 'reviewer_invoke "$1"' pipeline-reviewer "$PROMPT_FILE"
exit $?
