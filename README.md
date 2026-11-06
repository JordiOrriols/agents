# Agents

A minimal task list for a local coding agent. Write down what needs doing on the web; an
agent on your computer ([OpenCode](https://opencode.ai) with an [Ollama](https://ollama.com)
model) picks the tasks up one after the other, plans each one, does it, and reports back.

- Pending tasks sit on top in the order the agent will take them; finished tasks go below.
- Each task keeps the instructions, the plan, the outcome, the time spent, the tokens used and
  an optional follow-up chat.
- Tasks are pending, running, completed or failed. Finished tasks can be run again.

It shares sign-in, workspaces, the header and the styling with Ladders, Planner, Pulse and
Shiplog through [`@jordiorriols/ui`](https://github.com/JordiOrriols/ui).

## Web app

```sh
cp .env.example .env   # VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY
npm install            # needs GITHUB_TOKEN with read:packages for @jordiorriols/ui
npm start              # http://localhost:5179
```

## Local runner

`runner/agents_runner.py` needs Python 3.11+ (standard library only), OpenCode and Ollama.

1. Pull the model and check OpenCode can use it:

   ```sh
   ollama pull qwen3-coder:30b
   opencode run -m ollama/qwen3-coder:30b "Say hi"
   ```

2. Create an account for the runner (sign up in the app), then share your workspace with it
   as an **Agents editor** from the workspace menu. The runner only sees tasks of the
   workspaces that account can edit.

3. Configure it:

   ```sh
   cp runner/config.example.toml runner/config.toml   # ignored by git
   ```

   Set `email`, `password` and `workspace_dir` (the folder the agent works in; it can hold
   several repositories). The Supabase URL and key are read from `.env`. Every connection
   setting can also come from the environment: `AGENTS_SUPABASE_URL`,
   `AGENTS_SUPABASE_PUBLISHABLE_KEY`, `AGENTS_EMAIL`, `AGENTS_PASSWORD`,
   `AGENTS_WORKSPACE_DIR`.

4. Run it:

   ```sh
   python3 runner/agents_runner.py          # keeps checking every poll_minutes
   python3 runner/agents_runner.py --once   # works through the queue, then exits
   ```

### What a run does

On startup the runner starts OpenCode's web UI at `http://127.0.0.1:4096` and opens
the configured workspace in your browser, where its local sessions are visible.
It reuses an existing healthy server and stops only its own server when exiting.
Web/browser errors are reported without stopping task processing. Set `web_enabled = false`
for a headless runner or change `web_port` if necessary. The server binds only to loopback.

1. Claims the oldest pending task. Only one runner can take a task.
2. Discovers installed Ollama models (`auto_model = true`). When both a general Qwen and a
   coder are installed, a tool-free OpenCode classifier chooses general for research/questions
   or coder for code changes. It does not download models. With only one suitable model, it uses
   the configured model; discovery or classification errors fail explicitly.
3. Asks OpenCode's read-only `plan` agent for a plan and acceptance criteria (`plan_first = true`).
4. Continues the same session with the `build` agent, repeating the original objective,
   current local date/time and evidence requirements to prevent context drift.
5. A separate, tool-free OpenCode session checks whether the answer addresses the request.
   Unrelated results, unverifiable claims, malformed verdicts and exhausted budgets fail rather
   than being treated as completed. This model review checks relevance, not independent factual
   truth: a model can still make mistakes.
6. Reports the time, tokens and result, including routing and review costs. The result is a
   Markdown report, rendered in the task, with the answer, its evidence and what is unverified.
   A compaction that follows the final answer does not replace it. The task also fails
   when OpenCode exits with an error, gives no answer, or reaches `max_tokens` or `max_minutes`.

While a task runs, the runner reports its model and tokens after every step and the app counts
its time; tokens used by subagents appear when the run finishes.

The task conversation saves a bounded **Run history** after each attempt: selected model and
selection reason, phase durations/token counts, tool names and completion/error states, final
answer and review, plus counters for comparing runs, models and computers later: steps,
compactions, tokens read and cached, largest context, model and tool time, failed, truncated and
repeated tool calls, subagents, how the run ended and the computer. They are stored in the run
message, also for failed runs, and can be queried with `body::jsonb -> 'stats'`.
It does not upload tool arguments, tool output, files or private reasoning.
It is not a live tool stream and existing runs are not imported retroactively. The full local
conversation remains available with `opencode session list` and `opencode export <session-id>`;
exports can contain sensitive file/tool data, so review them before sharing.

A chat message on a finished task puts it back in the queue. The runner then answers in the
same OpenCode session instead of starting again. **Run again** starts the task from scratch;
the time and tokens keep adding up across runs.

### Settings

| Setting        | Default                  | Meaning                                              |
| -------------- | ------------------------ | ---------------------------------------------------- |
| `model`        | `ollama/qwen3-coder:30b` | OpenCode `provider/model`                            |
| `auto_model`   | `true`                   | Choose between installed Qwen general/coder per task |
| `ollama_url`   | `http://localhost:11434` | Local Ollama endpoint for model discovery            |
| `context`      | `32768`                  | Context window given to OpenCode (e.g. 65536)        |
| `output`       | `8192`                   | Largest answer in tokens                             |
| `max_tokens`   | `500000`                 | Input + output tokens per run                        |
| `max_minutes`  | `30`                     | Time per run                                         |
| `poll_minutes` | `5`                      | Wait between checks when the list is empty           |
| `plan_first`   | `true`                   | Plan with the read-only agent before working         |
| `auto_approve` | `false`                  | Pass `--auto` to OpenCode (disposable folders)       |
| `workspace_id` | all                      | Only take tasks from one workspace                   |
| `name`         | computer name            | Runner name shown in the app                         |

Make sure Ollama serves the model with at least the same context, for example
`OLLAMA_CONTEXT_LENGTH=32768 ollama serve`.

The 500,000-token budget counts input again on every model step, not just generated text.
Together with the 30-minute limit it is a safety ceiling, not a target duration.
Restart the runner after changing its configuration; settings are loaded at startup.

### Keep it running on macOS

Save as `~/Library/LaunchAgents/cat.jordiorriols.agents-runner.plist`, adjusting the paths
(macOS's `/usr/bin/python3` is 3.9, so point it at a Python 3.11+ such as Homebrew's),
then `launchctl load ~/Library/LaunchAgents/cat.jordiorriols.agents-runner.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>cat.jordiorriols.agents-runner</string>
    <key>ProgramArguments</key>
    <array>
      <string>/opt/homebrew/bin/python3</string>
      <string>/Users/you/GitHub/agents/runner/agents_runner.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/agents-runner.log</string>
    <key>StandardErrorPath</key><string>/tmp/agents-runner.log</string>
  </dict>
</plist>
```

## Checks

```sh
npm run compile && npm run lint && npm run format:check
npm run test:coverage
npm run test:runner
```

The isolated browser tests live in the sibling `e2e-tests` repository:

```sh
cd ../e2e-tests
npx playwright test --config agents.config.ts
```

They start Agents on port 5189 with mocked Supabase responses (no real workspace writes),
checking conversation history, mobile layout and refresh after the runner finishes.

## Database

The Supabase project is shared with the other apps. Its migrations and database tests live in
the [backend](https://github.com/JordiOrriols/backend) repository, which also documents how to
apply them. The Agents tables are `agent_tasks`, `agent_task_messages` and `agent_runners`;
every change goes through `agents_*` functions that check workspace access.
