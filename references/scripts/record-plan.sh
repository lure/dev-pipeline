#!/usr/bin/env bash
# record-plan.sh — PostToolUse(Write|Edit|MultiEdit) bookkeeping hook.
#
# Records plan-file writes into the writing session's state.json, keyed by session_id, so
# the spec-review stage can later find "this session's plan" with no argument — even with
# several agents planning in parallel.
#
# Which writes count as a plan is configured by PIPELINE_PLAN_GLOB (a path fragment) and
# where state lives by PIPELINE_RUNTIME_DIR — both from the pipeline config.
#
# Pure bookkeeping: never blocks a tool, never triggers a reviewer, ALWAYS exits 0.
# Deliberately no `set -e` — a hook that aborts mid-way is a hook that loses plan paths.
set -uo pipefail

exit_ok() { exit 0; }
trap exit_ok EXIT

payload="$(cat)"
command -v python3 >/dev/null 2>&1 || exit 0
[ -n "$payload" ] || exit 0

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd 2>/dev/null)" || exit 0

# The hook's own cwd is where Claude Code is running; prefer the payload's cwd when present.
HOOK_CWD="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("cwd") or "").strip())
except Exception:
    print("")
' 2>/dev/null)"
if [ -n "$HOOK_CWD" ] && [ -d "$HOOK_CWD" ]; then cd "$HOOK_CWD" || true; fi

# Resolve the MAIN repo root the same way state.sh does, so both write to the SAME place.
gcd="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$gcd" ]; then ROOT="$(cd "$gcd/.." 2>/dev/null && pwd)"; fi
[ -n "${ROOT:-}" ] || ROOT="$PWD"

# Load config tolerantly: a broken project config must not break the user's Write tool.
# shellcheck source=/dev/null
[ -f "$SKILL_DIR/pipeline.config.defaults.sh" ] && source "$SKILL_DIR/pipeline.config.defaults.sh" 2>/dev/null
REPO_CFG="${PIPELINE_CONFIG:-$ROOT/.claude/pipeline.config.sh}"
# shellcheck source=/dev/null
[ -f "$REPO_CFG" ] && source "$REPO_CFG" 2>/dev/null
: "${PIPELINE_PLAN_GLOB:=/plans/}"
: "${PIPELINE_RUNTIME_DIR:=.claude/dev-pipeline}"

PLAN_GLOB="$PIPELINE_PLAN_GLOB" RUNTIME_DIR="$PIPELINE_RUNTIME_DIR" MAIN_ROOT="$ROOT" \
python3 - "$payload" <<'PY'
import json, os, subprocess, sys, tempfile, time

try:
    p = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

glob    = os.environ.get("PLAN_GLOB", "/plans/")
runtime = os.environ.get("RUNTIME_DIR", ".claude/dev-pipeline")
main    = os.environ.get("MAIN_ROOT") or os.getcwd()

sid = (p.get("session_id") or "").strip()
fp  = (p.get("tool_input") or {}).get("file_path") or ""
if not sid or "/" in sid or "\\" in sid or glob not in fp:
    sys.exit(0)

fp = os.path.abspath(fp)

def toplevel_of(path):
    """Git toplevel CONTAINING the plan file. When planning happens inside a linked
    worktree (the default loop creates the worktree before planning) that is the worktree,
    not the main repo — so planPath stays repo-relative and `$WORKTREE/$planPath` resolves.
    Recording it relative to the main root instead produced '../repo-wt/...' paths that no
    stage could open."""
    d = os.path.dirname(path)
    try:
        out = subprocess.run(["git", "-C", d, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return main

top = toplevel_of(fp)
try:
    rel = os.path.relpath(fp, top)
except ValueError:
    rel = fp
if rel.startswith(".."):        # not under that toplevel after all — store absolute
    rel = fp

# State always lives in the MAIN repo, matching state.sh.
d = os.path.join(main, runtime, "sessions", sid)
try:
    os.makedirs(d, exist_ok=True)
except OSError:
    sys.exit(0)
sf = os.path.join(d, "state.json")
try:
    st = json.load(open(sf)) if os.path.exists(sf) else {}
    if not isinstance(st, dict):
        st = {}
except Exception:
    st = {}

st["sessionId"] = sid
st["planPath"]  = rel
st.setdefault("planApproved", False)
st.setdefault("phase", "planning")
st["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
try:
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        json.dump(st, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, sf)
except OSError:
    pass
PY
exit 0
