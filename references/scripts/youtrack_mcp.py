# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp==1.30.0"]
# ///
"""YouTrack tracker adapter. Reuses host MCP settings; never uses the REST API."""
import argparse
import asyncio
from contextlib import AsyncExitStack
from datetime import timedelta
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


class AdapterError(Exception):
    pass


def load_connection(host, root, server="youtrack", config_file=None, user_home=None):
    """Keep connection data in memory, including any existing header credentials."""
    if config_file:
        data = json.loads(Path(config_file).read_text())
        return data.get("mcpServers", {}).get(server) or data
    if host == "codex":
        result = subprocess.run(["codex", "mcp", "get", server, "--json"],
                                cwd=root, capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise AdapterError("Codex YouTrack MCP connection is unavailable")
        data = json.loads(result.stdout)
        if not data.get("enabled", True):
            raise AdapterError("Codex YouTrack MCP connection is disabled")
        return {**data["transport"], "_enabled_tools": data.get("enabled_tools"),
                "_disabled_tools": data.get("disabled_tools")}
    if host != "claude":
        raise AdapterError("PIPELINE_HOST must be codex or claude")
    home = Path(user_home) if user_home else Path.home()
    settings = home / ".claude.json"
    data = json.loads(settings.read_text()) if settings.exists() else {}
    # Claude's local project config takes precedence over shared and user settings.
    local = data.get("projects", {}).get(str(Path(root).resolve()), {}).get("mcpServers", {}).get(server)
    shared_file = Path(root) / ".mcp.json"
    shared = json.loads(shared_file.read_text()).get("mcpServers", {}).get(server) if shared_file.exists() else None
    connection = local or shared or data.get("mcpServers", {}).get(server)
    if not connection:
        raise AdapterError("Claude Code YouTrack MCP connection is unavailable")
    return connection


def decode_result(result):
    if result.isError:
        raise AdapterError("YouTrack MCP tool failed (server response omitted to protect credentials)")
    value = getattr(result, "structuredContent", None)
    if value is None:
        blocks = [c.text for c in result.content if getattr(c, "type", None) == "text"]
        if len(blocks) != 1:
            raise AdapterError("YouTrack MCP returned an unexpected result")
        value = json.loads(blocks[0])
    if isinstance(value, dict) and value.get("failedToUpdateFields"):
        raise AdapterError("YouTrack rejected one or more custom field updates")
    return value


class YouTrack:
    def __init__(self, session, names):
        self.session, self.names = session, names

    async def call(self, name, **args):
        if name not in self.names:
            raise AdapterError(f"YouTrack MCP is missing required tool: {name}")
        return decode_result(await self.session.call_tool(name, args))

    async def issue(self, issue):
        result = await self.call("get_issue", issueId=issue, recentCommentsCount=0)
        if result.get("id") != issue:
            raise AdapterError("YouTrack returned a different issue")
        return result

    async def children(self, epic):
        issues, offset = [], 0
        while True:
            result = await self.call("search_issues", query=f"subtask of: {epic}", limit=10,
                                     offset=offset, customFieldsToReturn=[])
            page = result["issuesPage"]
            issues.extend(page)
            if not result.get("hasNextPage"):
                return issues
            if not page:
                raise AdapterError("YouTrack pagination did not advance")
            offset += len(page)

    async def comment_once(self, issue, text, marker):
        offset = 0
        while True:
            result = await self.call("get_issue_comments", issueId=issue, limit=10, offset=offset)
            if not isinstance(result, list):
                raise AdapterError("Unexpected YouTrack comments response")
            if any(marker in c.get("text", "") for c in result):
                return
            if len(result) < 10:
                break
            offset += len(result)
        await self.call("add_issue_comment", issueId=issue, text=text + "\n\n" + marker)


def done_fields(manifest):
    fields = manifest.get("youtrack", {}).get("doneFields")
    if not isinstance(fields, dict) or not fields or not all(isinstance(k, str) and isinstance(v, str) for k, v in fields.items()):
        raise AdapterError("YouTrack manifest requires youtrack.doneFields from the project schema")
    return fields


def issue_state(issue, fields):
    matches = all(issue.get("customFields", {}).get(k) == v for k, v in fields.items())
    resolved = issue.get("resolvedAt") is not None
    if matches and resolved:
        return "CLOSED"
    if resolved:
        return "OTHER_RESOLVED"   # cancelled/duplicate is not implemented work
    return "UNKNOWN" if matches else "OPEN"


async def validate_fields(yt, issue, fields):
    schema = await yt.call("get_issue_fields_schema", projectKey=issue["project"])
    for name, value in fields.items():
        if value not in schema.get("properties", {}).get(name, {}).get("enum", []):
            raise AdapterError(f"Completion field/value is not in the project schema: {name}")


def atomic_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def merged_pr(issue, state, manifest, base):
    number, branch = state.get("prNumber"), state.get("branch")
    if not str(number or "").isdigit() or not branch:
        raise AdapterError("Subtask has no PR number/branch in pipeline state")
    result = subprocess.run(["gh", "pr", "view", str(number), "--repo", manifest["repository"],
        "--json", "state,mergedAt,url,headRefName,baseRefName,body,mergeCommit"],
        capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AdapterError("Could not verify the subtask PR via GitHub")
    pr = json.loads(result.stdout)
    if (pr.get("state") != "MERGED" or not pr.get("mergedAt") or
            pr.get("headRefName") != branch or pr.get("baseRefName") != base or
            not re.search(r"(?<![A-Z0-9-])" + re.escape(issue) + r"(?![A-Z0-9-])", pr.get("body", ""))):
        raise AdapterError("Subtask PR is not merged into the configured base with the correct issue reference")
    if not pr.get("url", "").startswith(f'https://github.com/{manifest["repository"]}/pull/'):
        raise AdapterError("Subtask PR belongs to a different repository")
    return {"prNumber": number, "branch": branch, "repository": manifest["repository"], "url": pr["url"]}


async def perform(yt, args, manifest):
    issue = args.issue
    if args.action == "read":
        return await yt.issue(issue)
    if args.action == "schema":
        return await yt.call("get_issue_fields_schema", projectKey=issue)
    if args.action == "children":
        return await yt.children(issue)
    if args.action == "comment":
        return await yt.call("add_issue_comment", issueId=issue, text=Path(args.file).read_text())
    fields = done_fields(manifest)
    current = await yt.issue(issue)
    if args.action == "state":
        return issue_state(current, fields)
    await validate_fields(yt, current, fields)
    if args.action == "preflight":
        required = {"get_issue", "get_issue_fields_schema", "search_issues", "get_issue_comments",
                    "add_issue_comment", "update_issue"}
        if not required.issubset(yt.names):
            raise AdapterError("YouTrack MCP does not enable every tool required for an epic run")
        children = await yt.children(issue)
        if not children or not set(map(str, manifest["order"])).issubset({c["id"] for c in children}):
            raise AdapterError("Manifest subtasks must be linked children of the YouTrack epic")
        return {"ready": True, "children": [c["id"] for c in children]}
    if args.action == "complete":
        proof = args.proof
        if issue_state(current, fields) == "OTHER_RESOLVED":
            raise AdapterError("Subtask was resolved for another reason; refusing to overwrite its outcome")
        marker = f'<!-- dev-pipeline:merged:{issue}:{proof["url"]} -->'
        await yt.comment_once(issue, f'Implemented and merged: {proof["url"]}', marker)
    elif args.action == "finish-epic":
        children = await yt.children(issue)
        if not children:
            raise AdapterError("Refusing to complete an epic without linked children")
        for child in children:
            if issue_state(await yt.issue(child["id"]), fields) != "CLOSED":
                return {"closed": False, "remaining": child["id"]}
        if issue_state(current, fields) == "OTHER_RESOLVED":
            raise AdapterError("Epic was resolved for another reason; refusing to overwrite its outcome")
    if issue_state(current, fields) != "CLOSED":
        await yt.call("update_issue", issueId=issue, customFields=fields)
    if issue_state(await yt.issue(issue), fields) != "CLOSED":
        raise AdapterError("YouTrack completion read-back did not confirm the requested resolved state")
    return {"closed": True, "issue": issue}


async def run(args):
    # Import lazily so normalization/configuration tests need only Python's standard library.
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    from mcp.client.streamable_http import streamablehttp_client
    manifest = json.loads(Path(args.manifest).read_text()) if args.manifest else {}
    if args.action == "complete":
        args.proof = merged_pr(args.issue, json.loads(Path(args.state).read_text()), manifest, args.base)
        # Persist even if MCP is unavailable: resume retries completion, never implementation.
        atomic_json(args.receipt, args.proof)
    cfg = load_connection(args.host, args.root, os.environ.get("PIPELINE_YOUTRACK_MCP_SERVER", "youtrack"),
                          os.environ.get("PIPELINE_YOUTRACK_MCP_CONFIG"))
    async with AsyncExitStack() as stack:
        if "command" in cfg:
            params = StdioServerParameters(command=cfg["command"], args=cfg.get("args") or [],
                cwd=cfg.get("cwd") or args.root, env={**os.environ, **(cfg.get("env") or {})})
            # Some MCP launchers echo auth headers on stderr. Never put them in epic logs.
            errlog = stack.enter_context(open(os.devnull, "w"))
            streams = await stack.enter_async_context(stdio_client(params, errlog=errlog))
        elif cfg.get("url"):
            headers = dict(cfg.get("headers") or cfg.get("http_headers") or {})
            for header, var in (cfg.get("env_http_headers") or {}).items():
                headers[header] = os.environ[var]
            token_var = cfg.get("bearer_token_env_var")
            if token_var:
                headers["Authorization"] = "Bearer " + os.environ[token_var]
            streams = await stack.enter_async_context(streamablehttp_client(cfg["url"], headers=headers))
        else:
            raise AdapterError("Unsupported YouTrack MCP transport; configure stdio or authenticated HTTP")
        session = await stack.enter_async_context(ClientSession(streams[0], streams[1],
            read_timeout_seconds=timedelta(seconds=args.timeout)))
        await session.initialize()
        names = {t.name for t in (await session.list_tools()).tools}
        if cfg.get("_enabled_tools") is not None:
            names &= set(cfg["_enabled_tools"])
        names -= set(cfg.get("_disabled_tools") or [])
        return await perform(YouTrack(session, names), args, manifest)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["read", "state", "schema", "children", "preflight", "comment", "complete", "finish-epic"])
    p.add_argument("issue")
    p.add_argument("--host", choices=["codex", "claude"], default=os.environ.get("PIPELINE_HOST", "claude"))
    p.add_argument("--root", default=os.environ.get("ROOT", os.getcwd()))
    p.add_argument("--manifest")
    p.add_argument("--file")
    p.add_argument("--state")
    p.add_argument("--receipt")
    p.add_argument("--base", default=os.environ.get("PIPELINE_BASE_BRANCH", "main"))
    p.add_argument("--timeout", type=int, default=int(os.environ.get("PIPELINE_YOUTRACK_TIMEOUT", "120")))
    args = p.parse_args()
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*" if args.action == "schema" else r"[A-Z][A-Z0-9_]*-[1-9][0-9]*", args.issue):
        p.error("expected a complete YouTrack issue ID (or a project key for schema)")
    required = {"state": ["manifest"], "complete": ["manifest", "state", "receipt"],
                "finish-epic": ["manifest"], "preflight": ["manifest"], "comment": ["file"]}.get(args.action, [])
    if any(not getattr(args, key) for key in required):
        p.error("missing required options: " + ", ".join("--" + key for key in required))
    logging.disable(logging.CRITICAL)
    try:
        result = asyncio.run(asyncio.wait_for(run(args), timeout=args.timeout))
        print(result if isinstance(result, str) else json.dumps(result))
    except Exception as exc:
        # Exception text from transports can contain URLs, headers, and command arguments.
        def safe_error(error):
            if isinstance(error, AdapterError):
                return str(error)
            for child in getattr(error, "exceptions", []):
                message = safe_error(child)
                if message:
                    return message
            return None
        print("youtrack adapter: " + (safe_error(exc) or f"{type(exc).__name__}; check the host MCP connection and authentication"), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
