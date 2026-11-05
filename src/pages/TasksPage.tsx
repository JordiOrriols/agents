import React from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { AppSkeleton, EmptyState, ErrorState } from "@jordiorriols/ui";
import { ListTodo } from "@jordiorriols/ui/icons";
import { RunnerStatus } from "@/components/RunnerStatus";
import { TaskCard } from "@/components/TaskCard";
import { TaskComposer } from "@/components/TaskComposer";
import { TaskDetail } from "@/components/TaskDetail";
import { useWorkspace } from "@/data/WorkspaceProvider";
import { useRunners, useTaskActions, useTasks } from "@/hooks/useTasks";
import { arrangeTasks, type AgentTask } from "@/lib/tasks";

function TaskSection({
  title,
  tasks,
  numbered,
  testId,
}: {
  title: string;
  tasks: AgentTask[];
  numbered?: boolean;
  testId: string;
}) {
  if (!tasks.length) return null;
  const running = tasks.filter((task) => task.status === "running").length;
  return (
    <section className="space-y-2" aria-label={title} data-testid={testId}>
      <h2 className="flex items-baseline gap-2 px-1 text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {title}
        <span className="font-mono normal-case tracking-normal">{tasks.length}</span>
      </h2>
      <ul className="space-y-1.5">
        {tasks.map((task, index) => (
          <TaskCard
            key={task.id}
            task={task}
            {...(numbered && task.status === "pending" ? { position: index + 1 - running } : {})}
          />
        ))}
      </ul>
    </section>
  );
}

export default function TasksPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { taskId } = useParams();
  const { workspace } = useWorkspace();
  const workspaceId = workspace?.id ?? null;
  const canEdit = workspace?.access_level === "owner" || workspace?.access_level === "editor";
  const tasks = useTasks(workspaceId);
  const runners = useRunners(workspaceId);
  const { create } = useTaskActions(workspaceId);
  const { queue, done } = arrangeTasks(tasks.data ?? []);
  const selected = tasks.data?.find((task) => task.id === taskId) ?? null;

  return (
    <div className="mx-auto w-full max-w-2xl space-y-6">
      <div className="space-y-2">
        {canEdit && <TaskComposer onCreate={(task) => create.mutateAsync(task)} />}
        <RunnerStatus runners={runners.data ?? []} />
      </div>
      {tasks.error && <ErrorState message={tasks.error.message} />}
      {tasks.isPending && !tasks.error ? (
        <AppSkeleton label={t("tasks.loading")} />
      ) : queue.length + done.length === 0 ? (
        !tasks.error && (
          <EmptyState
            icon={<ListTodo className="size-8 text-muted-foreground" />}
            title={t("tasks.empty.title")}
            description={t(canEdit ? "tasks.empty.description" : "tasks.empty.viewer")}
          />
        )
      ) : (
        <>
          <TaskSection title={t("tasks.sections.queue")} tasks={queue} numbered testId="queue" />
          <TaskSection title={t("tasks.sections.done")} tasks={done} testId="done" />
        </>
      )}
      {selected && <TaskDetail task={selected} canEdit={canEdit} onClose={() => navigate("/")} />}
    </div>
  );
}
