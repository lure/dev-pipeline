#!/usr/bin/env bash
# pipeline-lib.sh — sourced (never executed) by every dev-pipeline script.
#
# It establishes the three things every script needs, identically:
#   SKILL_DIR — the installed skill bundle (derived from this file's own location, so it
#               works whether the skill is global (~/.claude/skills/dev-pipeline) or
#               vendored into a repo (.claude/skills/dev-pipeline)).
#   ROOT      — the MAIN repo root, worktree-aware. Resolution FAILS LOUDLY outside a git
#               repo instead of silently yielding "/" (which made cleanup run against /).
#   config    — bundled pipeline.config.defaults.sh, then the repo's own
#               $ROOT/.claude/pipeline.config.sh overlaid on top ($PIPELINE_CONFIG wins).
#
# Usage:  source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"
#
# Deliberately does NOT `set -e`: the stage files source this into an ad-hoc shell where a
# non-zero grep must not kill the session. Executable scripts set their own strict mode.

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pipeline_die() { echo "dev-pipeline: $*" >&2; exit 2; }

# ── Path helpers ─────────────────────────────────────────────────────────────
# Normalize a path whose LEAF need not exist yet (so "$ROOT/../foo-wt" becomes a real
# absolute path — git worktree bookkeeping and state comparisons both want the clean form).
pipeline_abspath() {
  local p="$1" d b
  case "$p" in "") printf '\n'; return 0 ;; esac
  d="$(dirname "$p")"; b="$(basename "$p")"
  if [ -d "$d" ]; then printf '%s/%s\n' "$(cd "$d" && pwd)" "$b"; else printf '%s\n' "$p"; fi
}

# Resolve the MAIN repo root even from a linked worktree or a subdirectory.
# `git rev-parse --git-common-dir` returns ".git" at top level, "../../.git" from a subdir,
# and an absolute /main/.git from a linked worktree — `cd`-ing to "<that>/.." handles all
# three. Returns non-zero (instead of "/") when there is no repo.
pipeline_resolve_root() {
  local gcd
  gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$gcd" ] || return 1
  ( cd "$gcd/.." 2>/dev/null && pwd ) || return 1
}

# ── Config ───────────────────────────────────────────────────────────────────
# Loads bundled defaults, then the per-repo overlay. Both may reference $ROOT/$SKILL_DIR.
pipeline_load_config() {
  local defaults="$SKILL_DIR/pipeline.config.defaults.sh" repo_cfg
  [ -f "$defaults" ] || pipeline_die "bundled defaults missing: $defaults (broken install)"
  # shellcheck source=/dev/null
  source "$defaults"

  repo_cfg="${PIPELINE_CONFIG:-$ROOT/.claude/pipeline.config.sh}"
  if [ -f "$repo_cfg" ]; then
    # shellcheck source=/dev/null
    source "$repo_cfg"
    PIPELINE_CONFIG_FILE="$repo_cfg"
  elif [ -n "${PIPELINE_CONFIG:-}" ]; then
    pipeline_die "PIPELINE_CONFIG points at a file that does not exist: $PIPELINE_CONFIG"
  else
    PIPELINE_CONFIG_FILE=""   # running on defaults alone — legal, just unconfigured
  fi

  # Derived / normalized values. Done here so every script agrees on them.
  : "${PIPELINE_WORKTREE_ROOT:=$ROOT/../$(basename "$ROOT")-wt}"
  PIPELINE_WORKTREE_ROOT="$(pipeline_abspath "$PIPELINE_WORKTREE_ROOT")"
  PIPELINE_APP_DIR="$ROOT${PIPELINE_APP_SUBDIR:+/$PIPELINE_APP_SUBDIR}"
  export PIPELINE_CONFIG_FILE
  export PIPELINE_YOUTRACK_MCP_SERVER PIPELINE_YOUTRACK_MCP_CONFIG PIPELINE_YOUTRACK_TIMEOUT
}

# Resolve the host before loading config so overrides can branch on it. A driver may
# set it explicitly; native session IDs identify interactive hosts without a wrapper.
pipeline_resolve_host() {
  if [ -z "${PIPELINE_HOST:-}" ]; then
    if [ -n "${CODEX_THREAD_ID:-}" ]; then PIPELINE_HOST=codex
    elif [ -n "${CLAUDE_CODE_SESSION_ID:-}${CLAUDECODE:-}" ]; then PIPELINE_HOST=claude
    else PIPELINE_HOST=claude; fi   # legacy standalone scripts
  fi
  case "$PIPELINE_HOST" in codex|claude) ;; *) pipeline_die "PIPELINE_HOST must be codex or claude" ;; esac
  export PIPELINE_HOST
}

# Driver-assigned IDs take precedence over the host's native ID. Never generate one
# here: successive shell calls must keep using the same state directory.
pipeline_session_id() {
  local sid="${PIPELINE_SESSION_ID:-}"
  if [ -z "$sid" ]; then
    case "$PIPELINE_HOST" in
      codex) sid="${CODEX_THREAD_ID:-}" ;;
      claude) sid="${CLAUDE_CODE_SESSION_ID:-}" ;;
    esac
  fi
  [ -n "$sid" ] || pipeline_die "no session ID: export PIPELINE_SESSION_ID once and reuse it in every shell call (or use the host's native session ID)"
  case "$sid" in *[/\\]*|.|..) pipeline_die "refusing unsafe pipeline session ID: $sid" ;; esac
  printf '%s\n' "$sid"
}

# Standard preamble: resolve ROOT, host, then config. Every script calls this.
pipeline_init() {
  ROOT="$(pipeline_resolve_root)" \
    || pipeline_die "not inside a git repository (cwd: $PWD) — run this from your project"
  pipeline_resolve_host
  pipeline_load_config
  case "$PIPELINE_REVIEWER" in
    auto) if [ "$PIPELINE_HOST" = codex ]; then PIPELINE_REVIEWER_CLI=claude; else PIPELINE_REVIEWER_CLI=codex; fi ;;
    codex|claude) PIPELINE_REVIEWER_CLI="$PIPELINE_REVIEWER" ;;
    *) pipeline_die "PIPELINE_REVIEWER must be auto, codex or claude" ;;
  esac
  export PIPELINE_REVIEWER PIPELINE_REVIEWER_CLI
}

# ── Merge authority ──────────────────────────────────────────────────────────
# Succeeds when the current GitHub user may merge: PIPELINE_MERGERS is empty, or it lists the
# login `gh` is authenticated as. A failed `gh` lookup counts as "may not", so an unauthenticated
# or misconfigured session never merges by accident.
pipeline_may_merge() {
  [ -z "${PIPELINE_MERGERS// /}" ] && return 0
  local me
  me="$(gh api user --jq .login 2>/dev/null)" || return 1
  [ -n "$me" ] || return 1
  case " $PIPELINE_MERGERS " in *" $me "*) return 0 ;; esac
  return 1
}

# ── Portable timeout ─────────────────────────────────────────────────────────
# Runs <cmd> with a wall-clock cap and returns its exit status (124 on timeout).
#
# Implemented as a bash watchdog rather than GNU `timeout` (absent on stock macOS) or a
# perl `alarm`. Both of those signal only the DIRECT child: the reviewer CLI is a grandchild
# (reviewer_invoke is a shell function), so killing the wrapper left `codex` running and
# holding the pipe open — the cap appeared to do nothing. `set -m` puts the command in its
# own process group so `kill -- -PGID` takes down the whole tree.
pipeline_run_timeout() { # <seconds> <cmd> [args...]
  local secs="$1"; shift
  case "$secs" in ''|*[!0-9]*) secs=0 ;; esac
  if [ "$secs" -le 0 ]; then "$@"; return $?; fi

  local marker; marker="$(mktemp "${TMPDIR:-/tmp}/pipeline-timeout.XXXXXX")" || return 1

  local had_m=""; case "$-" in *m*) had_m=1 ;; esac
  set -m
  "$@" &
  local cmd_pid=$!
  # The watchdog stamps the marker BEFORE signalling, so "did the cap fire?" is answered by
  # the marker's contents, not by whether the watchdog happens to still be sleeping.
  ( sleep "$secs"
    printf 'timeout' > "$marker"
    kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null
    sleep 5
    kill -KILL -"$cmd_pid" 2>/dev/null || kill -KILL "$cmd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  local wd_pid=$!
  local rc=0
  wait "$cmd_pid" || rc=$?
  kill -TERM -"$wd_pid" 2>/dev/null || kill -TERM "$wd_pid" 2>/dev/null
  wait "$wd_pid" 2>/dev/null || true
  [ -n "$had_m" ] || set +m

  if [ -s "$marker" ]; then
    echo "dev-pipeline: reviewer exceeded REVIEWER_TIMEOUT=${secs}s — process tree killed" >&2
    rc=124
  fi
  rm -f "$marker"
  return $rc
}

# ── Misc ─────────────────────────────────────────────────────────────────────
# A lowercase RFC-4122 uuid. /proc is Linux-only; uuidgen exists on macOS and most Linuxes.
pipeline_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# Fail early with an actionable message rather than deep inside a stage.
pipeline_require() { # <cmd> [<cmd>...]
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || pipeline_die "required command(s) not on PATH: ${missing[*]}"
}
