import React from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useElapsedSeconds } from "@/hooks/useTasks";
import { formatDuration, formatTokens, spentTokens, type AgentTask } from "@/lib/tasks";
import { StatusMark } from "./StatusMark";

function TaskMeta({ task }: { task: AgentTask }) {
  const { t, i18n } = useTranslation();
  const elapsed = useElapsedSeconds(task);
  if (task.status === "running" && !task.startedAt) return t("tasks.status.running");
  if (task.status === "pending") return t("tasks.meta.queued");
  return t("tasks.meta.finished", {
    duration: formatDuration(elapsed),
    tokens: formatTokens(spentTokens(task).generated, i18n.language),
  });
}

export function TaskCard({ task, position }: { task: AgentTask; position?: number }) {
  return (
    <li>
      <Link
        to={`/tasks/${task.id}`}
        data-testid="task-card"
        data-status={task.status}
        className="group flex items-center gap-3 rounded-lg border border-border bg-card px-4 py-3 transition-colors hover:border-foreground/25 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        <StatusMark status={task.status} />
        <span
          className={
            task.status === "completed"
              ? "min-w-0 flex-1 truncate text-sm text-muted-foreground"
              : "min-w-0 flex-1 truncate text-sm font-medium"
          }
        >
          {task.title}
        </span>
        <span className="shrink-0 text-xs tabular-nums text-muted-foreground">
          <TaskMeta task={task} />
        </span>
        {position !== undefined && (
          <span className="w-5 shrink-0 text-right font-mono text-xs text-muted-foreground/70">
            {position}
          </span>
        )}
      </Link>
    </li>
  );
}
