"""A local stdio MCP server for adapter integration tests; no network or credentials."""
import json
import os
from pathlib import Path
import sys

NAMES = ["get_issue", "get_issue_fields_schema", "search_issues", "get_issue_comments",
         "add_issue_comment", "update_issue"]


def tool(name, args):
    path = Path(os.environ["TEST_TRACKER"])
    data = json.loads(path.read_text())
    data.setdefault("yt_calls", []).append({"tool": name, "args": args})
    issue = args.get("issueId")
    if name == "get_issue":
        state = data["states"][issue]
        value = {"id": issue, "project": "PROJ", "url": f"https://youtrack.test/issue/{issue}",
                 "summary": issue, "description": "Test issue", "resolvedAt": 1 if state == "CLOSED" else None,
                 "customFields": {"Stage": "Done" if state == "CLOSED" else "To Do"}}
    elif name == "get_issue_fields_schema":
        value = {"properties": {"Stage": {"enum": ["To Do", "Done", "Nixed"]}}}
    elif name == "search_issues":
        ids = data["children"][args["query"].split(": ")[1]]
        offset, limit = args.get("offset", 0), args.get("limit", 10)
        value = {"issuesPage": [{"id": x} for x in ids[offset:offset + limit]], "hasNextPage": offset + limit < len(ids)}
    elif name == "get_issue_comments":
        comments = data.setdefault("yt_comments", {}).get(issue, [])
        offset, limit = args.get("offset", 0), args.get("limit", 10)
        value = comments[offset:offset + limit]
    elif name == "add_issue_comment":
        data.setdefault("yt_comments", {}).setdefault(issue, []).append({"text": args["text"]})
        value = {"id": issue}
    elif name == "update_issue":
        if data.pop("fail_update_once", None) == issue:
            path.write_text(json.dumps(data))
            return {"content": [{"type": "text", "text": "update unavailable"}], "isError": True}
        assert args["customFields"] == {"Stage": "Done"}
        data["states"][issue] = "CLOSED"
        value = {"id": issue}
    else:
        raise ValueError("unknown tool")
    path.write_text(json.dumps(data))
    return {"content": [{"type": "text", "text": json.dumps(value)}], "isError": False}


for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "test-youtrack", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": n, "description": n, "inputSchema": {"type": "object"}} for n in NAMES]}
    elif method == "tools/call":
        result = tool(request["params"]["name"], request["params"].get("arguments", {}))
    elif method == "ping":
        result = {}
    else:
        raise ValueError(method)
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
