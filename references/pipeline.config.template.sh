#!/usr/bin/env bash
# .claude/pipeline.config.sh — THIS project's dev-pipeline settings.
#
# Seeded by `install.sh init`. Sourced ON TOP of the skill's pipeline.config.defaults.sh,
# so you only need to set what differs; delete a line to fall back to the default.
# Two variables are already set when this runs and may be referenced freely:
#   ROOT       — this repo's root (worktree-aware)
#   SKILL_DIR  — the installed dev-pipeline bundle
#
# Skill bundle this repo was initialised against: @@SKILL_DIR@@

# ── Git / worktree topology ──────────────────────────────────────────────────
PIPELINE_BASE_BRANCH="@@BASE_BRANCH@@"     # PRs target this; worktrees fork from it
# PIPELINE_WORKTREE_ROOT="$ROOT/../$(basename "$ROOT")-wt"   # default: sibling "<repo>-wt"
PIPELINE_APP_SUBDIR=""                     # sub-dir the app lives in ("" = repo root)

# ── Plans ────────────────────────────────────────────────────────────────────
# A path FRAGMENT: any Write/Edit to a path containing it is recorded as this session's plan.
PIPELINE_PLAN_GLOB="/plans/"

# ── Reviewer ─────────────────────────────────────────────────────────────────
# Leave REVIEWER_MODEL empty to use your reviewer CLI's own default (recommended — pinned
# model ids go stale and a stale pin fails the gate). Set it if you need a specific model.
# REVIEWER_MODEL="gpt-5.1-codex-max"
REVIEWER_EFFORT="high"
# Needs network (code review posts via `gh`) AND writes outside the worktree (the plan-review
# verdict lands in the main repo's session dir), so workspace-write is not enough for codex.
REVIEWER_SANDBOX="danger-full-access"
REVIEWER_TIMEOUT="3600"                    # seconds; 0 disables the cap

# Swap reviewers wholesale by redefining this. It gets ONE argument: a prompt file.
# reviewer_invoke() {
#   claude -p --dangerously-skip-permissions < "$1"
# }

# ── Worktree lifecycle ───────────────────────────────────────────────────────
# Runs in each NEW worktree, with the absolute app dir as $1. Install deps / generate
# clients here — NEVER share them from the main checkout.
pipeline_worktree_setup() {
  local app="$1"
  # ( cd "$app" && CI=true pnpm install --frozen-lockfile ) || return 1
  # ( cd "$app" && ./node_modules/.bin/prisma generate )   || return 1
  :
}

# Runs BEFORE a worktree is removed (same argument). Repair anything a per-worktree install
# repointed in the main checkout.
pipeline_worktree_teardown() {
  local app="$1"
  :
}

# Gitignored paths SAFE to symlink from the main checkout into a worktree, space-separated,
# relative to the app dir. NEVER node_modules or a generated client.
PIPELINE_WORKTREE_SYMLINKS=""
