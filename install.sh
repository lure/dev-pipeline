#!/usr/bin/env bash
# install.sh — install the dev-pipeline skill, then wire it into a repo.
#
#   install.sh global [--force]     Copy this bundle to ~/.claude/skills/dev-pipeline so every
#                                   project can use it. Re-run to update; never touches repos.
#   install.sh init [namespace]     Run INSIDE a target repo. Seeds .claude/pipeline.config.sh,
#                                   merges the PostToolUse plan hook into .claude/settings.json,
#                                   and writes slash-command shims under
#                                   .claude/commands/<namespace>/ (default namespace: pipeline).
#   install.sh doctor               Check this machine/repo: required CLIs, config, hook, shims.
#
# Both steps are idempotent. `init` never overwrites an existing pipeline.config.sh.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GLOBAL_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/dev-pipeline"
CODEX_DIR="${CODEX_SKILLS_DIR:-$HOME/.agents/skills}/dev-pipeline"
SKILL_NAME="dev-pipeline"

die()  { echo "install: $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }
note() { echo "  · $*"; }

need_repo() {
  git rev-parse --git-common-dir >/dev/null 2>&1 || die "not inside a git repository (cwd: $PWD)"
  ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
  [ -n "$ROOT" ] && [ "$ROOT" != "/" ] || die "refusing to operate on repo root '$ROOT'"
}

# ── global ───────────────────────────────────────────────────────────────────
cmd_global() {
  local force="${1:-}"
  if [ "$SKILL_DIR" = "$GLOBAL_DIR" ]; then
    echo "already running from the global location: $GLOBAL_DIR"
    chmod +x "$GLOBAL_DIR/references/scripts/"*.sh "$GLOBAL_DIR/install.sh"
    ok "executable bits refreshed"
    return 0
  fi
  echo "dev-pipeline → installing globally to $GLOBAL_DIR"
  if [ -e "$GLOBAL_DIR" ] && [ "$force" != "--force" ]; then
    note "$GLOBAL_DIR exists — updating in place (use --force to wipe it first)"
  elif [ -e "$GLOBAL_DIR" ]; then
    rm -rf "$GLOBAL_DIR"; note "removed existing $GLOBAL_DIR"
  fi
  mkdir -p "$GLOBAL_DIR"
  # Copy the bundle, excluding editor cruft and any local runtime droppings.
  ( cd "$SKILL_DIR" && tar --exclude='.git' --exclude='.idea' --exclude='.DS_Store' --exclude='__pycache__' \
      --exclude='pipeline.config.sh' -cf - . ) | ( cd "$GLOBAL_DIR" && tar -xf - )
  chmod +x "$GLOBAL_DIR/references/scripts/"*.sh "$GLOBAL_DIR/install.sh"
  ok "bundle copied"
  ok "skill available as: $SKILL_NAME"
  echo
  echo "next, in each repo you want to use it in:"
  echo "  cd /path/to/repo && bash $GLOBAL_DIR/install.sh init"
}

# Codex discovers the same bundle through its user skills directory. Refuse to replace
# another installation; keeping one bundle prevents host modes from drifting apart.
cmd_codex() {
  mkdir -p "$(dirname "$CODEX_DIR")"
  if [ -L "$CODEX_DIR" ] && [ "$(cd "$CODEX_DIR" && pwd -P)" = "$SKILL_DIR" ]; then
    ok "Codex skill already linked: $CODEX_DIR"
  elif [ -e "$CODEX_DIR" ] || [ -L "$CODEX_DIR" ]; then
    die "$CODEX_DIR already exists and points elsewhere; refusing to overwrite it"
  else
    ln -s "$SKILL_DIR" "$CODEX_DIR"
    ok "Codex skill linked: $CODEX_DIR -> $SKILL_DIR"
  fi
  note "start a new Codex session to refresh skill discovery; invoke with \$dev-pipeline"
}

# ── init ─────────────────────────────────────────────────────────────────────
cmd_init() {
  local ns="${1:-pipeline}"
  case "$ns" in ''|*[!a-zA-Z0-9_-]*) die "namespace must be [A-Za-z0-9_-]+, got: $ns" ;; esac
  need_repo
  echo "dev-pipeline init → repo: $ROOT"
  echo "  skill bundle:      $SKILL_DIR"
  echo "  command namespace: /$ns:*"
  mkdir -p "$ROOT/.claude"

  chmod +x "$SKILL_DIR/references/scripts/"*.sh 2>/dev/null || true

  # 1. Per-repo config, seeded from the template. NEVER clobber an existing one.
  local cfg="$ROOT/.claude/pipeline.config.sh"
  if [ -f "$cfg" ]; then
    note "config exists — left untouched: .claude/pipeline.config.sh"
  else
    local base
    base="$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
    [ -n "$base" ] || base="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
    render_template "$SKILL_DIR/references/pipeline.config.template.sh" "$SKILL_DIR" "$base" > "$cfg"
    ok "wrote .claude/pipeline.config.sh (base branch: $base) — edit it for this project"
  fi

  # 2. PostToolUse plan hook in .claude/settings.json.
  local hook_cmd="$SKILL_DIR/references/scripts/record-plan.sh"
  SETTINGS="$ROOT/.claude/settings.json" HOOK_CMD="$hook_cmd" python3 - <<'PY'
import json, os, sys
sp = os.environ["SETTINGS"]; cmd = os.environ["HOOK_CMD"]
if os.path.exists(sp):
    try:
        cfg = json.load(open(sp))
    except Exception as e:
        # Never silently overwrite a user's settings.json because it failed to parse.
        sys.exit(f"  ✗ {sp} is not valid JSON ({e}) — fix it, then re-run `install.sh init`")
    if not isinstance(cfg, dict):
        sys.exit(f"  ✗ {sp} is not a JSON object — fix it, then re-run `install.sh init`")
else:
    cfg = {}
hooks = cfg.setdefault("hooks", {}).setdefault("PostToolUse", [])
existing = [h for e in hooks for h in e.get("hooks", []) if h.get("type") == "command"]
same = [h for h in existing if h.get("command") == cmd]
stale = [h for h in existing
         if h is not None and h.get("command", "").endswith("/record-plan.sh") and h.get("command") != cmd]
if same:
    print("  · plan hook already present — left as-is")
elif stale:
    for h in stale:
        h["command"] = cmd
    json.dump(cfg, open(sp, "w"), indent=2)
    print("  ✓ repointed existing plan hook at the current skill location")
else:
    hooks.append({"matcher": "Write|Edit|MultiEdit",
                  "hooks": [{"type": "command", "command": cmd}]})
    json.dump(cfg, open(sp, "w"), indent=2)
    print("  ✓ added PostToolUse plan hook to .claude/settings.json")
PY

  # 3. Slash-command shims. The absolute skill path is baked in at init time, so the
  #    commands work whether the bundle is global or vendored into this repo.
  local cmddir="$ROOT/.claude/commands/$ns"
  mkdir -p "$cmddir"
  emit_cmd() { # $1=name $2=description $3=arg-hint $4=stage-file
    cat > "$cmddir/$1.md" <<EOF
---
description: $2
argument-hint: "$3"
---
Run the **$1** stage of the dev-pipeline skill.

Set \`PIPELINE_SKILL_DIR=$SKILL_DIR\` in every bash call you make for this stage, then read
and follow \`$SKILL_DIR/references/stages/$4\` in full, treating the text below as its
argument.

Argument: \$ARGUMENTS
EOF
  }
  emit_cmd spec-review "Reviewer plan-review gate — iterate this session's plan to approval, then auto-continue to implement" "[plan-path]" spec-review.md
  emit_cmd implement   "Build the approved plan in the worktree, push, open a draft PR, then auto-continue to code-review" "[plan-path]" implement.md
  emit_cmd code-review "Reviewer code-review gate on the session's PR — address every comment, gate the merge" "[pr-number]" code-review.md
  emit_cmd epic        "Orchestrate an epic — run every open subtask through the full pipeline autonomously in dependency order" "<epic-issue>" epic.md
  ok "wrote 4 command shims under .claude/commands/$ns/"

  # 4. Keep runtime state out of git.
  local gi="$ROOT/.gitignore"
  if [ -f "$gi" ] && grep -qxF ".claude/dev-pipeline/" "$gi" 2>/dev/null; then
    note ".gitignore already ignores .claude/dev-pipeline/"
  else
    printf '\n# dev-pipeline runtime state (per-session json, epic logs)\n.claude/dev-pipeline/\n' >> "$gi"
    ok "added .claude/dev-pipeline/ to .gitignore"
  fi

  echo
  echo "done. Next:"
  echo "  1. edit .claude/pipeline.config.sh (base branch, app subdir, reviewer, worktree hooks)"
  echo "  2. optionally write .claude/REVIEW_RULES.md (appended to both reviewer prompts)"
  echo "  3. START A NEW Claude Code session — settings/hooks are read at startup"
  echo "  4. drive a change with /$ns:spec-review, or an epic with /$ns:epic <issue>"
}

# Tiny template renderer (no envsubst dependency): replaces @@NAME@@ tokens.
render_template() { # <template> <skill-dir> <base-branch>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
tmpl, skill_dir, base = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(tmpl).read()
t = t.replace("@@SKILL_DIR@@", skill_dir).replace("@@BASE_BRANCH@@", base)
sys.stdout.write(t)
PY
}

# ── doctor ───────────────────────────────────────────────────────────────────
cmd_doctor() {
  local rc=0
  echo "dev-pipeline doctor"
  echo "  bundle: $SKILL_DIR"
  for c in git python3 gh claude codex; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c: $(command -v "$c")"
    else echo "  ✗ $c NOT on PATH"; rc=1; fi
  done
  note "REVIEWER_TIMEOUT is enforced by a built-in process-group watchdog (no coreutils needed)"
  if gh auth status >/dev/null 2>&1; then ok "gh authenticated"
  else echo "  ✗ gh not authenticated (run: gh auth login)"; rc=1; fi

  if git rev-parse --git-common-dir >/dev/null 2>&1; then
    need_repo
    echo "  repo: $ROOT"
    [ -f "$ROOT/.claude/pipeline.config.sh" ] \
      && ok "config: .claude/pipeline.config.sh" \
      || { echo "  ✗ no .claude/pipeline.config.sh — run: install.sh init"; rc=1; }
    [ -f "$ROOT/.claude/REVIEW_RULES.md" ] \
      && ok "review rules: .claude/REVIEW_RULES.md" \
      || note "no .claude/REVIEW_RULES.md (optional)"
    source "$SKILL_DIR/references/scripts/pipeline-lib.sh"
    pipeline_resolve_host
    if [ "$PIPELINE_HOST" = claude ]; then
      grep -q record-plan.sh "$ROOT/.claude/settings.json" 2>/dev/null \
        && ok "plan hook registered in .claude/settings.json" \
        || { echo "  ✗ plan hook missing — run: install.sh init"; rc=1; }
    else
      note "Codex records planPath explicitly with state.sh; no Claude plan hook required"
    fi
    # Load the real config exactly the way the scripts do, and report what it resolved to —
    # this is the check that catches a config that fails to source at all.
    ( source "$SKILL_DIR/references/scripts/pipeline-lib.sh" && pipeline_init \
      && echo "  · base branch:   $PIPELINE_BASE_BRANCH" \
      && echo "  · worktree root: $PIPELINE_WORKTREE_ROOT" \
      && echo "  · app dir:       $PIPELINE_APP_DIR" \
      && echo "  · plan glob:     $PIPELINE_PLAN_GLOB" \
      && echo "  · host/reviewer: $PIPELINE_HOST / $PIPELINE_REVIEWER_CLI (unless reviewer_invoke is overridden)" \
      && echo "  · reviewer knobs: model=${REVIEWER_MODEL:-<cli default>} effort=${REVIEWER_EFFORT:-} sandbox=${REVIEWER_SANDBOX:-} timeout=${REVIEWER_TIMEOUT:-0}s max rounds=$PIPELINE_MAX_ROUNDS" \
      && echo "  · branches:      ${PIPELINE_BRANCH_PREFIX}<slug>, merged with --$PIPELINE_MERGE_METHOD" \
      && { pipeline_may_merge \
             && echo "  · merging:       you may merge (PIPELINE_MERGERS=${PIPELINE_MERGERS:-<anyone>})" \
             || echo "  · merging:       reserved for ${PIPELINE_MERGERS}; GATE 2 stops at a PR ready for review"; } \
      ) || { echo "  ✗ config failed to load — see the error above"; rc=1; }
  else
    note "not in a git repo — skipping repo checks"
  fi
  return $rc
}

usage() {
  cat <<'EOF'
dev-pipeline installer

  install.sh global [--force]   Install/update the bundle at ~/.claude/skills/dev-pipeline.
                                Run once per machine. Never touches your repos.
  install.sh codex              Link this bundle into ~/.agents/skills/dev-pipeline for Codex.
                                CODEX_SKILLS_DIR overrides the parent directory.
  install.sh init [namespace]   Run INSIDE a repo. Seeds .claude/pipeline.config.sh, adds the
                                PostToolUse plan hook, writes /<namespace>:* command shims
                                (default namespace: pipeline). Never clobbers an existing config.
  install.sh doctor             Check CLIs, auth, config, hook, and what the config resolves to.

Typical first run:
  bash install.sh global
  bash ~/.claude/skills/dev-pipeline/install.sh codex
  cd /path/to/repo && bash ~/.claude/skills/dev-pipeline/install.sh init
EOF
}

case "${1:-}" in
  global)  shift; cmd_global "${1:-}" ;;
  codex)   cmd_codex ;;
  init)    shift; cmd_init "${1:-pipeline}" ;;
  doctor)  cmd_doctor ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $1 (try: global | codex | init | doctor)" ;;
esac
