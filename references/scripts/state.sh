#!/usr/bin/env bash
# state.sh — read/update the current session's pipeline state.
#
# State lives in the MAIN repo at $PIPELINE_RUNTIME_DIR/sessions/$CLAUDE_CODE_SESSION_ID/state.json,
# resolved via git's common dir so it works identically from a linked worktree.
#
# Usage:
#   state.sh dir                     -> print (and create) the session dir
#   state.sh file                    -> print the state.json path
#   state.sh root                    -> print the resolved main repo root
#   state.sh show                    -> print the whole state json ({} if none)
#   state.sh get <key>               -> print a value (empty if unset)
#   state.sh set <key>=<val> ...     -> set keys; <val> parsed as JSON, else stored as string
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/pipeline-lib.sh"
pipeline_init
pipeline_require python3

SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || pipeline_die "CLAUDE_CODE_SESSION_ID is not set — run this from a Claude Code session"
# Guard against a session id that would escape the runtime dir.
case "$SID" in *[/\\]*|.|..) pipeline_die "refusing unsafe CLAUDE_CODE_SESSION_ID: $SID" ;; esac

SDIR="$ROOT/$PIPELINE_RUNTIME_DIR/sessions/$SID"
SF="$SDIR/state.json"
mkdir -p "$SDIR"

cmd="${1:-show}"; shift || true
case "$cmd" in
  root) echo "$ROOT" ;;
  dir)  echo "$SDIR" ;;
  file) echo "$SF" ;;
  show) cat "$SF" 2>/dev/null || echo "{}" ;;
  get)
    python3 - "$SF" "${1:?usage: state.sh get <key>}" <<'PY'
import json, os, sys
sf, key = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(sf)) if os.path.exists(sf) else {}
except (json.JSONDecodeError, OSError) as e:
    print(f"state.sh: unreadable state file {sf}: {e}", file=sys.stderr)
    sys.exit(1)
v = d.get(key, "")
if isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, (dict, list)):
    print(json.dumps(v))
elif v is None:
    print("")
else:
    print(v)
PY
    ;;
  set)
    [ $# -gt 0 ] || pipeline_die "usage: state.sh set <key>=<value> [...]"
    python3 - "$SF" "$SID" "$@" <<'PY'
import json, os, sys, tempfile, time
sf, sid = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(sf)) if os.path.exists(sf) else {}
except (json.JSONDecodeError, OSError):
    d = {}          # a corrupt state file must not wedge the pipeline; rebuild it
if not isinstance(d, dict):
    d = {}
d["sessionId"] = sid
for pair in sys.argv[3:]:
    k, sep, raw = pair.partition("=")
    if not sep:
        sys.exit(f"state.sh set: expected key=value, got {pair!r}")
    try:
        d[k] = json.loads(raw)
    except json.JSONDecodeError:
        d[k] = raw
d["updatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
# Atomic write: a half-written state.json read by a concurrent stage is worse than a stale one.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(sf) or ".", suffix=".tmp")
with os.fdopen(fd, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, sf)
PY
    ;;
  *) pipeline_die "unknown command: $cmd (try: dir|file|root|show|get|set)" ;;
esac
