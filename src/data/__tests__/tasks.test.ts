import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { createTaskApi } from "../tasks";

const row = {
  id: "t1",
  workspace_id: "ws-1",
  title: "Fix login",
  instructions: "The login fails.",
  status: "completed",
  plan: "1. Read",
  outcome: "Fixed",
  error: "",
  seconds_spent: 61,
  tokens_generated: "1200",
  tokens_total: 54000,
  largest_context: 18000,
  attempts: 1,
  model: "ollama/qwen3-coder:30b",
  session_id: "ses_1",
  runner: null,
  created_at: "2026-11-01T09:00:00Z",
  queued_at: "2026-11-01T09:00:00Z",
  started_at: "2026-11-01T09:01:00Z",
  finished_at: "2026-11-01T09:02:01Z",
};

function fakeClient(result: { data: unknown; error: { message: string } | null }) {
  const calls: unknown[][] = [];
  const builder: Record<string, unknown> = {};
  for (const method of ["select", "eq", "order"])
    builder[method] = (...args: unknown[]) => {
      calls.push([method, ...args]);
      return builder;
    };
  builder["then"] = (resolve: (value: typeof result) => unknown) => resolve(result);
  const client = {
    from: vi.fn((table: string) => {
      calls.push(["from", table]);
      return builder;
    }),
    rpc: vi.fn(async () => result),
  };
  return { api: createTaskApi(client as unknown as SupabaseClient), client, calls };
}

describe("createTaskApi", () => {
  it("reads the tasks of a workspace", async () => {
    const { api, calls } = fakeClient({ data: [row], error: null });
    const [task] = await api.listTasks("ws-1");
    expect(calls).toEqual([
      ["from", "agent_tasks"],
      ["select", "*"],
      ["eq", "workspace_id", "ws-1"],
    ]);
    expect(task).toMatchObject({
      id: "t1",
      workspaceId: "ws-1",
      status: "completed",
      secondsSpent: 61,
      tokensGenerated: 1200,
      sessionId: "ses_1",
      runner: null,
      finishedAt: "2026-11-01T09:02:01Z",
    });
  });

  it("reads the chat in order", async () => {
    const message = { id: "m1", role: "agent", body: "Done", created_at: "2026-11-01T09:03:00Z" };
    const { api, calls } = fakeClient({ data: [message], error: null });
    expect(await api.listMessages("t1")).toEqual([
      { id: "m1", role: "agent", body: "Done", createdAt: "2026-11-01T09:03:00Z" },
    ]);
    expect(calls).toContainEqual(["eq", "task_id", "t1"]);
    expect(calls).toContainEqual(["order", "created_at"]);
  });

  it("calls the task RPCs", async () => {
    const { api, client } = fakeClient({ data: "t2", error: null });
    expect(await api.createTask("ws-1", "Title", "Do it")).toBe("t2");
    await api.rerunTask("t1");
    await api.deleteTask("t1");
    await api.sendMessage("t1", "Why?");
    expect(client.rpc.mock.calls).toEqual([
      [
        "agents_create_task",
        { workspace: "ws-1", task_title: "Title", task_instructions: "Do it" },
      ],
      ["agents_rerun_task", { task: "t1" }],
      ["agents_delete_task", { task: "t1" }],
      ["agents_send_message", { task: "t1", message: "Why?" }],
    ]);
  });

  it("reads the runners", async () => {
    const runner = { name: "mac", poll_seconds: 300, last_seen: "2026-11-01T09:00:00Z" };
    const { api, client } = fakeClient({ data: [runner], error: null });
    expect(await api.listRunners("ws-1")).toEqual([
      { name: "mac", pollSeconds: 300, lastSeen: "2026-11-01T09:00:00Z" },
    ]);
    expect(client.rpc).toHaveBeenCalledWith("agents_runner_status", { workspace: "ws-1" });
  });

  it("passes database errors on", async () => {
    const { api } = fakeClient({ data: null, error: { message: "Edit access required" } });
    await expect(api.rerunTask("t1")).rejects.toThrow("Edit access required");
  });

  it.each([
    ["not a list", { data: { id: "t1" } }],
    ["an unknown status", { data: [{ ...row, status: "paused" }] }],
    ["a missing title", { data: [{ ...row, title: 3 }] }],
    ["a bad number", { data: [{ ...row, attempts: "many" }] }],
    ["a row that is not an object", { data: ["t1"] }],
  ])("rejects a response with %s", async (_, { data }) => {
    const { api } = fakeClient({ data, error: null });
    await expect(api.listTasks("ws-1")).rejects.toThrow("unexpected response");
  });

  it("rejects malformed messages and runners", async () => {
    await expect(
      fakeClient({
        data: [{ id: "m", role: "system", body: "", created_at: "" }],
        error: null,
      }).api.listMessages("t1")
    ).rejects.toThrow("unexpected response");
    await expect(fakeClient({ data: [null], error: null }).api.listRunners("ws-1")).rejects.toThrow(
      "unexpected response"
    );
  });
});
