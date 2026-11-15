"""Offline integration checks for host routing; no model or GitHub calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BUNDLE = Path(__file__).resolve().parents[1]
SCRIPTS = BUNDLE / "references/scripts"

CLI_STUB = r'''#!/usr/bin/env python3
import json, os, re, subprocess, sys, time
from pathlib import Path
name = Path(sys.argv[0]).name
prompt = sys.stdin.read()
record = {"cli": name, "args": sys.argv[1:], "prompt": prompt, "cwd": os.getcwd(),
          "env": {k: os.environ.get(k) for k in ["PIPELINE_HOST", "PIPELINE_SESSION_ID",
            "CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "PIPELINE_MODE"]}}
match = re.search(r'Target issue:\*\* #([A-Z0-9_-]+)', prompt)
if match:
    issue = match[1]
    child_env = dict(os.environ)
    child_env["CODEX_THREAD_ID" if name == "codex" else "CLAUDE_CODE_SESSION_ID"] = "native-child"
    state_args = ["phase=done"]
    if "-" in issue:
        state_args += ["prNumber=" + issue.rsplit("-", 1)[1], "branch=feat/" + issue.lower()]
    subprocess.run(["bash", os.environ["TEST_STATE_SCRIPT"], "set", *state_args],
                   env=child_env, check=True)
    probe = subprocess.check_output(["bash", "-c",
        'source "$PIPELINE_SKILL_DIR/references/scripts/pipeline-lib.sh"; pipeline_init; '
        'printf "%s/%s" "$PIPELINE_HOST" "$PIPELINE_REVIEWER_CLI"'], env=child_env, text=True)
    record["roles"] = probe
    record["issue"] = issue
with open(os.environ["TEST_CALLS"], "a") as f:
    f.write(json.dumps(record) + "\n")
if match:
    mode = os.environ.get("TEST_SUBTASK_MODE", "done")
    if mode == "blocked":
        print(f"SUBTASK_BLOCKED: #{issue} — test blocker")
    elif mode == "done":
        path = Path(os.environ["TEST_TRACKER"])
        data = json.loads(path.read_text())
        if "-" not in issue: data["states"][issue] = "CLOSED"
        path.write_text(json.dumps(data))
        print(f"SUBTASK_DONE: #{issue}")
else:
    time.sleep(float(os.environ.get("TEST_REVIEW_SLEEP", "0")))
    print("PIPELINE_REVIEW_DONE event=APPROVE")
sys.exit(int(os.environ.get("TEST_CLI_EXIT", "0")))
'''

GH_STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
path = Path(os.environ["TEST_TRACKER"])
data = json.loads(path.read_text())
if args[:2] == ["repo", "view"]:
    print(os.environ.get("TEST_REPOSITORY", "acme/app")); sys.exit(0)
if args[:2] == ["pr", "view"]:
    issue = "PROJ-" + args[2]
    print(json.dumps({"state": os.environ.get("TEST_PR_STATE", "MERGED"),
        "mergedAt": "2026-10-31", "url": f"https://github.com/acme/app/pull/{args[2]}",
        "headRefName": "feat/" + issue.lower(), "baseRefName": os.environ.get("TEST_PR_BASE", "main"),
        "body": os.environ.get("TEST_PR_BODY", "Refs " + issue), "mergeCommit": {"oid": "a" * 40}}))
    sys.exit(0)
if args[:2] == ["api", "user"]:
    login = os.environ.get("TEST_GH_LOGIN", "")
    if login: print(login)
    sys.exit(0 if login else 1)
if args[:2] == ["auth", "status"]:
    sys.exit(0)
if args[0] != "issue":
    sys.exit(2)
action, issue = args[1:3]
if action == "view":
    if "state" in args: print(data["states"].get(issue, "UNKNOWN"))
    elif "body" in args: print(data["body"])
elif action == "comment":
    data["comments"].append(args)
elif action == "edit":
    data["body"] = sys.stdin.read()
elif action == "close":
    data["states"][issue] = "CLOSED"
else:
    sys.exit(2)
path.write_text(json.dumps(data))
'''


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pipeline test ")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.repo = self.base / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test",
                        "-c", "user.email=test@example.com", "commit", "-qm", "init",
                        "--allow-empty"], check=True)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for name, code in [("codex", CLI_STUB), ("claude", CLI_STUB), ("gh", GH_STUB)]:
            p = self.bin / name
            p.write_text(code)
            p.chmod(0o755)
        self.calls = self.base / "calls.jsonl"
        self.tracker = self.base / "tracker.json"
        self.tracker.write_text(json.dumps({"states": {"44": "OPEN", "48": "OPEN", "49": "OPEN"},
                                           "body": "- [ ] **#48** first\n- [ ] #49 second", "comments": []}))
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith(("PIPELINE_", "REVIEWER_", "CODEX_", "CLAUDE_")) or key == "CLAUDECODE":
                self.env.pop(key)
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TEST_CALLS=str(self.calls), TEST_TRACKER=str(self.tracker),
                        TEST_STATE_SCRIPT=str(SCRIPTS / "state.sh"))

    def run_script(self, script, *args, env=None, cwd=None, input=None, ok=True):
        result = subprocess.run(["bash", str(script), *map(str, args)], cwd=cwd or self.repo,
                                env={**self.env, **(env or {})}, input=input, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def config(self, text):
        d = self.repo / ".claude"
        d.mkdir(exist_ok=True)
        (d / "pipeline.config.sh").write_text(text)

    def records(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def review(self, env=None, ok=True):
        prompt = self.base / "review prompt.md"
        prompt.write_text("review this prompt")
        return self.run_script(SCRIPTS / "run-reviewer.sh", self.repo, prompt, env=env, ok=ok)

    def manifest(self, host="codex", **extra):
        p = self.base / "manifest.json"
        p.write_text(json.dumps({"epic": 44, "order": [48, 49], "deps": {"49": [48]},
                                 "host": host, "model": None, **extra}))
        return p

    def test_native_host_detection_and_reviewer_isolation(self):
        for host, native, reviewer in [("codex", "CODEX_THREAD_ID", "claude"),
                                        ("claude", "CLAUDE_CODE_SESSION_ID", "codex")]:
            with self.subTest(host=host):
                self.review({native: "parent-session", "PIPELINE_SESSION_ID": "parent-override"})
                r = self.records()[-1]
                self.assertEqual(r["cli"], reviewer)
                self.assertEqual(r["prompt"], "review this prompt")
                self.assertEqual(r["cwd"], str(self.repo))
                for key in [native, "PIPELINE_SESSION_ID", "CLAUDECODE"]:
                    self.assertIsNone(r["env"][key])

    def test_model_pins_are_provider_specific(self):
        self.config('REVIEWER_MODEL="legacy-codex-pin"\nCLAUDE_REVIEWER_MODEL="claude-pin"\n')
        self.review({"PIPELINE_HOST": "codex"})
        self.assertIn("claude-pin", self.records()[-1]["args"])
        self.assertNotIn("legacy-codex-pin", self.records()[-1]["args"])
        self.review({"PIPELINE_HOST": "claude"})
        self.assertIn("legacy-codex-pin", self.records()[-1]["args"])
        self.config('CODEX_REVIEWER_MODEL="new-codex-pin"\nREVIEWER_MODEL="legacy-pin"\n')
        self.review({"PIPELINE_HOST": "claude"})
        self.assertIn("new-codex-pin", self.records()[-1]["args"])

    def test_repo_reviewer_override_wins(self):
        self.config('reviewer_invoke() { printf "custom:%s" "$(cat "$1")"; }\n')
        r = self.review({"PIPELINE_HOST": "codex"})
        self.assertIn("custom:review this prompt", r.stdout)
        self.assertEqual(self.records(), [])

    def test_explicit_reviewer_selection_wins(self):
        self.config('PIPELINE_REVIEWER="codex"\n')
        self.review({"PIPELINE_HOST": "codex"})
        self.assertEqual(self.records()[-1]["cli"], "codex")

    def test_epic_preserves_explicit_reviewer_selection(self):
        self.run_script(SCRIPTS / "run-epic.sh", self.manifest(order=[48], deps={}),
                        env={"PIPELINE_REVIEWER": "codex"})
        self.assertEqual(self.records()[0]["roles"], "codex/codex")

    def test_legacy_manifest_uses_detected_host(self):
        manifest = self.manifest(order=[48], deps={})
        data = json.loads(manifest.read_text()); del data["host"]
        manifest.write_text(json.dumps(data))
        self.run_script(SCRIPTS / "run-epic.sh", manifest, env={"CODEX_THREAD_ID": "parent"})
        self.assertEqual(self.records()[0]["roles"], "codex/claude")

    def test_reviewer_failure_and_timeout_propagate(self):
        r = self.review({"PIPELINE_HOST": "codex", "TEST_CLI_EXIT": "7"}, ok=False)
        self.assertEqual(r.returncode, 7)
        self.config('REVIEWER_TIMEOUT="1"\n')
        r = self.review({"PIPELINE_HOST": "claude", "TEST_REVIEW_SLEEP": "5"}, ok=False)
        self.assertEqual(r.returncode, 124)

    def test_state_native_ids_override_and_worktree(self):
        wt = self.base / "worktree"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-qb", "feature", str(wt)],
                       check=True, stdout=subprocess.DEVNULL)
        for host, native in [("codex", "CODEX_THREAD_ID"), ("claude", "CLAUDE_CODE_SESSION_ID")]:
            self.run_script(SCRIPTS / "state.sh", "set", "phase=planning", env={native: host})
            r = self.run_script(SCRIPTS / "state.sh", "file", cwd=wt, env={native: host})
            self.assertEqual(Path(r.stdout.strip()), self.repo / f".claude/dev-pipeline/sessions/{host}/state.json")
            r = self.run_script(SCRIPTS / "state.sh", "file", env={native: host, "PIPELINE_SESSION_ID": "driver-id"})
            self.assertIn("/driver-id/state.json", r.stdout)

    def test_missing_and_unsafe_session_ids_fail(self):
        for env in [{"PIPELINE_HOST": "codex"}, {"PIPELINE_SESSION_ID": "../escape"},
                    {"PIPELINE_SESSION_ID": ".."}, {"PIPELINE_SESSION_ID": "bad\\id"}]:
            self.assertEqual(self.run_script(SCRIPTS / "state.sh", "file", env=env, ok=False).returncode, 2)

    def test_claude_hook_uses_driver_state(self):
        plan = self.repo / "docs/plans/plan.md"
        plan.parent.mkdir(parents=True)
        plan.write_text("plan")
        self.run_script(SCRIPTS / "record-plan.sh", input=json.dumps({"session_id": "native-child",
            "cwd": str(self.repo), "tool_input": {"file_path": str(plan)}}),
            env={"PIPELINE_SESSION_ID": "driver-id"})
        r = self.run_script(SCRIPTS / "state.sh", "get", "planPath", env={"PIPELINE_SESSION_ID": "driver-id"})
        self.assertEqual(r.stdout.strip(), "docs/plans/plan.md")
        self.assertFalse((self.repo / ".claude/dev-pipeline/sessions/native-child").exists())

    def test_epic_routes_both_hosts_and_resumes(self):
        for host in ["codex", "claude"]:
            with self.subTest(host=host):
                data = json.loads(self.tracker.read_text())
                data["states"] = {"44": "OPEN", "48": "OPEN", "49": "OPEN"}
                self.tracker.write_text(json.dumps(data))
                manifest = self.manifest(host=host, model=f"{host}-model")
                before = len(self.records())
                self.run_script(SCRIPTS / "run-epic.sh", manifest,
                    env={"CODEX_THREAD_ID": "parent", "CLAUDE_CODE_SESSION_ID": "parent", "CLAUDECODE": "1"})
                records = self.records()[before:]
                self.assertEqual([r["issue"] for r in records], ["48", "49"])
                ids = []
                for r in records:
                    self.assertEqual(r["cli"], host)
                    self.assertEqual(r["roles"], f'{host}/{"claude" if host == "codex" else "codex"}')
                    self.assertIn(f"{host}-model", r["args"])
                    self.assertEqual(r["env"]["PIPELINE_MODE"], "auto")
                    for key in ["CODEX_THREAD_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDECODE"]:
                        self.assertIsNone(r["env"][key])
                    sid = r["env"]["PIPELINE_SESSION_ID"]
                    ids.append(sid)
                    self.assertTrue((self.repo / f".claude/dev-pipeline/sessions/{sid}/state.json").exists())
                self.assertEqual(len(set(ids)), 2)
                self.run_script(SCRIPTS / "run-epic.sh", manifest)
                self.assertEqual(len(self.records()), before + 2)
                self.assertEqual(json.loads(self.tracker.read_text())["states"]["44"], "CLOSED")

    def test_epic_halts_without_starting_dependents(self):
        for mode in ["blocked", "open"]:
            with self.subTest(mode=mode):
                before = len(self.records())
                r = self.run_script(SCRIPTS / "run-epic.sh", self.manifest(),
                                    env={"TEST_SUBTASK_MODE": mode}, ok=False)
                self.assertEqual(r.returncode, 1)
                self.assertEqual([r["issue"] for r in self.records()[before:]], ["48"])
                self.assertEqual(json.loads(self.tracker.read_text())["states"]["49"], "OPEN")

    def test_epic_dependency_guard_and_manifest_validation(self):
        r = self.run_script(SCRIPTS / "run-epic.sh", self.manifest(order=[49]), ok=False)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.records(), [])
        for extra in [{"epic": "PROJ-500"}, {"order": ["PROJ-501"]},
                      {"host": "invalid"}, {"model": []}, {"deps": {"49": [True]}}]:
            r = self.run_script(SCRIPTS / "run-epic.sh", self.manifest(**extra), ok=False)
            self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(self.records(), [])

    def test_epic_runs_only_for_a_listed_merger(self):
        self.config('PIPELINE_MERGERS="alice carol"\n')
        # Someone not on the list, and a failed `gh` lookup, are both refused before any session starts.
        for login in ["bob", ""]:
            with self.subTest(login=login):
                r = self.run_script(SCRIPTS / "run-epic.sh", self.manifest(order=[48], deps={}),
                                    env={"TEST_GH_LOGIN": login}, ok=False)
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn("only alice carol may merge", r.stderr)
        self.assertEqual(self.records(), [])
        self.run_script(SCRIPTS / "run-epic.sh", self.manifest(order=[48], deps={}),
                        env={"TEST_GH_LOGIN": "carol"})
        self.assertEqual([r["issue"] for r in self.records()], ["48"])

    def test_cleanup_without_args_reads_state_for_every_session_kind(self):
        sessions = [{"PIPELINE_SESSION_ID": "driver-id"}, {"CODEX_THREAD_ID": "codex-thread"},
                    {"CLAUDE_CODE_SESSION_ID": "claude-session"}]
        for i, env in enumerate(sessions):
            with self.subTest(env=env):
                branch, wt = f"feat/cleanup-{i}", self.base / f"wt-{i}"
                subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-qb", branch, str(wt)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.run_script(SCRIPTS / "state.sh", "set", f"branch={branch}", f"worktree={wt}", env=env)
                r = self.run_script(SCRIPTS / "cleanup-worktree.sh", env=env)
                self.assertFalse(wt.exists(), r.stdout + r.stderr)
                self.assertIn(f"deleted local branch: {branch}", r.stdout)

    def test_codex_install_idempotent_and_non_destructive(self):
        dest = self.base / "skills"
        env = {"CODEX_SKILLS_DIR": str(dest)}
        self.run_script(BUNDLE / "install.sh", "codex", env=env)
        self.run_script(BUNDLE / "install.sh", "codex", env=env)
        link = dest / "dev-pipeline"
        self.assertEqual(link.resolve(), BUNDLE)
        link.unlink()
        link.mkdir()
        sentinel = link / "keep"
        sentinel.write_text("untouched")
        self.assertNotEqual(self.run_script(BUNDLE / "install.sh", "codex", env=env, ok=False).returncode, 0)
        self.assertEqual(sentinel.read_text(), "untouched")

    def test_global_install_and_repo_init_preserve_overrides(self):
        dest = self.base / "claude skills"
        self.run_script(BUNDLE / "install.sh", "global", env={"CLAUDE_SKILLS_DIR": str(dest)})
        installed = dest / "dev-pipeline"
        self.assertEqual((installed / "SKILL.md").read_text(), (BUNDLE / "SKILL.md").read_text())
        self.assertFalse(list(installed.rglob("__pycache__")))
        self.config('REVIEWER_TIMEOUT="12"\n')
        settings = self.repo / ".claude/settings.json"
        settings.write_text(json.dumps({"permissions": {"allow": ["test"]}}))
        for _ in range(2):
            self.run_script(installed / "install.sh", "init")
        self.assertEqual((self.repo / ".claude/pipeline.config.sh").read_text(), 'REVIEWER_TIMEOUT="12"\n')
        data = json.loads(settings.read_text())
        self.assertEqual(data["permissions"], {"allow": ["test"]})
        self.assertEqual(len(data["hooks"]["PostToolUse"]), 1)
        self.assertEqual((self.repo / ".gitignore").read_text().count(".claude/dev-pipeline/"), 1)


if __name__ == "__main__":
    unittest.main()
