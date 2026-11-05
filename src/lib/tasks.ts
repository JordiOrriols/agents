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
