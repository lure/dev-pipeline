# YouTrack epics (Codex and Claude Code)

Use this for full issue IDs, for example `PROJ-100`. PRs and reviews remain on GitHub; issue
discovery, comments, and completion use the existing YouTrack MCP connection. No REST token or
second model is needed for tracker calls.

## Discover and freeze the work

1. Read the epic with MCP `get_issue`. Read its real linked children with
   `search_issues(query="subtask of: PROJ-100", limit=10, offset=0)` and paginate until
   `hasNextPage=false`. A Markdown checklist is optional.
2. Read each child and the project field schema (`get_issue_fields_schema`). Preserve full IDs.
   The completion fields come from `PIPELINE_YOUTRACK_DONE_FIELDS` when the repo config sets it.
   Otherwise choose the project's successful resolved state from the schema (never a cancelled or
   duplicate state), confirm it with the user, and offer to save it in the repo config.
3. Freeze dependencies from the issue links and descriptions. For each prerequisite X, the query
   `depends on: X` finds its dependents; add X to each returned child's dependencies. Cross-check
   against the epic's work breakdown. Include external/already-complete prerequisites in `deps`.
   Topologically order the open children; stop on cycles or conflicting requirements.
4. Resolve the GitHub repository from the actual checkout (`gh repo view --json nameWithOwner`).
   It is independent of the YouTrack project: a project keyed `PROJ` can ship from any repository,
   such as `acme/app`. Freeze the initiating host too.

Write the manifest in this session's state directory, as in epic stage §3:

```json
{
  "tracker": "youtrack",
  "epic": "PROJ-100",
  "repository": "acme/app",
  "host": "codex",
  "model": null,
  "order": ["PROJ-101", "PROJ-102"],
  "deps": {"PROJ-102": ["PROJ-101"]},
  "youtrack": {"doneFields": {"Stage": "Done"}}
}
```

The example shows the manifest shape only. A Claude-led run sets
`host` to `claude`. Run it through the same `run-epic.sh` and `epic-progress.sh` entry points.
Legacy numeric GitHub manifests keep working without a `tracker` field.

## MCP connection and preflight

The adapter uses the official MCP Python SDK, pinned in `references/scripts/youtrack_mcp.py` and
launched with `uv run --script`. Install `uv` if absent. A first run fetches the SDK into uv's cache;
later runs reuse it. It supports stdio and authenticated Streamable HTTP connections.

- Codex: reads `codex mcp get youtrack --json`, honoring enabled/disabled tool lists.
- Claude Code: reads its local project connection in `~/.claude.json`, then the repo's `.mcp.json`,
  then the user connection in `~/.claude.json`.
- `PIPELINE_YOUTRACK_MCP_SERVER` changes the connection name (default `youtrack`).
- `PIPELINE_YOUTRACK_MCP_CONFIG` optionally points to an existing JSON MCP configuration. Do not
  copy credentials into manifests, repo files, prompts, or logs.
- `PIPELINE_YOUTRACK_TIMEOUT` bounds each MCP operation (default 120 seconds).

After the common skill preamble, a read-only readiness check is:

```bash
uv run --script "$SKILL_DIR/references/scripts/youtrack_mcp.py" preflight "$EPIC" \
  --host "$PIPELINE_HOST" --root "$ROOT" --manifest "$MANIFEST"
```

It checks MCP access, completion fields, required tools, and that manifest subtasks are linked to
the epic. The driver also checks the current checkout's GitHub repository before launching work.
Missing configuration/authentication fails before implementation. Child implementer sessions use
the same host MCP setup; project override variables are exported by `pipeline_init`.

## Completion, failure, and resume

Subtasks include their full YouTrack URL and ID in the PR body and retain `prNumber` and `branch`
in pipeline state. The driver checks the PR's repository, merged timestamp/status, head branch,
base branch, and exact issue reference through `gh`. A `SUBTASK_DONE` message alone is insufficient.

Before making a completion write, it saves a merged-PR receipt under the epic log directory.
It adds an idempotent PR-link comment, updates only `doneFields`, and reads the issue back. Both
the requested values and YouTrack's `resolvedAt` must confirm success. Cancelled/duplicate outcomes,
partial updates, unavailable MCP, or unmerged PRs halt the run before dependents start.

On retry, the driver re-verifies the receipt's PR and retries tracker completion without launching
implementation again. It never falls back to a GitHub issue with the same numeric suffix.
An already-complete child is skipped. At the end, all live linked children are re-read; a newly
added or still-open child leaves the epic open. Descriptions and unrelated fields are preserved.

Adapter actions are `read`, `schema`, `children`, `preflight`, `state`, `comment --file`,
`complete --state --receipt --base`, and `finish-epic`. Completion/state actions require `--manifest`;
all accept `--host` and `--root`. Run `--help` for the full CLI.
