import React from "react";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";
import i18n from "@/i18n";
import App from "@/App";

const { client, auth, store } = vi.hoisted(() => {
  const auth = {
    session: null as { user: { id: string; email: string } } | null,
    listener: undefined as ((event: string, session: unknown) => void) | undefined,
    workspaces: [] as { id: string; name: string; owner_id: string; access_level: string }[],
  };
  type Task = Record<string, unknown> & { id: string; status: string };
  const minutesAgo = (minutes: number) => new Date(Date.now() - minutes * 60_000).toISOString();
  /** An in-memory stand-in for the Agents tables and their RPCs. */
  const store = {
    tasks: [] as Task[],
    messages: [] as {
      id: string;
      task_id: string;
      role: string;
      body: string;
      created_at: string;
    }[],
    runners: [] as { name: string; poll_seconds: number; last_seen: string }[],
    fail: null as string | null,
    minutesAgo,
    task(id: string, overrides: Record<string, unknown> = {}): Task {
      return {
        id,
        workspace_id: "ws-1",
        title: id,
        instructions: `Instructions for ${id}`,
        status: "pending",
        plan: "",
        outcome: "",
        error: "",
        seconds_spent: 0,
        tokens_generated: 0,
        tokens_total: 0,
        largest_context: 0,
        attempts: 0,
        model: "",
        session_id: null,
        runner: null,
        created_at: minutesAgo(60),
        queued_at: minutesAgo(60),
        started_at: null,
        finished_at: null,
        ...overrides,
      };
    },
    reset() {
      store.tasks = [];
      store.messages = [];
      store.runners = [];
      store.fail = null;
    },
    rpc(name: string, args: Record<string, unknown>) {
      const found = store.tasks.find((task) => task.id === args["task"]);
      switch (name) {
        case "agents_create_task": {
          const id = `new-${store.tasks.length + 1}`;
          store.tasks.push(
            store.task(id, {
              title: args["task_title"],
              instructions: args["task_instructions"],
              created_at: new Date().toISOString(),
              queued_at: new Date().toISOString(),
            })
          );
          return id;
        }
        case "agents_rerun_task":
          Object.assign(found!, {
            status: "pending",
            plan: "",
            outcome: "",
            error: "",
            queued_at: new Date().toISOString(),
          });
          return null;
        case "agents_delete_task":
          store.tasks = store.tasks.filter((task) => task !== found);
          return null;
        case "agents_send_message":
          store.messages.push({
            id: `m${store.messages.length + 1}`,
            task_id: found!.id,
            role: "user",
            body: String(args["message"]),
            created_at: new Date().toISOString(),
          });
          found!.status = "pending";
          return null;
        case "agents_runner_status":
          return store.runners;
        default:
          return null;
      }
    },
  };
  const query = (table: string) => {
    const filters: Record<string, unknown> = {};
    const builder = {
      select: () => builder,
      order: () => builder,
      eq: (column: string, value: unknown) => {
        filters[column] = value;
        return builder;
      },
      then: (resolve: (value: { data: unknown; error: null }) => unknown) =>
        resolve({
          data:
            table === "agent_tasks"
              ? store.tasks.filter((task) => task["workspace_id"] === filters["workspace_id"])
              : store.messages.filter((message) => message.task_id === filters["task_id"]),
          error: null,
        }),
    };
    return builder;
  };
  const client = {
    link: null as unknown,
    current: {
      rpc: vi.fn(async (name: string, args: Record<string, unknown>) => {
        if (name === "list_workspaces") return { data: auth.workspaces, error: null };
        if (store.fail) return { data: null, error: { message: store.fail } };
        return { data: store.rpc(name, args), error: null };
      }),
      from: vi.fn(query),
      auth: {
        getSession: vi.fn(async () => ({ data: { session: auth.session }, error: null })),
        onAuthStateChange: vi.fn((listener: typeof auth.listener) => {
          auth.listener = listener;
          return { data: { subscription: { unsubscribe: vi.fn() } } };
        }),
        signInWithPassword: vi.fn(async () => ({ error: null })),
        signOut: vi.fn(async () => ({ error: null })),
        updateUser: vi.fn(async () => ({ data: { user: null }, error: null })),
        setSession: vi.fn(async () => ({ data: { session: auth.session }, error: null })),
      },
    } as unknown,
  };
  return { client, auth, store };
});
vi.mock("@/data/supabaseClient", () => ({
  get supabase() {
    return client.current;
  },
  get authCallback() {
    return client.link;
  },
}));
const rpc = (client.current as { rpc: ReturnType<typeof vi.fn> }).rpc;
const supabaseAuth = (client.current as { auth: Record<string, ReturnType<typeof vi.fn>> }).auth;

const renderAt = (path: string) =>
  render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <MemoryRouter initialEntries={[path]}>
        <App />
      </MemoryRouter>
    </QueryClientProvider>
  );

const cardTitles = (section: HTMLElement) =>
  within(section)
    .getAllByTestId("task-card")
    .map((card) => card.textContent);

describe("Agents", () => {
  beforeEach(async () => {
    await i18n.changeLanguage("en");
    auth.session = { user: { id: "user-1", email: "ada@example.com" } };
    auth.workspaces = [{ id: "ws-1", name: "Home", owner_id: "user-1", access_level: "owner" }];
    localStorage.clear();
    store.reset();
  });

  it("shows the shared header with Agents as the current project", async () => {
    renderAt("/");
    expect(await screen.findByTestId("header-title")).toHaveTextContent("Agents");
    await userEvent.click(screen.getByRole("button", { name: "Switch project" }));
    expect(screen.getByRole("menuitem", { name: "Agents" })).toHaveAttribute(
      "aria-current",
      "page"
    );
    expect(rpc).toHaveBeenCalledWith("list_workspaces", { app_name: "agents" });
  });

  it("lists pending tasks on top in queue order and finished tasks below", async () => {
    store.tasks = [
      store.task("Write docs", {
        status: "completed",
        seconds_spent: 125,
        tokens_generated: 2400,
        finished_at: store.minutesAgo(5),
      }),
      store.task("Second", { queued_at: store.minutesAgo(30) }),
      store.task("Running now", {
        status: "running",
        runner: "studio",
        started_at: store.minutesAgo(2),
      }),
      store.task("First", { queued_at: store.minutesAgo(40) }),
      store.task("Broken", { status: "failed", finished_at: store.minutesAgo(1) }),
    ];
    renderAt("/");
    const queue = await screen.findByRole("region", { name: "Up next" });
    expect(cardTitles(queue)).toEqual([
      "Running nowStarted 2 minutes ago",
      "FirstQueued1",
      "SecondQueued2",
    ]);
    expect(cardTitles(screen.getByRole("region", { name: "Done" }))).toEqual([
      "Broken0s · 0 tokens",
      "Write docs2m 05s · 2.4K tokens",
    ]);
    expect(within(queue).getAllByRole("img")[0]).toHaveAccessibleName("Running");
  });

  it("adds a task, using the title as instructions when none are given", async () => {
    renderAt("/");
    expect(await screen.findByText("No tasks yet")).toBeInTheDocument();
    expect(screen.queryByLabelText(/Instructions/)).not.toBeInTheDocument();
    await userEvent.type(screen.getByLabelText("What should the agent do?"), "Update deps");
    await userEvent.click(screen.getByRole("button", { name: "Add task" }));
    const queue = await screen.findByRole("region", { name: "Up next" });
    expect(cardTitles(queue)).toEqual(["Update depsQueued1"]);
    expect(rpc).toHaveBeenCalledWith("agents_create_task", {
      workspace: "ws-1",
      task_title: "Update deps",
      task_instructions: "Update deps",
    });
    expect(screen.getByLabelText("What should the agent do?")).toHaveValue("");
  });

  it("adds a task with instructions from the keyboard shortcut", async () => {
    renderAt("/");
    await userEvent.type(await screen.findByLabelText("What should the agent do?"), "Audit");
    await userEvent.type(screen.getByLabelText(/Instructions/), "Check every repo");
    await userEvent.keyboard("{Control>}{Enter}{/Control}");
    await screen.findByRole("region", { name: "Up next" });
    expect(rpc).toHaveBeenCalledWith("agents_create_task", {
      workspace: "ws-1",
      task_title: "Audit",
      task_instructions: "Check every repo",
    });
  });

  it("keeps the draft and explains when a task cannot be added", async () => {
    store.fail = "Edit access required";
    renderAt("/");
    await userEvent.type(await screen.findByLabelText("What should the agent do?"), "Audit");
    await userEvent.click(screen.getByRole("button", { name: "Add task" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Edit access required");
    expect(screen.getByLabelText("What should the agent do?")).toHaveValue("Audit");
  });

  it("shows the instructions, plan, outcome, usage and chat of a finished task", async () => {
    store.tasks = [
      store.task("t1", {
        title: "Fix login",
        status: "completed",
        instructions: "The login fails on Safari.",
        plan: "1. Reproduce\n2. Fix",
        outcome: "Fixed the cookie flag.",
        seconds_spent: 3725,
        tokens_generated: 12_345,
        tokens_total: 210_000,
        attempts: 2,
        model: "ollama/qwen3-coder:30b",
        session_id: "ses_1",
        finished_at: store.minutesAgo(3),
      }),
    ];
    store.messages = [
      {
        id: "m1",
        task_id: "t1",
        role: "agent",
        body: "It was the SameSite flag.",
        created_at: store.minutesAgo(2),
      },
    ];
    renderAt("/tasks/t1");
    const detail = await screen.findByRole("dialog", { name: "Fix login" });
    expect(detail).toHaveAccessibleDescription("Completed · 2 runs");
    expect(within(detail).getByTestId("task-instructions")).toHaveTextContent(
      "The login fails on Safari."
    );
    expect(within(detail).getByTestId("task-plan")).toHaveTextContent("1. Reproduce 2. Fix");
    expect(within(detail).getByTestId("task-outcome")).toHaveTextContent("Fixed the cookie flag.");
    expect(within(detail).getByText("1h 02m")).toBeInTheDocument();
    expect(within(detail).getByText("12.3K")).toBeInTheDocument();
    expect(within(detail).getByText("210K")).toBeInTheDocument();
    expect(within(detail).getByText("ollama/qwen3-coder:30b")).toBeInTheDocument();
    expect(await within(detail).findByText("It was the SameSite flag.")).toBeInTheDocument();

    await userEvent.type(within(detail).getByLabelText(/follow-up/), "Add a test too");
    await userEvent.click(within(detail).getByRole("button", { name: "Send" }));
    expect(await within(detail).findByText("Add a test too")).toBeInTheDocument();
    expect(rpc).toHaveBeenCalledWith("agents_send_message", {
      task: "t1",
      message: "Add a test too",
    });
    await waitFor(() => expect(detail).toHaveAccessibleDescription("Pending · 2 runs"));
  });

  it("runs a failed task again from its detail", async () => {
    store.tasks = [
      store.task("t1", {
        title: "Deploy",
        status: "failed",
        error: "Stopped: token limit (150,000).",
        attempts: 1,
        finished_at: store.minutesAgo(1),
      }),
    ];
    renderAt("/tasks/t1");
    const detail = await screen.findByRole("dialog", { name: "Deploy" });
    expect(within(detail).getByRole("alert")).toHaveTextContent("token limit");
    await userEvent.click(within(detail).getByRole("button", { name: "Run again" }));
    await waitFor(() => expect(detail).toHaveAccessibleDescription("Pending · 1 run"));
    expect(within(detail).queryByRole("button", { name: "Run again" })).not.toBeInTheDocument();
    expect(rpc).toHaveBeenCalledWith("agents_rerun_task", { task: "t1" });
  });

  it("deletes a task after confirming and goes back to the list", async () => {
    store.tasks = [store.task("t1", { title: "Old idea" })];
    renderAt("/tasks/t1");
    const detail = await screen.findByRole("dialog", { name: "Old idea" });
    await userEvent.click(within(detail).getByRole("button", { name: "Delete" }));
    const confirm = await screen.findByRole("alertdialog", { name: "Delete this task?" });
    await userEvent.click(within(confirm).getByRole("button", { name: "Delete" }));
    expect(await screen.findByText("No tasks yet")).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("does not let a running task be deleted or chatted with", async () => {
    store.tasks = [store.task("t1", { title: "Busy", status: "running", runner: "studio" })];
    renderAt("/tasks/t1");
    const detail = await screen.findByRole("dialog", { name: "Busy" });
    expect(within(detail).getByText("Running on studio")).toBeInTheDocument();
    expect(within(detail).getByRole("button", { name: "Delete" })).toBeDisabled();
    expect(within(detail).getByLabelText(/follow-up/)).toBeDisabled();
    expect(within(detail).getByText("You can write once the agent finishes.")).toBeInTheDocument();
  });

  it("closes the detail back to the list", async () => {
    store.tasks = [store.task("t1", { title: "Something" })];
    renderAt("/tasks/t1");
    const detail = await screen.findByRole("dialog", { name: "Something" });
    await userEvent.click(within(detail).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    expect(screen.getByRole("region", { name: "Up next" })).toBeInTheDocument();
  });

  it("opens a task from its card", async () => {
    store.tasks = [store.task("t1", { title: "Card" })];
    renderAt("/");
    await userEvent.click(await screen.findByTestId("task-card"));
    expect(await screen.findByRole("dialog", { name: "Card" })).toBeInTheDocument();
  });

  it("is read-only for workspace viewers", async () => {
    auth.workspaces = [{ id: "ws-1", name: "Home", owner_id: "user-2", access_level: "viewer" }];
    store.tasks = [store.task("t1", { title: "Shared", status: "completed" })];
    renderAt("/tasks/t1");
    const detail = await screen.findByRole("dialog", { name: "Shared" });
    expect(within(detail).queryByRole("button", { name: "Run again" })).not.toBeInTheDocument();
    expect(within(detail).queryByLabelText(/follow-up/)).not.toBeInTheDocument();
    expect(screen.queryByLabelText("What should the agent do?")).not.toBeInTheDocument();
  });

  it("tells viewers where tasks come from when there are none", async () => {
    auth.workspaces = [{ id: "ws-1", name: "Home", owner_id: "user-2", access_level: "viewer" }];
    renderAt("/");
    expect(
      await screen.findByText("Tasks added by the workspace editors appear here.")
    ).toBeInTheDocument();
  });

  it("shows whether the local runner is checking for work", async () => {
    renderAt("/");
    expect(await screen.findByTestId("runner-status")).toHaveTextContent("No runner yet");
  });

  it.each([
    [2, "true", "Runner studio online · checked 2 minutes ago"],
    [60, "false", "Runner studio offline · last seen 1 hour ago"],
  ])("shows a runner seen %i minutes ago", async (minutes, online, text) => {
    store.runners = [{ name: "studio", poll_seconds: 300, last_seen: store.minutesAgo(minutes) }];
    renderAt("/");
    const status = await screen.findByTestId("runner-status");
    await waitFor(() => expect(status).toHaveTextContent(text));
    expect(status).toHaveAttribute("data-online", online);
  });

  it("sends unknown routes to the list", async () => {
    renderAt("/missing");
    expect(await screen.findByText("No tasks yet")).toBeInTheDocument();
  });

  it("signs out from the shared header", async () => {
    renderAt("/");
    await userEvent.click(await screen.findByRole("button", { name: "Sign out" }));
    expect(supabaseAuth["signOut"]).toHaveBeenCalled();
    await act(async () => auth.listener?.("SIGNED_OUT", null));
    expect(
      await screen.findByRole("heading", { name: "Hand tasks to your local agent." })
    ).toBeInTheDocument();
  });
});
