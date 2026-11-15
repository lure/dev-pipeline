import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import test_pipeline as pipeline
from test_pipeline import BUNDLE, SCRIPTS

spec = importlib.util.spec_from_file_location("youtrack_mcp", SCRIPTS / "youtrack_mcp.py")
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class YouTrackUnitTest(unittest.TestCase):
    def test_resolution_requires_the_configured_success_state(self):
        fields = {"Stage": "Done"}
        for stage, resolved, expected in [("Done", 1, "CLOSED"), ("To Do", None, "OPEN"),
                ("Nixed", 1, "OTHER_RESOLVED"), ("Done", None, "UNKNOWN")]:
            self.assertEqual(adapter.issue_state({"customFields": {"Stage": stage}, "resolvedAt": resolved}, fields), expected)

    def test_mcp_error_and_failed_fields_are_not_success(self):
        for is_error, value in [(True, {}), (False, {"failedToUpdateFields": ["Stage"]})]:
            with self.assertRaises(adapter.AdapterError):
                adapter.decode_result(SimpleNamespace(isError=is_error, structuredContent=value))

    def test_codex_loader_preserves_tool_restrictions(self):
        result = SimpleNamespace(returncode=0, stdout=json.dumps({"enabled": True,
            "transport": {"command": "fake", "args": []}, "disabled_tools": ["update_issue"]}))
        with patch.object(adapter.subprocess, "run", return_value=result) as invoke:
            cfg = adapter.load_connection("codex", "/repo")
        self.assertEqual(cfg["_disabled_tools"], ["update_issue"])
        self.assertEqual(invoke.call_args.kwargs["cwd"], "/repo")

    def test_claude_local_shared_user_precedence(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve(); home = root / "home"; home.mkdir()
            (home / ".claude.json").write_text(json.dumps({"mcpServers": {"youtrack": {"command": "user"}}}))
            self.assertEqual(adapter.load_connection("claude", root, user_home=home)["command"], "user")
            (root / ".mcp.json").write_text(json.dumps({"mcpServers": {"youtrack": {"command": "shared"}}}))
            self.assertEqual(adapter.load_connection("claude", root, user_home=home)["command"], "shared")
            (home / ".claude.json").write_text(json.dumps({"projects": {str(root): {"mcpServers": {"youtrack": {"command": "local"}}}}}))
            self.assertEqual(adapter.load_connection("claude", root, user_home=home)["command"], "local")


@unittest.skipUnless(shutil.which("uv"), "YouTrack integration requires uv and the cached MCP SDK")
class YouTrackIntegrationTest(unittest.TestCase):
    setUp = pipeline.PipelineTest.setUp
    run_script = pipeline.PipelineTest.run_script
    records = pipeline.PipelineTest.records
    def yt_setup(self, host="codex", **changes):
        shutil.rmtree(self.repo / ".claude/dev-pipeline/epics/epic-PROJ-500", ignore_errors=True)
        data = {"states": {"PROJ-500": "OPEN", "PROJ-501": "OPEN", "PROJ-502": "OPEN"},
                "children": {"PROJ-500": ["PROJ-501", "PROJ-502"]}, "comments": [], **changes}
        self.tracker.write_text(json.dumps(data))
        config = self.base / "mcp.json"
        config.write_text(json.dumps({"mcpServers": {"youtrack": {"command": sys.executable,
            "args": [str(BUNDLE / "tests/fake_youtrack_mcp.py")]}}}))
        self.env.update(PIPELINE_YOUTRACK_MCP_CONFIG=str(config), UV_OFFLINE="1")
        manifest = self.base / "youtrack-manifest.json"
        manifest.write_text(json.dumps({"tracker": "youtrack", "epic": "PROJ-500", "host": host,
            "repository": "acme/app", "order": ["PROJ-501", "PROJ-502"],
            "deps": {"PROJ-502": ["PROJ-501"]}, "youtrack": {"doneFields": {"Stage": "Done"}}}))
        return manifest

    def test_yt_full_driver_both_hosts(self):
        for host in ["codex", "claude"]:
            with self.subTest(host=host):
                manifest = self.yt_setup(host)
                before = len(self.records())
                self.run_script(SCRIPTS / "run-epic.sh", manifest)
                records = self.records()[before:]
                self.assertEqual([r["issue"] for r in records], ["PROJ-501", "PROJ-502"])
                self.assertTrue(all(r["cli"] == host for r in records))
                data = json.loads(self.tracker.read_text())
                self.assertTrue(all(s == "CLOSED" for s in data["states"].values()))
                self.assertEqual([x["args"]["issueId"] for x in data["yt_calls"] if x["tool"] == "update_issue"],
                                 ["PROJ-501", "PROJ-502", "PROJ-500"])
                progress = self.run_script(SCRIPTS / "epic-progress.sh", "PROJ-500", ok=False)
                self.assertEqual(progress.returncode, 3)
                self.assertIn("COMPLETE", progress.stdout)

    def test_yt_retry_after_tracker_failure_does_not_reimplement(self):
        manifest = self.yt_setup(fail_update_once="PROJ-501")
        r = self.run_script(SCRIPTS / "run-epic.sh", manifest, ok=False)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertEqual(len(self.records()), 1)
        self.run_script(SCRIPTS / "run-epic.sh", manifest)
        self.assertEqual([r["issue"] for r in self.records()], ["PROJ-501", "PROJ-502"])
        data = json.loads(self.tracker.read_text())
        self.assertEqual(len(data["yt_comments"]["PROJ-501"]), 1)

    def test_yt_unmerged_wrong_base_or_wrong_issue_halts(self):
        for env in [{"TEST_PR_STATE": "OPEN"}, {"TEST_PR_BASE": "wrong"}, {"TEST_PR_BODY": "PROJ-5010"}]:
            with self.subTest(env=env):
                manifest = self.yt_setup()
                before = len(self.records())
                r = self.run_script(SCRIPTS / "run-epic.sh", manifest, env=env, ok=False)
                self.assertEqual(r.returncode, 1)
                self.assertEqual(len(self.records()), before + 1)
                self.assertEqual(json.loads(self.tracker.read_text())["states"]["PROJ-501"], "OPEN")

    def test_yt_repository_mismatch_fails_before_implementation(self):
        manifest = self.yt_setup()
        self.assertNotEqual(self.run_script(SCRIPTS / "run-epic.sh", manifest,
            env={"TEST_REPOSITORY": "different/repo"}, ok=False).returncode, 0)
        self.assertEqual(self.records(), [])

    def test_yt_new_open_child_keeps_epic_open(self):
        manifest = self.yt_setup(states={"PROJ-500": "OPEN", "PROJ-501": "OPEN", "PROJ-502": "OPEN", "PROJ-503": "OPEN"},
            children={"PROJ-500": ["PROJ-501", "PROJ-502", "PROJ-503"]})
        self.run_script(SCRIPTS / "run-epic.sh", manifest)
        self.assertEqual(json.loads(self.tracker.read_text())["states"]["PROJ-500"], "OPEN")

    def test_yt_child_discovery_paginates(self):
        ids = [f"PROJ-{i}" for i in range(100, 125)]
        self.yt_setup(children={"PROJ-500": ids})
        result = subprocess.run(["uv", "run", "--script", str(SCRIPTS / "youtrack_mcp.py"),
            "children", "PROJ-500", "--host", "claude", "--root", str(self.repo)],
            env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([x["id"] for x in json.loads(result.stdout)], ids)

    def test_yt_transport_stderr_does_not_leak_into_logs(self):
        self.yt_setup()
        Path(self.env["PIPELINE_YOUTRACK_MCP_CONFIG"]).write_text(json.dumps({"command": sys.executable,
            "args": ["-c", "import sys; sys.stderr.write('FAKE_TEST_SECRET'); sys.exit(1)"]}))
        result = subprocess.run(["uv", "run", "--script", str(SCRIPTS / "youtrack_mcp.py"),
            "read", "PROJ-500", "--timeout", "3"], env=self.env,
            capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("FAKE_TEST_SECRET", result.stdout + result.stderr)

    def test_yt_active_progress_uses_full_id(self):
        directory = self.repo / ".claude/dev-pipeline/epics/epic-PROJ-500"
        directory.mkdir(parents=True)
        sid = "11111111-1111-1111-1111-111111111111"
        (directory / "epic.log").write_text(f"[epic #PROJ-500] start — host: claude\n[epic #PROJ-500] spawn #PROJ-501 — isolated session (sid={sid})\n")
        self.run_script(SCRIPTS / "state.sh", "set", "phase=implementing", env={"PIPELINE_SESSION_ID": sid})
        result = self.run_script(SCRIPTS / "epic-progress.sh", "PROJ-500")
        self.assertIn("#PROJ-501 — implementing", result.stdout)

