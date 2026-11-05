import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useData } from "@/data/DataProvider";
import type { AgentTask } from "@/lib/tasks";

const ACTIVE_POLL_MS = 5_000;
const IDLE_POLL_MS = 20_000;

const taskKeys = {
  list: (workspaceId: string | null) => ["tasks", workspaceId] as const,
  messages: (taskId: string | null) => ["messages", taskId] as const,
  runners: (workspaceId: string | null) => ["runners", workspaceId] as const,
};

/** The tasks of a workspace, refreshed often while the agent has work in progress. */
export function useTasks(workspaceId: string | null) {
  const { taskApi } = useData();
  return useQuery({
    queryKey: taskKeys.list(workspaceId),
    queryFn: () => taskApi!.listTasks(workspaceId!),
    enabled: !!taskApi && !!workspaceId,
    refetchInterval: (query) =>
      query.state.data?.some((task) => task.status === "running" || task.status === "pending")
        ? ACTIVE_POLL_MS
        : IDLE_POLL_MS,
  });
}

export function useTaskMessages(task: AgentTask | null) {
  const { taskApi } = useData();
  return useQuery({
    queryKey: taskKeys.messages(task?.id ?? null),
    queryFn: () => taskApi!.listMessages(task!.id),
    enabled: !!taskApi && !!task,
    refetchInterval: task && task.status !== "completed" ? ACTIVE_POLL_MS : false,
  });
}

export function useRunners(workspaceId: string | null) {
  const { taskApi } = useData();
  return useQuery({
    queryKey: taskKeys.runners(workspaceId),
    queryFn: () => taskApi!.listRunners(workspaceId!),
    enabled: !!taskApi && !!workspaceId,
    refetchInterval: 30_000,
  });
}

/** Task changes, each refreshing the list (and the chat) once the database accepted it. */
export function useTaskActions(workspaceId: string | null) {
  const { taskApi } = useData();
  const client = useQueryClient();
  const refresh = async (taskId?: string) => {
    await client.invalidateQueries({ queryKey: taskKeys.list(workspaceId) });
    if (taskId) await client.invalidateQueries({ queryKey: taskKeys.messages(taskId) });
  };
  return {
    create: useMutation({
      mutationFn: ({ title, instructions }: { title: string; instructions: string }) =>
        taskApi!.createTask(workspaceId!, title, instructions),
      onSuccess: () => refresh(),
    }),
    rerun: useMutation({
      mutationFn: (taskId: string) => taskApi!.rerunTask(taskId),
      onSuccess: (_, taskId) => refresh(taskId),
    }),
    remove: useMutation({
      mutationFn: (taskId: string) => taskApi!.deleteTask(taskId),
      onSuccess: () => refresh(),
    }),
    send: useMutation({
      mutationFn: ({ taskId, message }: { taskId: string; message: string }) =>
        taskApi!.sendMessage(taskId, message),
      onSuccess: (_, { taskId }) => refresh(taskId),
    }),
  };
}
