import io
import json
import os
import sys
import tempfile
import threading
import unittest
import unittest.mock
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agents_runner as runner  # noqa: E402

FAKE_OPENCODE = r'''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
prompt = args[-1]
agent = args[args.index("--agent") + 1]
session = args[args.index("--session") + 1] if "--session" in args else "ses_" + agent
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "pwd": os.environ.get("PWD"), "cwd": os.getcwd(),
                          "config": json.loads(os.environ["OPENCODE_CONFIG_CONTENT"])}) + "\n")
mode = os.environ.get("FAKE_MODE", "")
if mode == "sleep":
    time.sleep(30)
if mode == "crash":
    print("model not found")
    sys.exit(2)
steps = 4 if mode == "tokens" else 1
for step in range(steps):
    print(json.dumps({"type": "text", "sessionID": session, "part": {"text": f"{agent} answer {step}"}}))
    print(json.dumps({"type": "step_finish", "sessionID": session, "part": {"tokens": {
        "total": 1000 + step, "input": 900, "output": 80, "reasoning": 20, "cache": {"read": 5, "write": 0}}}}))
    sys.stdout.flush()
    if mode == "tokens":
        time.sleep(0.2)
'''


class FakeApi:
    def __init__(self, messages=None, tasks=None):
        self.calls = []
        self._messages = messages or []
        self.tasks = list(tasks or [])

    def messages(self, task_id):
        return self._messages

    def rpc(self, name, args):
        self.calls.append((name, args))
        if name == "agents_claim_task":
            return [self.tasks.pop(0)] if self.tasks else []
        return None


class RunnerTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.workspace = self.dir / "workspace"
        self.workspace.mkdir()
        self.log = self.dir / "calls.jsonl"
        script = self.dir / "opencode"
        script.write_text(FAKE_OPENCODE)
        script.chmod(0o755)
        self.config = runner.Config(supabase_url="https://x.supabase.co", publishable_key="key", email="a@b.c",
                                    password="pw", workspace_dir=self.workspace, name="test-runner",
                                    opencode=str(script), max_minutes=1, max_tokens=10_000)
        self.env = {"FAKE_LOG": str(self.log)}
        self.previous = {key: os.environ.get(key) for key in ("FAKE_LOG", "FAKE_MODE")}
        os.environ.update(self.env)

    def tearDown(self):
        for key, value in self.previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []


class ConfigTest(RunnerTestCase):
    def write(self, text):
        path = self.dir / "config.toml"
        path.write_text(text)
        return path

    def test_reads_the_file_and_lets_the_environment_override_secrets(self):
        path = self.write(f'supabase_url = "https://file"\npublishable_key = "k"\nemail = "file@x"\n'
                          f'password = "file"\nworkspace_dir = "{self.workspace}"\ncontext = 65536\n'
                          f'max_minutes = 10\nplan_first = false\nworkspace_id = "w1"\n')
        config = runner.load_config(path, {"AGENTS_PASSWORD": "env"}, self.dir / "none.env")
        self.assertEqual(config.supabase_url, "https://file")
        self.assertEqual(config.password, "env")
        self.assertEqual(config.context, 65536)
        self.assertEqual(config.max_minutes, 10.0)
        self.assertFalse(config.plan_first)
        self.assertEqual(config.workspace_id, "w1")
        self.assertEqual(config.max_tokens, 150_000)
        self.assertEqual(config.poll_minutes, 5)

    def test_falls_back_to_the_web_app_env_file(self):
        dotenv = self.dir / ".env"
        dotenv.write_text("# comment\nVITE_SUPABASE_URL='https://dotenv'\nVITE_SUPABASE_PUBLISHABLE_KEY=pk\n")
        path = self.write(f'email = "a"\npassword = "b"\nworkspace_dir = "{self.workspace}"\n')
        config = runner.load_config(path, {}, dotenv)
        self.assertEqual((config.supabase_url, config.publishable_key), ("https://dotenv", "pk"))

    def test_reports_what_is_missing(self):
        with self.assertRaises(SystemExit) as raised:
            runner.load_config(self.dir / "absent.toml", {}, self.dir / "none.env")
        self.assertIn("supabase_url", str(raised.exception))
        self.assertIn("password", str(raised.exception))

    def test_requires_an_existing_workspace_folder(self):
        path = self.write('supabase_url = "u"\npublishable_key = "k"\nemail = "a"\npassword = "b"\n'
                          'workspace_dir = "/no/such/folder"\n')
        with self.assertRaises(SystemExit):
            runner.load_config(path, {}, self.dir / "none.env")


class OpenCodeTest(RunnerTestCase):
    def run_once(self, **overrides):
        options = {"title": "t", "agent": "build", "session": None, "token_budget": 10_000, "seconds_budget": 60}
        return runner.run_opencode(self.config, "do it", **{**options, **overrides})

    def test_collects_the_answer_session_and_tokens(self):
        result = self.run_once()
        self.assertIsNone(result.failure)
        self.assertEqual(result.answer, "build answer 0")
        self.assertEqual(result.session, "ses_build")
        self.assertEqual((result.tokens_generated, result.tokens_total, result.context), (100, 1000, 1000))
        call = self.calls()[0]
        self.assertEqual(call["pwd"], str(self.workspace))
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(self.workspace))
        self.assertEqual(call["config"], {"provider": {"ollama": {"models": {"qwen3-coder:30b": {
            "limit": {"context": 32768, "output": 8192}}}}}})
        self.assertNotIn("--auto", call["args"])

    def test_continues_a_session_and_can_auto_approve(self):
        self.config.auto_approve = True
        self.run_once(session="ses_old")
        args = self.calls()[0]["args"]
        self.assertEqual(args[args.index("--session") + 1], "ses_old")
        self.assertIn("--auto", args)

    def test_stops_at_the_token_limit(self):
        os.environ["FAKE_MODE"] = "tokens"
        result = self.run_once(token_budget=1500)
        self.assertIn("token limit", result.failure)
        self.assertLess(result.tokens_total, 4000)

    def test_stops_at_the_time_limit(self):
        os.environ["FAKE_MODE"] = "sleep"
        result = self.run_once(seconds_budget=1)
        self.assertIn("time limit", result.failure)
        self.assertLess(result.seconds, 10)

    def test_stops_when_the_runner_stops(self):
        os.environ["FAKE_MODE"] = "sleep"
        stop = threading.Event()
        threading.Timer(0.5, stop.set).start()
        result = self.run_once(stop_event=stop)
        self.assertEqual(result.failure, "Stopped: the runner was stopped.")

    def test_reports_a_crash_with_its_output(self):
        os.environ["FAKE_MODE"] = "crash"
        result = self.run_once()
        self.assertIn("exited with code 2", result.failure)
        self.assertIn("model not found", result.failure)


class ProcessTaskTest(RunnerTestCase):
    task = {"id": "t1", "title": "Fix the bug", "instructions": "The login fails.", "session_id": None}

    def finish(self, api):
        return next(args for name, args in api.calls if name == "agents_finish_task")

    def test_plans_then_carries_out_the_task_in_the_same_session(self):
        api = FakeApi(messages=[{"role": "user", "body": "Use the staging data"}])
        self.assertEqual(runner.process_task(api, self.config, self.task), "completed")
        plan, execute = self.calls()
        self.assertEqual(plan["args"][plan["args"].index("--agent") + 1], "plan")
        self.assertIn("The login fails.", plan["args"][-1])
        self.assertIn("- Use the staging data", plan["args"][-1])
        self.assertEqual(execute["args"][execute["args"].index("--session") + 1], "ses_plan")
        self.assertIn("carry out the plan", execute["args"][-1])
        report = self.finish(api)
        self.assertTrue(report["succeeded"])
        self.assertEqual(report["run_plan"], "plan answer 0")
        self.assertEqual(report["run_outcome"], "build answer 0")
        self.assertEqual((report["run_tokens_generated"], report["run_tokens_total"]), (200, 2000))
        self.assertEqual(report["run_session"], "ses_plan")
        self.assertIsNone(report["reply"])
        self.assertIsNone(report["failure"])

    def test_can_skip_planning(self):
        self.config.plan_first = False
        api = FakeApi()
        runner.process_task(api, self.config, self.task)
        (call,) = self.calls()
        self.assertNotIn("--session", call["args"])
        self.assertIn("Carry out the task.", call["args"][-1])
        self.assertIsNone(self.finish(api)["run_plan"])

    def test_answers_new_messages_in_the_existing_session(self):
        api = FakeApi(messages=[{"role": "user", "body": "old"}, {"role": "agent", "body": "done"},
                                {"role": "user", "body": "Why?"}, {"role": "user", "body": "And tests?"}])
        runner.process_task(api, self.config, {**self.task, "session_id": "ses_7"})
        (call,) = self.calls()
        self.assertEqual(call["args"][-1], "Why?\n\nAnd tests?")
        self.assertEqual(call["args"][call["args"].index("--session") + 1], "ses_7")
        report = self.finish(api)
        self.assertEqual(report["reply"], "build answer 0")
        self.assertIsNone(report["run_outcome"])

    def test_fails_without_carrying_out_a_failed_plan(self):
        os.environ["FAKE_MODE"] = "crash"
        api = FakeApi()
        self.assertEqual(runner.process_task(api, self.config, self.task), "failed")
        self.assertEqual(len(self.calls()), 1)
        report = self.finish(api)
        self.assertFalse(report["succeeded"])
        self.assertIn("exited with code 2", report["failure"])

    def test_shares_the_limits_between_plan_and_work(self):
        budgets = []

        def fake(config, prompt, **options):
            budgets.append((options["token_budget"], options["seconds_budget"]))
            return runner.Run(answer="ok", session="s", tokens_total=4000, seconds=20)

        runner.process_task(FakeApi(), self.config, self.task, runner=fake)
        self.assertEqual(budgets, [(10_000, 60), (6000, 40)])


class WorkTest(RunnerTestCase):
    def test_works_through_tasks_one_after_the_other(self):
        api = FakeApi(tasks=[{"id": "a", "title": "A"}, {"id": "b", "title": "B"}])
        done = []
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            runner.work(api, self.config, threading.Event(), once=True,
                        process=lambda api, config, task, stop: done.append(task["id"]) or "completed")
        self.assertEqual(done, ["a", "b"])
        claims = [args for name, args in api.calls if name == "agents_claim_task"]
        self.assertEqual(len(claims), 3)
        self.assertEqual(claims[0], {"runner_name": "test-runner", "poll_seconds": 300, "only_workspace": None})

    def test_keeps_going_when_supabase_is_unreachable(self):
        class Down(FakeApi):
            def rpc(self, name, args):
                raise urllib.error.URLError("offline")

        stop = threading.Event()
        self.config.poll_minutes = 0.001
        threading.Timer(0.3, stop.set).start()
        output = io.StringIO()
        with unittest.mock.patch("sys.stdout", output):
            runner.work(Down(), self.config, stop)
        self.assertIn("Could not check for tasks", output.getvalue())


class SupabaseTest(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.responses = []

    def opener(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return unittest.mock.MagicMock(**{"__enter__.return_value.read.return_value": json.dumps(response).encode()})

    def session(self, token):
        return {"access_token": token, "refresh_token": "r-" + token, "expires_in": 3600}

    def test_signs_in_once_and_calls_rpcs_with_the_token(self):
        api = runner.Supabase("https://x.supabase.co/", "pk", "a@b.c", "pw", opener=self.opener)
        self.responses = [self.session("t1"), [{"id": 1}], []]
        self.assertEqual(api.rpc("agents_claim_task", {"runner_name": "r"}), [{"id": 1}])
        self.assertEqual(api.messages("t1"), [])
        sign_in, rpc, messages = self.requests
        self.assertEqual(sign_in.full_url, "https://x.supabase.co/auth/v1/token?grant_type=password")
        self.assertEqual(json.loads(sign_in.data), {"email": "a@b.c", "password": "pw"})
        self.assertEqual(rpc.full_url, "https://x.supabase.co/rest/v1/rpc/agents_claim_task")
        self.assertEqual(rpc.get_header("Authorization"), "Bearer t1")
        self.assertEqual(rpc.get_header("Apikey"), "pk")
        self.assertIn("agent_task_messages?task_id=eq.t1", messages.full_url)

    def test_refreshes_an_expiring_session(self):
        api = runner.Supabase("https://x", "pk", "a", "b", opener=self.opener)
        self.responses = [self.session("t1"), self.session("t2")]
        api.token()
        api.expires_at = 0
        self.assertEqual(api.token(), "t2")
        self.assertIn("grant_type=refresh_token", self.requests[1].full_url)
        self.assertEqual(json.loads(self.requests[1].data), {"refresh_token": "r-t1"})

    def test_explains_errors(self):
        api = runner.Supabase("https://x", "pk", "a", "b", opener=self.opener)
        api.access_token, api.expires_at = "t", 10**12
        body = io.BytesIO(json.dumps({"message": "Task is not running on this runner"}).encode())
        self.responses = [urllib.error.HTTPError("https://x", 400, "Bad", {}, body)]
        with self.assertRaisesRegex(runner.SupabaseError, r"rpc/agents_finish_task failed \(400\): Task is not"):
            api.rpc("agents_finish_task", {})


if __name__ == "__main__":
    unittest.main()
