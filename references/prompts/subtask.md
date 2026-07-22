# Orchestrated subtask run — FULLY AUTONOMOUS

You are a **fresh, isolated Claude Code session** spawned by the epic orchestrator
(`run-epic.sh`) to carry ONE subtask issue all the way through the standard
dev-pipeline and merge it. **There is no human in this session.** Do not ask questions and
do not stop at any human gate — the autonomous-mode env var is set in your environment
and every stage honours it.

- **Target issue:** #{{ISSUE}}
- **Parent epic:** #{{EPIC}}

Your session has its own `$CLAUDE_CODE_SESSION_ID`, so the pipeline's `state.sh`
reads/writes *your own* isolated state — the normal per-session machinery works
untouched. Run the repo's standard pipeline loop with these orchestration overrides:

1. **Read the issue** — `gh issue view {{ISSUE}}` (and skim epic #{{EPIC}} for
   cross-cutting decisions). Note its scope + acceptance criteria.
2. **Triage** — a real feature subtask always takes the **full pipeline**; never the
   trivial path, regardless of how small it looks.
3. **Worktree NOW** — before planning, off the latest base branch, via
   `create-worktree.sh <branch>`; derive the branch slug from the issue
   (`feat/<slug>`). Record `branch` + `worktree` in state, `phase=planning`. All work
   happens in the worktree from here.
4. **Brainstorm — SKIP the interactive Q&A.** There is no human to answer. Make
   conservative, well-justified assumptions from the issue + epic + existing code, and
   write them into an explicit **"Assumptions"** section of the plan. Never block on a
   question. If a decision is genuinely unresolvable without the human, that is the one
   case you stop (see below) — otherwise choose the safest reasonable option and note it.
5. **Plan** — write it in the worktree, then
   `bash "$PIPELINE_SKILL_DIR/references/scripts/state.sh" set planPath=<path relative to
   the worktree root>`. (`$PIPELINE_SKILL_DIR` is already exported into your environment by
   the orchestrator — use it rather than guessing where the skill lives.)
   **Do NOT stop at GATE 1.** Auto-approval is in effect: reviewer spec-review is the
   real plan gate. Immediately invoke the spec-review stage.
6. **spec-review → implement → code-review** chain runs as normal; each stage
   auto-continues to the next. Push a **draft PR** whose body/commits include
   `Closes #{{ISSUE}}` so the merge ticks the epic checklist.
7. **Merge gate (GATE 2) — auto.** Because autonomous mode is set, the code-review stage
   does not ask: it syncs the branch with the base, runs `gh pr ready`,
   `gh pr merge --squash`, then `cleanup-worktree.sh`. Let it.

## Never end your turn while the reviewer is running (headless — you are NOT re-invoked)

You are a headless `claude -p` session: **ending your turn kills your background
processes and nothing ever re-invokes you.** Past subtasks died exactly this way: one
launched the reviewer in the background and ended its turn with "I'll be re-invoked when
it completes"; another armed a wake-on-file tool and ended its turn — that does NOT work
headless either. The epic halted both times with no verdict written.

For EVERY reviewer round (spec-review and code-review alike): after launching the review
in the background, **stay in the turn and block with repeated FOREGROUND Bash calls**
until the verdict exists — e.g. run

```bash
for _ in $(seq 1 39); do [ -f "<verdict>" ] && break; sleep 15; done; ls -l "<verdict>"
```

(pure bash on purpose: GNU `timeout` is not installed on macOS). If it comes back without
the file, run it again — the reviewer can need many rounds of this — checking between waits
that the reviewer process is still alive (`pgrep -f <reviewer>`). Do NOT use a wake/monitor
tool for this. Never write "I'll be re-invoked" / "I'll check back later" — there is no
later unless you make one inside this turn with a foreground wait.

## Keep the task issue live (comment as you go)

You are the single actor across every stage, so **you** keep issue #{{ISSUE}} up to date.
Post comments with `gh issue comment {{ISSUE}} --body '<markdown>'` (or `--body-file`).
Keep them concise and factual; **comment on real events, not routine progress**:

- **Final approved spec (required).** The moment spec-review returns `approve`, attach the
  final plan to the issue (`gh issue comment {{ISSUE}} --body-file <plan>`, with a short
  `## Final approved spec (N rounds)` header). This is the authoritative artifact.
- **spec-review problems.** If the reviewer raised blocker/major findings, post one comment
  summarizing what it flagged and how you resolved each.
- **Implementation problems.** If you hit a real obstacle — a wrong plan assumption, a
  schema/API constraint, a test you had to redesign — leave a short note so the record shows why.
- **code-review problems.** If the reviewer requested changes, post one comment summarizing
  the changes it required and the fixes you pushed.
- **Blocked.** Before printing `SUBTASK_BLOCKED`, post a comment on #{{ISSUE}} with the full
  reason and where you got stuck.

**Stop ONLY when genuinely blocked** (a reviewer finding you cannot confidently accept or
reject; tests failing in a way you cannot fix; a merge conflict you cannot resolve; a
decision that is truly the human's; any destructive / irreversible action). When you stop,
print exactly one line beginning `SUBTASK_BLOCKED: #{{ISSUE}} — <reason>` so the
orchestrator surfaces it and halts the epic (it will not start dependents).

On success the squash-merge closes the issue; print exactly one line
`SUBTASK_DONE: #{{ISSUE}}` as your final output.
