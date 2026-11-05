import type { SupabaseClient } from "@supabase/supabase-js";
import i18n from "@/i18n";
import {
  TASK_STATUSES,
  type AgentTask,
  type RunnerStatus,
  type TaskMessage,
  type TaskStatus,
} from "@/lib/tasks";

type Row = { [field: string]: unknown };

function unexpected(): never {
  throw new Error(i18n.t("errors.unexpectedResponse"));
}
const isRow = (value: unknown): value is Row =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const text = (value: unknown) => (typeof value === "string" ? value : unexpected());
const optionalText = (value: unknown) => (value === null ? null : text(value));
const count = (value: unknown) => {
  const parsed = typeof value === "string" ? Number(value) : value;
  return typeof parsed === "number" && Number.isFinite(parsed) ? parsed : unexpected();
};
const list = (value: unknown) => (Array.isArray(value) ? value : unexpected());

function parseTask(row: unknown): AgentTask {
  if (!isRow(row)) unexpected();
  const status = row["status"];
  if (!(TASK_STATUSES as readonly unknown[]).includes(status)) unexpected();
  return {
    id: text(row["id"]),
    workspaceId: text(row["workspace_id"]),
    title: text(row["title"]),
    instructions: text(row["instructions"]),
    status: status as TaskStatus,
    plan: text(row["plan"]),
    outcome: text(row["outcome"]),
    error: text(row["error"]),
    secondsSpent: count(row["seconds_spent"]),
    tokensGenerated: count(row["tokens_generated"]),
    tokensTotal: count(row["tokens_total"]),
    largestContext: count(row["largest_context"]),
    attempts: count(row["attempts"]),
    model: text(row["model"]),
    sessionId: optionalText(row["session_id"]),
    runner: optionalText(row["runner"]),
    createdAt: text(row["created_at"]),
    queuedAt: text(row["queued_at"]),
    startedAt: optionalText(row["started_at"]),
    finishedAt: optionalText(row["finished_at"]),
  };
}

function parseMessage(row: unknown): TaskMessage {
  if (!isRow(row) || (row["role"] !== "user" && row["role"] !== "agent")) unexpected();
  return {
    id: text(row["id"]),
    role: row["role"],
    body: text(row["body"]),
    createdAt: text(row["created_at"]),
  };
}

function parseRunner(row: unknown): RunnerStatus {
  if (!isRow(row)) unexpected();
  return {
    name: text(row["name"]),
    pollSeconds: count(row["poll_seconds"]),
    lastSeen: text(row["last_seen"]),
  };
}

type Result = { data: unknown; error: { message: string } | null };
async function run(query: PromiseLike<Result>) {
  const { data, error } = await query;
  if (error) throw new Error(error.message);
  return data;
}

export function createTaskApi(client: SupabaseClient) {
  return {
    async listTasks(workspaceId: string) {
      const data = await run(
        client.from("agent_tasks").select("*").eq("workspace_id", workspaceId)
      );
      return list(data).map(parseTask);
    },
    async listMessages(taskId: string) {
      const data = await run(
        client
          .from("agent_task_messages")
          .select("id, role, body, created_at")
          .eq("task_id", taskId)
          .order("created_at")
      );
      return list(data).map(parseMessage);
    },
    async listRunners(workspaceId: string) {
      const data = await run(client.rpc("agents_runner_status", { workspace: workspaceId }));
      return list(data).map(parseRunner);
    },
    async createTask(workspaceId: string, title: string, instructions: string) {
      return text(
        await run(
          client.rpc("agents_create_task", {
            workspace: workspaceId,
            task_title: title,
            task_instructions: instructions,
          })
        )
      );
    },
    async rerunTask(taskId: string) {
      await run(client.rpc("agents_rerun_task", { task: taskId }));
    },
    async deleteTask(taskId: string) {
      await run(client.rpc("agents_delete_task", { task: taskId }));
    },
    async sendMessage(taskId: string, message: string) {
      await run(client.rpc("agents_send_message", { task: taskId, message }));
    },
  };
}

export type TaskApi = ReturnType<typeof createTaskApi>;
