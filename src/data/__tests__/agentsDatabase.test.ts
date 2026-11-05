// @vitest-environment node
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { PGlite } from "@electric-sql/pglite";
import { createMigratedDatabase } from "./support/migratedDatabase";

const accounts = ["owner", "editor", "viewer", "otherApp", "outsider", "runner"].map(
  (name, index) => ({
    id: `${index + 1}1111111-1111-4111-8111-111111111111`,
    email: `${name.toLowerCase()}@example.com`,
  })
);
const [owner, editor, viewer, otherApp, outsider, runner] = accounts as [
  (typeof accounts)[number],
  (typeof accounts)[number],
  (typeof accounts)[number],
  (typeof accounts)[number],
  (typeof accounts)[number],
  (typeof accounts)[number],
];
let db: PGlite;
let workspace: string;
let otherWorkspace: string;

async function login(account: { id: string } | null) {
  await db.exec("reset role");
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [account?.id ?? ""]);
  await db.exec(`set role ${account ? "authenticated" : "anon"}`);
}
async function value<T>(sql: string, args: unknown[] = []) {
  return (await db.query<{ value: T }>(sql, args)).rows[0]!.value;
}
async function rows<T>(sql: string, args: unknown[] = []) {
  return (await db.query<T>(sql, args)).rows;
}
async function createTask(title: string, target = workspace) {
  return value<string>("select public.agents_create_task($1,$2,$3) as value", [
    target,
    title,
    `Do ${title}`,
  ]);
}
type Claimed = { id: string; title: string; status: string; attempts: number; runner: string };
async function claim(name = "mac") {
  return rows<Claimed>("select * from public.agents_claim_task($1, 300)", [name]);
}
async function finish(task: string, args: Partial<Record<string, unknown>> = {}) {
  const run = {
    runner: "mac",
    succeeded: true,
    seconds: 30,
    generated: 100,
    total: 1000,
    context: 900,
    model: "ollama/qwen3-coder:30b",
    session: "ses_1",
    plan: null,
    outcome: null,
    reply: null,
    failure: "",
    ...args,
  };
  await db.query(
    `select public.agents_finish_task(task => $1, runner_name => $2, succeeded => $3,
      run_seconds => $4, run_tokens_generated => $5, run_tokens_total => $6, run_context => $7,
      run_model => $8, run_session => $9, run_plan => $10, run_outcome => $11, reply => $12,
      failure => $13)`,
    [
      task,
      run.runner,
      run.succeeded,
      run.seconds,
      run.generated,
      run.total,
      run.context,
      run.model,
      run.session,
      run.plan,
      run.outcome,
      run.reply,
      run.failure,
    ]
  );
}
async function task(id: string) {
  await db.exec("reset role");
  const [found] = await rows<Record<string, unknown>>(
    "select * from public.agent_tasks where id=$1",
    [id]
  );
  return found!;
}

beforeAll(async () => {
  db = await createMigratedDatabase(accounts);
  await login(owner);
  workspace = await value("select id as value from public.create_workspace('Agents')");
  otherWorkspace = await value("select id as value from public.create_workspace('Other')");
  for (const [account, access] of [
    [editor, "editor"],
    [viewer, "viewer"],
    [runner, "editor"],
  ] as const)
    await db.query("select public.share_workspace($1,$2,'agents',$3)", [
      workspace,
      account.email,
      access,
    ]);
  await db.query("select public.share_workspace($1,$2,'pulse','editor')", [
    workspace,
    otherApp.email,
  ]);
});
afterAll(async () => db?.close());
beforeEach(async () => {
  await db.exec("reset role; delete from public.agent_tasks; delete from public.agent_runners;");
});

describe("agents workspace access", () => {
  it("lists Agents workspaces and shares through the shared workspace RPCs", async () => {
    await login(editor);
    expect(
      await rows("select name, access_level from public.list_workspaces('agents')")
    ).toContainEqual({ name: "Agents", access_level: "editor" });
    await login(owner);
    expect(
      await rows<{ email: string }>(
        "select email from public.list_workspace_app_shares($1,'agents')",
        [workspace]
      )
    ).toEqual([
      { email: "editor@example.com" },
      { email: "runner@example.com" },
      { email: "viewer@example.com" },
    ]);
  });

  it("lets editors create tasks and keeps them inside the workspace", async () => {
    await login(editor);
    const id = await createTask("  Check the site  ");
    await login(viewer);
    expect(await rows("select title, status from public.agent_tasks")).toEqual([
      { title: "Check the site", status: "pending" },
    ]);
    for (const account of [otherApp, outsider]) {
      await login(account);
      expect(await rows("select id from public.agent_tasks")).toEqual([]);
      await expect(createTask("Nope")).rejects.toThrow("Agents editor access required");
      await expect(db.query("select public.agents_delete_task($1)", [id])).rejects.toThrow(
        "Task not found"
      );
    }
    await login(viewer);
    await expect(createTask("Nope")).rejects.toThrow("Agents editor access required");
    await expect(db.query("select public.agents_delete_task($1)", [id])).rejects.toThrow(
      "Agents editor access required"
    );
    await login(null);
    expect(await rows("select id from public.agent_tasks").catch(() => [])).toEqual([]);
  });

  it("only allows changes through RPCs", async () => {
    await login(owner);
    const id = await createTask("Direct");
    await expect(
      db.query("update public.agent_tasks set status='completed' where id=$1", [id])
    ).rejects.toThrow("permission denied");
    await expect(
      db.query(
        "insert into public.agent_task_messages(task_id, role, body) values ($1,'agent','x')",
        [id]
      )
    ).rejects.toThrow("permission denied");
    await expect(db.query("select * from public.agent_runners")).rejects.toThrow(
      "permission denied"
    );
  });
});

describe("agents runner queue", () => {
  it("claims the oldest pending task of editable workspaces, one at a time", async () => {
    await login(owner);
    const first = await createTask("First");
    const second = await createTask("Second");
    await createTask("Elsewhere", otherWorkspace);
    await login(runner);
    const [claimed] = await claim();
    expect(claimed).toMatchObject({ id: first, status: "running", attempts: 1, runner: "mac" });
    await finish(first, { plan: "1. Look", outcome: "Done", reply: null });
    expect(await task(first)).toMatchObject({
      status: "completed",
      plan: "1. Look",
      outcome: "Done",
      seconds_spent: 30,
      tokens_generated: 100,
      tokens_total: 1000,
      largest_context: 900,
      session_id: "ses_1",
      runner: null,
    });
    await login(runner);
    expect((await claim())[0]!.id).toBe(second);
    await finish(second, { succeeded: false, failure: "time limit (30 min)" });
    expect(await task(second)).toMatchObject({ status: "failed", error: "time limit (30 min)" });
    await login(runner);
    expect(await claim()).toEqual([]);
  });

  it("does not let viewers or other runners claim or finish tasks", async () => {
    await login(owner);
    const id = await createTask("Guarded");
    await login(viewer);
    expect(await claim()).toEqual([]);
    await login(runner);
    await claim("mac");
    await expect(finish(id, { runner: "other" })).rejects.toThrow(
      "Task is not running on this runner"
    );
    await login(viewer);
    await expect(finish(id)).rejects.toThrow("Agents editor access required");
  });

  it("fails the tasks a restarted runner left running", async () => {
    await login(owner);
    const id = await createTask("Interrupted");
    await login(runner);
    await claim();
    expect(await claim()).toEqual([]);
    expect(await task(id)).toMatchObject({
      status: "failed",
      error: "The runner stopped before finishing this task.",
    });
  });

  it("reports runners of accounts that can edit the workspace", async () => {
    await login(runner);
    await claim("studio");
    await login(viewer);
    await claim("viewer-mac");
    await login(viewer);
    expect(
      await rows("select name, poll_seconds from public.agents_runner_status($1)", [workspace])
    ).toEqual([{ name: "studio", poll_seconds: 300 }]);
    await login(outsider);
    await expect(
      db.query("select * from public.agents_runner_status($1)", [workspace])
    ).rejects.toThrow("Workspace access required");
  });
});

describe("agents reruns and chat", () => {
  it("reruns finished tasks from scratch and keeps the totals", async () => {
    await login(owner);
    const id = await createTask("Again");
    await expect(db.query("select public.agents_rerun_task($1)", [id])).rejects.toThrow(
      "Only finished tasks can run again"
    );
    await login(runner);
    await claim();
    await expect(db.query("select public.agents_delete_task($1)", [id])).rejects.toThrow(
      "A running task cannot be deleted"
    );
    await finish(id, { plan: "Plan", outcome: "Out" });
    await login(editor);
    await db.query("select public.agents_rerun_task($1)", [id]);
    expect(await task(id)).toMatchObject({
      status: "pending",
      plan: "",
      outcome: "",
      session_id: null,
      seconds_spent: 30,
      attempts: 1,
    });
    await login(runner);
    await claim();
    await finish(id, { seconds: 10 });
    expect(await task(id)).toMatchObject({ attempts: 2, seconds_spent: 40, tokens_generated: 200 });
    await login(editor);
    await db.query("select public.agents_delete_task($1)", [id]);
    expect(await rows("select id from public.agent_tasks")).toEqual([]);
  });

  it("queues chat messages and stores the agent reply in order", async () => {
    await login(owner);
    const id = await createTask("Chat");
    await login(runner);
    await claim();
    await login(editor);
    await expect(db.query("select public.agents_send_message($1,'Hello')", [id])).rejects.toThrow(
      "Wait until the agent finishes this task"
    );
    await login(runner);
    await finish(id, { outcome: "First answer" });
    await login(editor);
    await expect(db.query("select public.agents_send_message($1,'  ')", [id])).rejects.toThrow(
      "Invalid message"
    );
    await db.query("select public.agents_send_message($1,' Why? ')", [id]);
    expect(await task(id)).toMatchObject({ status: "pending", session_id: "ses_1" });
    await login(runner);
    await claim();
    await finish(id, { reply: "Because", outcome: null });
    await login(viewer);
    expect(
      await rows("select role, body from public.agent_task_messages order by created_at")
    ).toEqual([
      { role: "user", body: "Why?" },
      { role: "agent", body: "Because" },
    ]);
    expect(await task(id)).toMatchObject({ status: "completed", outcome: "First answer" });
  });
});
