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
if args[0] == "export":
    print("Exporting session: " + args[1])
    print(os.environ.get("FAKE_EXPORT", "{}"))
    sys.exit(0)
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
if mode == "tools":
    for tool, status in [("webfetch", "completed"), ("bash", "error")]:
        print(json.dumps({"type": "tool_use", "sessionID": session, "part": {
            "tool": tool, "state": {"status": status, "input": {"password": "private"},
                                   "output": "secret HTML", "error": "private error"}}}))
if mode == "denied":
    print(json.dumps({"type": "tool_use", "sessionID": session, "part": {"tool": "bash", "state": {
        "status": "error", "error": "The user rejected permission to use this specific tool call."}}}))
    print(json.dumps({"type": "text", "sessionID": session, "part": {"text": "Let me execute."}}))
    print(json.dumps({"type": "step_finish", "sessionID": session, "part": {"reason": "tool-calls", "tokens": {}}}))
    sys.exit(0)
if mode == "event-error":
    print(json.dumps({"type": "error", "error": {"data": {"message": "Model failed"}}}))
for step in range(steps):
    answer = json.dumps({"status": "completed", "reason": "The requested result is supplied."}) if agent == "task-review" else f"{agent} answer {step}"
    print(json.dumps({"type": "text", "sessionID": session, "part": {"text": answer}}))
    print(json.dumps({"type": "step_finish", "sessionID": session, "part": {"tokens": {
        "total": 1000 + step, "input": 900, "output": 80, "reasoning": 20, "cache": {"read": 5, "write": 0}}}}))
    sys.stdout.flush()
    if mode == "tokens":
        time.sleep(0.2)
'''


def assistant(text, finish="stop", agent="build", *parts):
    return {"info": {"role": "assistant", "agent": agent, "finish": finish},
            "parts": [{"type": "text", "text": text}, *parts]}


CONTINUE = {"info": {"role": "user"}, "parts": [{"type": "text", "text": "Continue", "synthetic": True}]}
ANSWER_THEN_COMPACTION = [
    {"info": {"role": "user"}, "parts": [{"type": "text", "text": "How many rides?"}]},
    assistant("There are 40 rides."),
    {"info": {"role": "user"}, "parts": [{"type": "compaction", "auto": True}]},
    assistant("## Objective", agent="compaction"),
    CONTINUE,
    assistant("Which park do you mean?"),
]


class SettledAnswerTest(unittest.TestCase):
    def test_returns_the_answer_from_before_the_compaction(self):
        self.assertEqual(runner.settled_answer(ANSWER_THEN_COMPACTION), "There are 40 rides.")

    def test_ignores_sessions_without_a_compaction(self):
        self.assertIsNone(runner.settled_answer(ANSWER_THEN_COMPACTION[:2]))

    def test_keeps_the_last_reply_when_the_agent_went_back_to_work(self):
        worked = assistant("Done after more work.", "stop", "build", {"type": "tool", "tool": "bash"})
        self.assertIsNone(runner.settled_answer([*ANSWER_THEN_COMPACTION[:5], worked]))

    def test_keeps_the_last_reply_when_the_compaction_interrupted_the_work(self):
        interrupted = [assistant("Fetching pages.", "tool-calls"), *ANSWER_THEN_COMPACTION[2:]]
        self.assertIsNone(runner.settled_answer(interrupted))

    def test_keeps_the_reply_to_a_new_request_after_the_compaction(self):
        question = {"info": {"role": "user"}, "parts": [{"type": "text", "text": "And in Ferrari Land?"}]}
        self.assertIsNone(runner.settled_answer([*ANSWER_THEN_COMPACTION, question, assistant("16.")]))


def timed(message, created, completed):
    message["info"]["time"] = {"created": created, "completed": completed}
    return message


def tool(name, status="completed", start=0, end=0, **state):
    return {"type": "tool", "tool": name, "state": {"status": status, "time": {"start": start, "end": end}, **state}}


class SessionStatsTest(unittest.TestCase):
    config = None

    def stats(self, sessions, since=0):
        with unittest.mock.patch.object(runner, "export_session", lambda _, session: sessions.get(session, [])):
            return runner.session_stats(self.config, "main", since)

    def test_counts_a_run_with_its_subagents_and_no_content(self):
        page = {"input": {"url": "https://secret.example/private"}, "metadata": {"truncated": True}}
        first = assistant("private answer", "tool-calls", "build",
                          tool("webfetch", start=1_000, end=3_000, **page),
                          tool("webfetch", start=3_000, end=4_000, **page),
                          tool("webfetch", "error", error="StatusCode: non 2xx status code (404 GET https://x)"),
                          tool("webfetch", "error", error="StatusCode: non 2xx status code (403 GET https://y)"),
                          tool("task", start=4_000, end=9_000, metadata={"sessionId": "child"}))
        first["info"]["tokens"] = {"total": 500, "input": 300, "output": 40, "reasoning": 10, "cache": {"read": 150}}
        compaction = assistant("summary", agent="compaction")
        compaction["info"]["tokens"] = {"total": 100, "input": 80, "output": 20, "cache": {"read": 0}}
        child = assistant("child notes", "stop", "explore")
        child["info"]["tokens"] = {"total": 900, "input": 700, "output": 5, "cache": {"read": 0}}
        stats = self.stats({"main": [timed(first, 1_000, 21_000), timed(compaction, 22_000, 25_000),
                                     timed(assistant("done"), 26_000, 28_000)],
                            "child": [timed(child, 4_000, 9_000)]})
        self.assertEqual(stats, {
            "steps": 3, "compactions": 1, "compaction_seconds": 3, "model_seconds": 19, "tool_seconds": 3,
            "tokens_read": 1080, "tokens_cached": 150, "tokens_generated": 75, "largest_context": 900,
            "tool_calls": 5, "tool_errors": 2, "pages_not_found": 1, "pages_forbidden": 1,
            "truncated_outputs": 2, "repeated_fetches": 1, "subagents": 1, "ended": "stop"})
        self.assertNotIn("secret", json.dumps(stats))
        self.assertNotIn("private", json.dumps(stats))

    def test_counts_only_this_run_of_a_continued_session(self):
        old, new = timed(assistant("old"), 1_000, 2_000), timed(assistant("new"), 5_000, 6_000)
        self.assertEqual(self.stats({"main": [old, new]}, since=4_000)["steps"], 1)

    def test_marks_a_run_that_was_cut_off(self):
        self.assertEqual(self.stats({"main": [timed(assistant("working", None), 1_000, 0)]})["ended"], "interrupted")

    def test_has_nothing_to_report_without_a_session(self):
        self.assertIsNone(self.stats({}))


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
                                    opencode=str(script), max_minutes=1, max_tokens=10_000,
                                    auto_model=False)
        self.env = {"FAKE_LOG": str(self.log)}
        self.previous = {key: os.environ.get(key) for key in ("FAKE_LOG", "FAKE_MODE", "FAKE_EXPORT")}
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
        self.assertEqual(config.max_tokens, 500_000)
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
        self.assertEqual(call["config"]["provider"], {"ollama": {"models": {"qwen3-coder:30b": {
            "limit": {"context": 32768, "output": 8192}}}}})
        self.assertEqual(call["config"]["agent"]["task-review"]["tools"], {"*": False})
        self.assertNotIn("--auto", call["args"])

    def test_keeps_the_answer_a_compaction_replaced(self):
        os.environ["FAKE_EXPORT"] = json.dumps({"messages": ANSWER_THEN_COMPACTION})
        self.assertEqual(self.run_once().answer, "There are 40 rides.")

    def test_reads_an_export_larger_than_a_pipe_buffer(self):
        padding = assistant("x" * 100_000, "tool-calls")
        os.environ["FAKE_EXPORT"] = json.dumps({"messages": [padding, *ANSWER_THEN_COMPACTION]})
        self.assertEqual(self.run_once().answer, "There are 40 rides.")

    def test_keeps_the_streamed_answer_when_the_session_cannot_be_exported(self):
        os.environ["FAKE_EXPORT"] = "not json"
        self.assertEqual(self.run_once().answer, "build answer 0")

    def test_marks_an_answer_it_had_to_recover(self):
        os.environ["FAKE_EXPORT"] = json.dumps({"messages": ANSWER_THEN_COMPACTION})
        self.assertTrue(self.run_once().recovered)

    def test_reports_a_denied_tool_instead_of_a_half_finished_reply(self):
        os.environ["FAKE_MODE"] = "denied"
        result = self.run_once()
        self.assertEqual(result.failure, "OpenCode denied permission to use bash, so the agent could not finish.")

    def test_reports_each_finished_step(self):
        seen = []
        self.run_once(on_progress=lambda run: seen.append(run.tokens_total))
        self.assertEqual(seen, [1000])

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

    def test_records_only_tool_names_and_states(self):
        os.environ["FAKE_MODE"] = "tools"
        result = self.run_once()
        self.assertEqual(result.activity, ["webfetch: completed", "bash: error"])
        self.assertNotIn("private", json.dumps(result.activity))
        self.assertNotIn("HTML", json.dumps(result.activity))

    def test_error_event_cannot_be_success_even_with_text_and_zero_exit(self):
        os.environ["FAKE_MODE"] = "event-error"
        result = self.run_once()
        self.assertEqual(result.exit, 0)
        self.assertEqual(result.failure, "OpenCode error: Model failed")


class ProcessTaskTest(RunnerTestCase):
    task = {"id": "t1", "title": "Fix the bug", "instructions": "The login fails.", "session_id": None}

    def finish(self, api):
        return next(args for name, args in api.calls if name == "agents_finish_task")

    def test_plans_then_carries_out_the_task_in_the_same_session(self):
        api = FakeApi(messages=[{"role": "user", "body": "Use the staging data"}])
        self.assertEqual(runner.process_task(api, self.config, self.task), "completed")
        plan, execute, review = self.calls()
        self.assertEqual(plan["args"][plan["args"].index("--agent") + 1], "plan")
        self.assertIn("The login fails.", plan["args"][-1])
        self.assertIn("- Use the staging data", plan["args"][-1])
        self.assertEqual(execute["args"][execute["args"].index("--session") + 1], "ses_plan")
        self.assertIn("carry out the plan", execute["args"][-1])
        report = self.finish(api)
        self.assertTrue(report["succeeded"])
        self.assertEqual(report["run_plan"], "plan answer 0")
        self.assertEqual(report["run_outcome"], "build answer 0")
        self.assertEqual((report["run_tokens_generated"], report["run_tokens_total"]), (300, 3000))
        self.assertEqual(report["run_session"], "ses_plan")
        self.assertEqual(json.loads(report["reply"])["answer"], "build answer 0")
        self.assertIsNone(report["failure"])

    def test_can_skip_planning(self):
        self.config.plan_first = False
        api = FakeApi()
        runner.process_task(api, self.config, self.task)
        call, review = self.calls()
        self.assertNotIn("--session", call["args"])
        self.assertIn("Carry out the task.", call["args"][-1])
        self.assertIsNone(self.finish(api)["run_plan"])

    def test_answers_new_messages_in_the_existing_session(self):
        api = FakeApi(messages=[{"role": "user", "body": "old"}, {"role": "agent", "body": "done"},
                                {"role": "user", "body": "Why?"}, {"role": "user", "body": "And tests?"}])
        runner.process_task(api, self.config, {**self.task, "session_id": "ses_7"})
        call, review = self.calls()
        self.assertIn("- Why?\n- And tests?", call["args"][-1])
        self.assertEqual(call["args"][call["args"].index("--session") + 1], "ses_7")
        report = self.finish(api)
        self.assertEqual(json.loads(report["reply"])["answer"], "build answer 0")
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
            return runner.Run(answer='{"status":"completed","reason":"ok"}', session="s",
                              tokens_total=4000, seconds=20)

        runner.process_task(FakeApi(), self.config, self.task, runner=fake)
        self.assertEqual(budgets, [(10_000, 60), (6000, 40), (2000, 20)])

    def test_rejects_an_unrelated_sitemap_and_keeps_history(self):
        def fake(config, prompt, **options):
            answer = ('{"status":"failed","reason":"A sitemap does not answer live availability."}'
                      if options["agent"] == "task-review" else "Tickets, hotels, parks")
            return runner.Run(answer=answer, session="s", activity=["webfetch: completed"])

        api = FakeApi()
        self.assertEqual(runner.process_task(api, self.config, self.task, runner=fake), "failed")
        report = self.finish(api)
        self.assertIn("sitemap", report["failure"])
        history = json.loads(report["reply"])
        self.assertEqual(history["phases"][1]["tools"], ["webfetch: completed"])
        self.assertEqual(history["answer"], "Tickets, hotels, parks")
        self.assertNotIn("stats", history)

    def test_reports_the_model_and_tokens_while_it_runs(self):
        def fake(config, prompt, **options):
            run = runner.Run(answer="done", session="s", tokens_generated=10, tokens_total=100)
            options["on_progress"](run)
            return run

        api = FakeApi()
        runner.process_task(api, self.config, self.task, runner=fake)
        reports = [args for name, args in api.calls if name == "agents_report_progress"]
        self.assertEqual(reports[0]["run_tokens_total"], 0)
        self.assertEqual(reports[0]["run_model"], self.config.model)
        self.assertEqual([report["run_tokens_total"] for report in reports[1:4]], [100, 100, 200])

    def test_a_failed_progress_report_does_not_stop_the_run(self):
        class Unreachable(FakeApi):
            def rpc(self, name, args):
                if name == "agents_report_progress":
                    raise runner.SupabaseError("function not found")
                return super().rpc(name, args)

        def fake(config, prompt, **options):
            answer = '{"status":"completed","reason":"ok"}' if options["agent"] == "task-review" else "done"
            return runner.Run(answer=answer, session="s")

        self.assertEqual(runner.process_task(Unreachable(), self.config, self.task, runner=fake), "completed")

    def test_keeps_the_counters_of_a_failed_run(self):
        def fake(config, prompt, **options):
            return runner.Run(session="s", stopped="time limit (30 min)", recovered=True)

        api = FakeApi()
        with unittest.mock.patch.object(runner, "session_stats", return_value={"compactions": 4}) as stats, \
                unittest.mock.patch.object(runner, "machine_name", return_value="Test Mac, 64 GB"):
            self.assertEqual(runner.process_task(api, self.config, self.task, runner=fake), "failed")
        self.assertEqual(stats.call_args.args[1], "s")
        self.assertEqual(json.loads(self.finish(api)["reply"])["stats"], {
            "compactions": 4, "answer_recovered": True, "machine": "Test Mac, 64 GB", "context_limit": 32768})

    def test_rejects_invalid_or_missing_review(self):
        for answer in ("ok", '{"status":"completed"}', '{"status":"completed","reason":""}'):
            self.assertIsNotNone(runner.review_failure(answer))

    def test_does_not_launch_more_work_after_budget_is_exhausted(self):
        calls = []
        def fake(config, prompt, **options):
            calls.append(options)
            return runner.Run(answer="plan", session="s", tokens_total=10_000)
        api = FakeApi()
        self.assertEqual(runner.process_task(api, self.config, self.task, runner=fake), "failed")
        self.assertEqual(len(calls), 1)

    def test_routes_research_to_general_and_code_to_coder(self):
        self.config.auto_model = True
        installed = ["ollama/qwen3.6:35b", "ollama/qwen3-coder:30b"]
        for category, selected in (("general", installed[0]), ("coding", installed[1])):
            calls = []
            def fake(config, prompt, **options):
                calls.append((config.model, options["agent"]))
                answer = (json.dumps({"category": category, "reason": "Chosen for this task"})
                          if options["agent"] == "task-router"
                          else '{"status":"completed","reason":"The task is answered."}')
                return runner.Run(answer=answer, session="s")
            api = FakeApi()
            self.assertEqual(runner.process_task(api, self.config, self.task, runner=fake,
                                                models=lambda _: installed), "completed")
            self.assertEqual(calls[1], (selected, "plan"))
            self.assertEqual(self.finish(api)["run_model"], selected)
            self.assertEqual(self.config.model, "ollama/qwen3-coder:30b")

    def test_fails_explicitly_if_discovery_or_routing_fails(self):
        self.config.auto_model = True
        api = FakeApi()
        self.assertEqual(runner.process_task(api, self.config, self.task,
                                            models=lambda _: []), "failed")
        self.assertIn("not installed", self.finish(api)["failure"])

    def test_single_model_skips_classifier(self):
        self.config.auto_model = True
        api = FakeApi()
        runner.process_task(api, self.config, self.task,
                            models=lambda _: ["ollama/qwen3-coder:30b"])
        self.assertEqual(len(self.calls()), 3)


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


class WebTest(RunnerTestCase):
    def test_reuses_server_and_opens_existing_workspace_session(self):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps([
            {"id": "ses_existing", "directory": str(self.workspace)}
        ]).encode()
        with unittest.mock.patch.object(runner, "web_ready", return_value=True), \
             unittest.mock.patch.object(runner.urllib.request, "urlopen", return_value=response), \
             unittest.mock.patch.object(runner.webbrowser, "open", return_value=True) as browser, \
             unittest.mock.patch.object(runner.subprocess, "Popen") as popen:
            self.assertIsNone(runner.start_web(self.config, threading.Event()))
            popen.assert_not_called()
            self.assertTrue(browser.call_args.args[0].endswith("/session/ses_existing"))

    def test_starts_server_in_workspace_and_stops_only_owned_process(self):
        process = unittest.mock.MagicMock()
        process.poll.return_value = None
        response = unittest.mock.MagicMock()
        response.__enter__.return_value.read.return_value = b"[]"
        with unittest.mock.patch.object(runner, "web_ready", side_effect=[False, True]), \
             unittest.mock.patch.object(runner.urllib.request, "urlopen", return_value=response), \
             unittest.mock.patch.object(runner.webbrowser, "open", return_value=True), \
             unittest.mock.patch.object(runner.subprocess, "Popen", return_value=process) as popen:
            self.assertIs(runner.start_web(self.config, threading.Event()), process)
            self.assertEqual(popen.call_args.kwargs["cwd"], self.workspace)
            self.assertIn("127.0.0.1", popen.call_args.args[0])
        runner.stop_web(process)
        process.terminate.assert_called_once()
        runner.stop_web(None)

    def test_cleans_up_server_when_readiness_fails(self):
        process = unittest.mock.MagicMock()
        process.poll.return_value = None
        with unittest.mock.patch.object(runner, "web_ready", side_effect=[False, RuntimeError("port conflict")]), \
             unittest.mock.patch.object(runner.subprocess, "Popen", return_value=process):
            with self.assertRaisesRegex(RuntimeError, "port conflict"):
                runner.start_web(self.config, threading.Event())
        process.terminate.assert_called_once()


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
