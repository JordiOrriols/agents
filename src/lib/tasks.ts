import i18n from "@/i18n";

export const TASK_STATUSES = ["pending", "running", "completed", "failed"] as const;
export type TaskStatus = (typeof TASK_STATUSES)[number];

export interface AgentTask {
  id: string;
  workspaceId: string;
  title: string;
  instructions: string;
  status: TaskStatus;
  plan: string;
  outcome: string;
  error: string;
  secondsSpent: number;
  tokensGenerated: number;
  tokensTotal: number;
  largestContext: number;
  attempts: number;
  model: string;
  sessionId: string | null;
  runner: string | null;
  createdAt: string;
  queuedAt: string;
  startedAt: string | null;
  finishedAt: string | null;
}

export interface TaskMessage {
  id: string;
  role: "user" | "agent";
  body: string;
  createdAt: string;
}

export interface RunMessage {
  kind: "agents-run";
  version: 1;
  model: string;
  selection: string;
  phases: {
    name: "routing" | "plan" | "work" | "review";
    tokens: number;
    seconds: number;
    tools: string[];
  }[];
  answer: string;
  verification: string;
  failure: string | null;
  stats?: RunStats;
}

const RUN_COUNTERS = [
  "steps",
  "compactions",
  "compaction_seconds",
  "model_seconds",
  "tool_seconds",
  "tokens_read",
  "tokens_cached",
  "tokens_generated",
  "largest_context",
  "context_limit",
  "tool_calls",
  "tool_errors",
  "pages_not_found",
  "pages_forbidden",
  "truncated_outputs",
  "repeated_fetches",
  "subagents",
] as const;

/** Counters of a run, kept to compare runs, models and computers later. */
export type RunStats = Record<(typeof RUN_COUNTERS)[number], number> & {
  ended: string;
  machine: string;
  answer_recovered: boolean;
};

export function parseRunMessage(body: string): RunMessage | null {
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch (error) {
    if (error instanceof SyntaxError) return null;
    throw error;
  }
  const record = (item: unknown): item is Record<string, unknown> =>
    typeof item === "object" && item !== null && !Array.isArray(item);
  if (!record(value) || value["kind"] !== "agents-run") return null;
  const number = (item: unknown) => typeof item === "number" && Number.isFinite(item) && item >= 0;
  const validStats = (stats: unknown) =>
    record(stats) &&
    RUN_COUNTERS.every((field) => number(stats[field])) &&
    typeof stats["ended"] === "string" &&
    typeof stats["machine"] === "string" &&
    typeof stats["answer_recovered"] === "boolean";
  const valid = (value: Record<string, unknown>): value is Record<string, unknown> & RunMessage =>
    value["version"] === 1 &&
    ["model", "selection", "answer", "verification"].every(
      (field) => typeof value[field] === "string"
    ) &&
    (value["failure"] === null || typeof value["failure"] === "string") &&
    (value["stats"] === undefined || validStats(value["stats"])) &&
    Array.isArray(value["phases"]) &&
    value["phases"].every(
      (phase: unknown) =>
        record(phase) &&
        ["routing", "plan", "work", "review"].includes(String(phase["name"])) &&
        number(phase["tokens"]) &&
        number(phase["seconds"]) &&
        Array.isArray(phase["tools"]) &&
        phase["tools"].every(
          (tool: unknown) =>
            typeof tool === "string" && /^[a-zA-Z0-9_-]{1,60}: (completed|error)$/.test(tool)
        )
    );
  if (!valid(value)) throw new Error(i18n.t("errors.unexpectedResponse"));
  return value;
}

export interface RunnerStatus {
  name: string;
  pollSeconds: number;
  lastSeen: string;
}

const time = (value: string | null) => (value ? Date.parse(value) : 0);

/**
 * The list reads top to bottom as the agent will work: the running task, then pending tasks in
 * queue order, then finished tasks with the most recent first.
 */
export function arrangeTasks(tasks: AgentTask[]) {
  const queue = tasks
    .filter((task) => task.status === "running" || task.status === "pending")
    .sort(
      (a, b) =>
        Number(b.status === "running") - Number(a.status === "running") ||
        time(a.queuedAt) - time(b.queuedAt) ||
        time(a.createdAt) - time(b.createdAt)
    );
  const done = tasks
    .filter((task) => task.status === "completed" || task.status === "failed")
    .sort(
      (a, b) => time(b.finishedAt) - time(a.finishedAt) || time(b.createdAt) - time(a.createdAt)
    );
  return { queue, done };
}

/** Time spent on a task, including the run in progress. */
export function elapsedSeconds(task: AgentTask, now: number) {
  if (task.status !== "running" || !task.startedAt) return task.secondsSpent;
  return task.secondsSpent + Math.max(0, (now - Date.parse(task.startedAt)) / 1000);
}

export function formatDuration(seconds: number) {
  const total = Math.max(0, Math.round(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = total % 60;
  if (hours) return `${hours}h ${String(minutes).padStart(2, "0")}m`;
  if (minutes) return `${minutes}m ${String(rest).padStart(2, "0")}s`;
  return `${rest}s`;
}

export function formatTokens(tokens: number, language: string) {
  return new Intl.NumberFormat(language, { notation: "compact", maximumFractionDigits: 1 }).format(
    tokens
  );
}

export function formatRelative(date: string, language: string, now = Date.now()) {
  const seconds = Math.round((Date.parse(date) - now) / 1000);
  const format = new Intl.RelativeTimeFormat(language, { numeric: "auto" });
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
  ];
  for (const [unit, size] of units)
    if (Math.abs(seconds) >= size) return format.format(Math.round(seconds / size), unit);
  return format.format(0, "second");
}

/** A runner is online while it has checked for work within two poll intervals. */
export function isRunnerOnline(runner: RunnerStatus, now = Date.now()) {
  return now - Date.parse(runner.lastSeen) <= runner.pollSeconds * 2000 + 60_000;
}
