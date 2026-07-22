# Project review rules (example)

Copy this to `<repo>/.claude/REVIEW_RULES.md` and replace the contents with YOUR repo's
load-bearing rules. The file is appended verbatim to **both** reviewer prompts (plan review
and code review) under a `# PROJECT REVIEW RULES` heading, and the reviewer is told to treat
the entries as rubric items carrying the same weight as its built-in ones.

Keep it short and load-bearing. Every line costs reviewer attention, and a long list of soft
preferences is exactly what turns a high-signal review into nitpicking. If a rule wouldn't
change whether you'd ship, it does not belong here.

- **Reuse before writing.** Before hand-rolling non-trivial logic, a proven library already in
  the repo (or a mature package) must be reused, or the hand-roll explicitly justified. Flag
  from-scratch implementations of what a library already provides.
- **No silent fallbacks.** Errors surface; no empty `catch`, no default-on-error that hides a
  failed call. Flag anything that turns a failure into a plausible-looking success.
- **Migrations must be reversible.** Flag a schema change that cannot be rolled back without
  data loss.
