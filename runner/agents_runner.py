#!/usr/bin/env python3
"""Work through the Agents task list with a local OpenCode agent, one task at a time.

The runner signs in to the shared Supabase project, takes the oldest pending task of the
workspaces its account can edit, lets OpenCode plan it and then carry it out inside the
configured workspace folder, and reports the plan, outcome, time and tokens back. With nothing
to do it sleeps and checks again every few minutes.

Usage: python3 runner/agents_runner.py [--config runner/config.toml] [--once]
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE / "config.toml"


@dataclasses.dataclass
class Config:
    supabase_url: str
    publishable_key: str
    email: str
    password: str
    workspace_dir: Path
    name: str = dataclasses.field(default_factory=socket.gethostname)
    workspace_id: str | None = None
    model: str = "ollama/qwen3-coder:30b"
    context: int = 32768
    output: int = 8192
    max_tokens: int = 150_000
    max_minutes: float = 30
    poll_minutes: float = 5
    plan_first: bool = True
    auto_approve: bool = False
    opencode: str = "opencode"


SECRET_FIELDS = {
    "supabase_url": ("AGENTS_SUPABASE_URL", "VITE_SUPABASE_URL"),
    "publishable_key": ("AGENTS_SUPABASE_PUBLISHABLE_KEY", "VITE_SUPABASE_PUBLISHABLE_KEY"),
    "email": ("AGENTS_EMAIL",),
    "password": ("AGENTS_PASSWORD",),
    "workspace_dir": ("AGENTS_WORKSPACE_DIR",),
}
SETTINGS = {"name": str, "workspace_id": str, "model": str, "context": int, "output": int,
            "max_tokens": int, "max_minutes": float, "poll_minutes": float, "plan_first": bool,
            "auto_approve": bool, "opencode": str}


def read_dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            key, sep, value = line.strip().partition("=")
            if sep and key and not key.startswith("#"):
                values[key.strip()] = value.strip().strip("'\"")
    return values


def load_config(path: Path, env: dict[str, str] | None = None, dotenv: Path | None = None) -> Config:
    """Settings come from the TOML file. Connection details and secrets may also come from the
    environment, which wins, or from the repository .env file the web app uses."""
    env = dict(os.environ if env is None else env)
    data: dict[str, Any] = tomllib.loads(path.read_text()) if path.is_file() else {}
    fallback = read_dotenv(dotenv or HERE.parent / ".env")

    values: dict[str, Any] = {}
    for key, names in SECRET_FIELDS.items():
        values[key] = (next((env[name] for name in names if env.get(name)), None)
                       or data.get(key)
                       or next((fallback[name] for name in names if fallback.get(name)), None))
    missing = [key for key, value in values.items() if not value]
    if missing:
        raise SystemExit(f"Missing configuration: {', '.join(missing)}. See runner/config.example.toml.")
    values["workspace_dir"] = Path(values["workspace_dir"]).expanduser().resolve()
    for key, kind in SETTINGS.items():
        if data.get(key) not in (None, ""):
            values[key] = kind(data[key])
    config = Config(**values)
    if not config.workspace_dir.is_dir():
        raise SystemExit(f"The workspace folder {config.workspace_dir} does not exist.")
    return config


class SupabaseError(RuntimeError):
    pass


class Supabase:
    """The few Supabase calls the runner needs, over plain HTTPS."""

    def __init__(self, url: str, key: str, email: str, password: str, opener=urllib.request.urlopen):
        self.url, self.key, self.email, self.password = url.rstrip("/"), key, email, password
        self.opener = opener
        self.access_token: str | None = None
        self.refresh_token: str | None = None
        self.expires_at = 0.0

    def _request(self, method: str, path: str, body: Any = None, token: str | None = None) -> Any:
        headers = {"apikey": self.key, "Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        try:
            with self.opener(request, timeout=60) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")
            try:
                parsed = json.loads(detail)
                detail = parsed.get("message") or parsed.get("msg") or parsed.get("error_description") or detail
            except ValueError:
                pass
            raise SupabaseError(f"{method} {path.split('?')[0]} failed ({error.code}): {detail}") from None
        return json.loads(raw) if raw else None

    def _store(self, session: dict[str, Any]) -> str:
        self.access_token = session["access_token"]
        self.refresh_token = session["refresh_token"]
        self.expires_at = time.time() + int(session.get("expires_in", 3600))
        return self.access_token

    def token(self) -> str:
        if self.access_token and time.time() < self.expires_at - 120:
            return self.access_token
        if self.refresh_token:
            try:
                return self._store(self._request("POST", "/auth/v1/token?grant_type=refresh_token",
                                                 {"refresh_token": self.refresh_token}))
            except SupabaseError:
                pass
        return self._store(self._request("POST", "/auth/v1/token?grant_type=password",
                                         {"email": self.email, "password": self.password}))

    def rpc(self, name: str, args: dict[str, Any]) -> Any:
        return self._request("POST", f"/rest/v1/rpc/{name}", args, self.token())

    def messages(self, task_id: str) -> list[dict[str, Any]]:
        query = f"task_id=eq.{task_id}&select=role,body,created_at&order=created_at.asc"
        return self._request("GET", f"/rest/v1/agent_task_messages?{query}", None, self.token()) or []


@dataclasses.dataclass
class Run:
    answer: str = ""
    session: str | None = None
    tokens_generated: int = 0
    tokens_total: int = 0
    context: int = 0
    seconds: float = 0
    exit: int = 0
    stopped: str | None = None
    log: list[str] = dataclasses.field(default_factory=list)

    @property
    def failure(self) -> str | None:
        if self.stopped:
            return f"Stopped: {self.stopped}."
        if self.exit:
            tail = "\n".join(self.log[-5:])
            return f"OpenCode exited with code {self.exit}." + (f"\n{tail}" if tail else "")
        if not self.answer:
            return "The agent returned no answer." + (f"\n{self.log[-1]}" if self.log else "")
        return None


def opencode_config(config: Config) -> dict[str, Any]:
    provider, _, model = config.model.partition("/")
    # Tells OpenCode the real context, so it compacts instead of being cut off.
    return {"provider": {provider: {"models": {model: {"limit": {"context": config.context,
                                                                   "output": config.output}}}}}}


def run_opencode(config: Config, prompt: str, *, title: str, agent: str, session: str | None,
                 token_budget: int, seconds_budget: float, stop_event: threading.Event | None = None,
                 popen: Callable[..., Any] = subprocess.Popen) -> Run:
    command = [config.opencode, "run", "--format", "json", "-m", config.model, "--agent", agent,
               "--title", title, "--dir", str(config.workspace_dir)]
    if session:
        command += ["--session", session]
    if config.auto_approve:
        command.append("--auto")
    command += ["--", prompt]
    # OpenCode also reads its working folder from PWD, not only from the process cwd.
    env = {**os.environ, "PWD": str(config.workspace_dir),
           "OPENCODE_CONFIG_CONTENT": json.dumps(opencode_config(config))}
    process = popen(command, cwd=config.workspace_dir, env=env, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    result = Run(session=session)
    lock = threading.Lock()

    def stop(reason: str) -> None:
        with lock:
            if result.stopped:
                return
            result.stopped = reason
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            process.terminate()

    timer = threading.Timer(max(seconds_budget, 1), stop, [f"time limit ({config.max_minutes:g} min)"])
    timer.daemon = True
    timer.start()
    finished = threading.Event()
    if stop_event:
        def watch() -> None:
            while not finished.is_set():
                if stop_event.wait(0.5):
                    stop("the runner was stopped")
                    return
        threading.Thread(target=watch, daemon=True).start()
    start = time.monotonic()
    texts: list[str] = []
    for line in process.stdout:
        try:
            event = json.loads(line)
        except ValueError:
            if line.strip():
                result.log.append(line.rstrip())
            continue
        if not isinstance(event, dict):
            continue
        result.session = event.get("sessionID") or result.session
        part = event.get("part") or {}
        if event.get("type") == "text":
            texts.append(part.get("text", ""))
        elif event.get("type") == "step_finish":
            used = part.get("tokens") or {}
            generated = int(used.get("output", 0)) + int(used.get("reasoning", 0))
            result.tokens_generated += generated
            result.tokens_total += int(used.get("input", 0)) + generated
            result.context = max(result.context, int(used.get("total", 0)))
            if result.tokens_total > token_budget:
                stop(f"token limit ({config.max_tokens:,})")
        elif event.get("type") == "error":
            error = event.get("error") or {}
            result.log.append(str((error.get("data") or {}).get("message") or error.get("name") or error))
    result.exit = process.wait()
    process.stdout.close()
    finished.set()
    timer.cancel()
    result.seconds = time.monotonic() - start
    # Earlier text parts are commentary between tool calls; the last one is the answer.
    result.answer = next((text.strip() for text in reversed(texts) if text.strip()), "")
    return result


PLAN_STEP = ("Plan this task before doing anything. Explore what you need to, but do not change any file "
             "yet. Reply with a short numbered plan and how you will know it is finished.")
EXECUTE_STEP = ("Carry out the task. When you are done, reply with a short summary of the outcome: what you "
                "did, what you found, and anything left for a person to check.")
CONTINUE_STEP = "Now carry out the plan. " + EXECUTE_STEP.removeprefix("Carry out the task. ")


def task_prompt(task: dict[str, Any], notes: list[str], step: str) -> str:
    extra = ("\n\nAdditional notes:\n" + "\n".join(f"- {note}" for note in notes)) if notes else ""
    return f"Task: {task['title']}\n\n{task['instructions']}{extra}\n\n{step}"


def unanswered(messages: list[dict[str, Any]]) -> list[str]:
    pending: list[str] = []
    for message in messages:
        if message["role"] == "agent":
            pending = []
        else:
            pending.append(message["body"])
    return pending


def process_task(api: Supabase, config: Config, task: dict[str, Any],
                 stop_event: threading.Event | None = None, runner: Callable[..., Run] = run_opencode) -> str:
    """Runs one claimed task and reports it. Returns the status it finished with."""
    messages = api.messages(task["id"])
    questions = unanswered(messages)
    tokens_left, seconds_left = config.max_tokens, config.max_minutes * 60
    title = f"agents: {task['title'][:60]}"
    report: dict[str, Any] = {"run_plan": None, "run_outcome": None, "reply": None}
    runs: list[Run] = []

    def step(prompt: str, agent: str, session: str | None) -> Run:
        run = runner(config, prompt, title=title, agent=agent, session=session, token_budget=tokens_left,
                     seconds_budget=seconds_left, stop_event=stop_event)
        runs.append(run)
        return run

    if task.get("session_id") and questions:
        print(f"  Answering {len(questions)} message(s) in session {task['session_id']}", flush=True)
        report["reply"] = step("\n\n".join(questions), "build", task["session_id"]).answer or None
    else:
        notes = [message["body"] for message in messages if message["role"] == "user"]
        session = None
        if config.plan_first:
            planned = step(task_prompt(task, notes, PLAN_STEP), "plan", None)
            report["run_plan"] = planned.answer or None
            session = planned.session
            tokens_left -= planned.tokens_total
            seconds_left -= planned.seconds
            print(f"  Planned: {planned.tokens_total:,} tokens, {planned.seconds:.0f}s", flush=True)
        if not runs or (not runs[0].failure and session):
            prompt = CONTINUE_STEP if session else task_prompt(task, notes, EXECUTE_STEP)
            report["run_outcome"] = step(prompt, "build", session).answer or None
        elif not runs[0].failure:
            runs[0].log.append("OpenCode did not report a session to continue.")
            runs[0].answer = ""

    failure = next((run.failure for run in runs if run.failure), None)
    session = next((run.session for run in reversed(runs) if run.session), task.get("session_id"))
    api.rpc("agents_finish_task", {
        "task": task["id"], "runner_name": config.name, "succeeded": failure is None,
        "run_seconds": round(sum(run.seconds for run in runs)),
        "run_tokens_generated": sum(run.tokens_generated for run in runs),
        "run_tokens_total": sum(run.tokens_total for run in runs),
        "run_context": max((run.context for run in runs), default=0),
        "run_model": config.model, "run_session": session, "failure": failure, **report,
    })
    return "failed" if failure else "completed"


def claim(api: Supabase, config: Config) -> dict[str, Any] | None:
    claimed = api.rpc("agents_claim_task", {"runner_name": config.name,
                                           "poll_seconds": round(config.poll_minutes * 60),
                                           "only_workspace": config.workspace_id})
    return claimed[0] if claimed else None


def work(api: Supabase, config: Config, stop_event: threading.Event, once: bool = False,
         process: Callable[..., str] = process_task) -> None:
    while not stop_event.is_set():
        try:
            task = claim(api, config)
        except (SupabaseError, urllib.error.URLError, OSError) as error:
            print(f"Could not check for tasks: {error}", flush=True)
            task = None
        if task:
            print(f"\nTask: {task['title']}", flush=True)
            try:
                print(f"  {process(api, config, task, stop_event)}", flush=True)
            except (SupabaseError, urllib.error.URLError, OSError) as error:
                print(f"  Could not finish the task: {error}", flush=True)
            continue
        if once:
            return
        print(f"No pending tasks. Checking again in {config.poll_minutes:g} min.", flush=True)
        stop_event.wait(config.poll_minutes * 60)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--once", action="store_true", help="work through the pending tasks, then exit")
    args = parser.parse_args(argv)
    config = load_config(args.config)
    api = Supabase(config.supabase_url, config.publishable_key, config.email, config.password)
    stop_event = threading.Event()

    def shutdown(*_: Any) -> None:
        if stop_event.is_set():
            sys.exit(130)
        print("\nStopping the current task (press Ctrl+C again to quit now).", flush=True)
        stop_event.set()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    print(f"Runner {config.name}: {config.model}, {config.context:,} context, "
          f"limits {config.max_tokens:,} tokens / {config.max_minutes:g} min, working in {config.workspace_dir}",
          flush=True)
    work(api, config, stop_event, once=args.once)


if __name__ == "__main__":
    main()
