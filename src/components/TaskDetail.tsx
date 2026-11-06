import React, { useState, type FormEvent, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { Button, ConfirmDialog, ErrorState, Modal, Textarea, cn } from "@jordiorriols/ui";
import { RotateCcw, Trash2 } from "@jordiorriols/ui/icons";
import { useElapsedSeconds, useTaskActions, useTaskMessages } from "@/hooks/useTasks";
import {
  formatDuration,
  formatTokens,
  parseRunMessage,
  spentTokens,
  type AgentTask,
} from "@/lib/tasks";
import { Markdown } from "./Markdown";
import { StatusMark } from "./StatusMark";

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="space-y-1.5">
      <h3 className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{title}</h3>
      {children}
    </section>
  );
}

function Text({ children, testId }: { children: string; testId: string }) {
  return (
    <div
      data-testid={testId}
      className="max-h-80 overflow-y-auto whitespace-pre-wrap break-words rounded-md bg-muted/50 px-3 py-2 text-sm leading-relaxed"
    >
      {children}
    </div>
  );
}

function Report({ children, testId }: { children: string; testId: string }) {
  return (
    <div
      data-testid={testId}
      className="max-h-[32rem] overflow-y-auto rounded-md bg-muted/50 px-3 py-2 text-sm leading-relaxed"
    >
      <Markdown>{children}</Markdown>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="truncate text-sm font-medium tabular-nums" title={value}>
        {value}
      </dd>
    </div>
  );
}

function AgentMessage({ body }: { body: string }) {
  const { t, i18n } = useTranslation();
  let run;
  try {
    run = parseRunMessage(body);
  } catch (error) {
    if (!(error instanceof Error)) throw error;
    return <ErrorState message={t("errors.unexpectedResponse")} />;
  }
  if (!run) return <>{body}</>;
  return (
    <div className="space-y-3" data-testid="agent-run-history">
      <Markdown>{run.answer}</Markdown>
      <details>
        <summary className="cursor-pointer font-medium">{t("tasks.detail.history")}</summary>
        <div className="mt-2 space-y-2">
          <p>{run.model}</p>
          {run.selection && <p>{run.selection}</p>}
          <ol className="space-y-2">
            {run.phases.map((phase, index) => (
              <li key={index}>
                <p>
                  {t(`tasks.detail.phases.${phase.name}`)} ·{" "}
                  {t("tasks.meta.finished", {
                    duration: formatDuration(phase.seconds),
                    tokens: formatTokens(phase.tokens, i18n.language),
                  })}
                </p>
                {phase.tools.length > 0 && (
                  <ul className="pl-3">
                    {phase.tools.map((tool, toolIndex) => {
                      const [name, status] = tool.split(": ");
                      return (
                        <li key={toolIndex}>
                          {name} ·{" "}
                          {t(`tasks.status.${status === "error" ? "failed" : "completed"}`)}
                        </li>
                      );
                    })}
                  </ul>
                )}
              </li>
            ))}
          </ol>
          {run.stats && (
            <dl className="grid grid-cols-2 gap-2 sm:grid-cols-3" data-testid="run-stats">
              <Stat
                label={t("tasks.detail.stats.compactions")}
                value={String(run.stats.compactions)}
              />
              <Stat label={t("tasks.detail.stats.steps")} value={String(run.stats.steps)} />
              <Stat
                label={t("tasks.detail.stats.modelTime")}
                value={formatDuration(run.stats.model_seconds)}
              />
              <Stat
                label={t("tasks.detail.stats.tokensRead")}
                value={formatTokens(run.stats.tokens_read, i18n.language)}
              />
              <Stat
                label={t("tasks.detail.stats.tokensCached")}
                value={formatTokens(run.stats.tokens_cached, i18n.language)}
              />
              <Stat
                label={t("tasks.detail.stats.largestContext")}
                value={formatTokens(run.stats.largest_context, i18n.language)}
              />
              <Stat
                label={t("tasks.detail.stats.toolErrors")}
                value={`${run.stats.tool_errors} / ${run.stats.tool_calls}`}
              />
              <Stat label={t("tasks.detail.stats.subagents")} value={String(run.stats.subagents)} />
              <Stat label={t("tasks.detail.stats.machine")} value={run.stats.machine} />
            </dl>
          )}
          {run.verification && <p>{run.verification}</p>}
          {run.failure && <ErrorState message={run.failure} />}
        </div>
      </details>
    </div>
  );
}

function Chat({ task, canEdit }: { task: AgentTask; canEdit: boolean }) {
  const { t } = useTranslation();
  const { data: messages = [], error } = useTaskMessages(task);
  const { send } = useTaskActions(task.workspaceId);
  const [message, setMessage] = useState("");
  const running = task.status === "running";

  async function submit(event: FormEvent) {
    event.preventDefault();
    const body = message.trim();
    if (!body) return;
    await send.mutateAsync({ taskId: task.id, message: body });
    setMessage("");
  }

  return (
    <Section title={t("tasks.detail.chat")}>
      {error && <ErrorState message={error.message} />}
      {messages.length > 0 && (
        <ol className="space-y-2" data-testid="task-chat">
          {messages.map((item) => (
            <li
              key={item.id}
              data-role={item.role}
              className={cn(
                "max-w-[85%] whitespace-pre-wrap break-words rounded-lg px-3 py-2 text-sm",
                item.role === "user" ? "ml-auto bg-primary text-primary-foreground" : "bg-muted/60"
              )}
            >
              <span className="sr-only">{t(`tasks.detail.roles.${item.role}`)}</span>
              {item.role === "agent" ? <AgentMessage body={item.body} /> : item.body}
            </li>
          ))}
        </ol>
      )}
      {canEdit && (
        <form onSubmit={submit} className="space-y-2">
          <Textarea
            value={message}
            onChange={(event) => setMessage(event.target.value)}
            placeholder={t("tasks.detail.chatPlaceholder")}
            aria-label={t("tasks.detail.chatPlaceholder")}
            maxLength={20000}
            rows={2}
            disabled={running || send.isPending}
          />
          {send.error && <ErrorState message={send.error.message} />}
          <div className="flex items-center justify-between gap-3">
            <p className="text-xs text-muted-foreground">
              {running ? t("tasks.detail.chatBusy") : t("tasks.detail.chatHint")}
            </p>
            <Button
              type="submit"
              size="sm"
              variant="outline"
              disabled={running || send.isPending || !message.trim()}
            >
              {t("tasks.detail.send")}
            </Button>
          </div>
        </form>
      )}
    </Section>
  );
}

/** Everything about one task: what was asked, the plan, the outcome, its cost and the chat. */
export function TaskDetail({
  task,
  canEdit,
  onClose,
}: {
  task: AgentTask;
  canEdit: boolean;
  onClose: () => void;
}) {
  const { t, i18n } = useTranslation();
  const { rerun, remove } = useTaskActions(task.workspaceId);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const elapsed = useElapsedSeconds(task);
  const tokens = spentTokens(task);
  const finished = task.status === "completed" || task.status === "failed";
  const failure = rerun.error ?? remove.error;

  return (
    <>
      <Modal
        isOpen
        onOpenChange={(open) => !open && onClose()}
        title={task.title}
        description={t("tasks.detail.description", {
          status: t(`tasks.status.${task.status}`),
          count: task.attempts,
        })}
        closeLabel={t("tasks.detail.close")}
        footer={
          canEdit && (
            <div className="flex w-full items-center justify-between gap-2">
              <Button
                variant="ghost"
                size="sm"
                disabled={task.status === "running" || remove.isPending}
                onClick={() => setConfirmDelete(true)}
              >
                <Trash2 />
                {t("tasks.detail.delete")}
              </Button>
              {finished && (
                <Button size="sm" disabled={rerun.isPending} onClick={() => rerun.mutate(task.id)}>
                  <RotateCcw />
                  {t("tasks.detail.rerun")}
                </Button>
              )}
            </div>
          )
        }
      >
        <div className="space-y-5" data-testid="task-detail">
          {task.runner && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <StatusMark status={task.status} />
              <span>{t("tasks.detail.runner", { name: task.runner })}</span>
            </div>
          )}
          {failure && <ErrorState message={failure.message} />}
          <dl className="grid grid-cols-2 gap-3 rounded-lg border border-border p-3 sm:grid-cols-4">
            <Stat label={t("tasks.detail.timeSpent")} value={formatDuration(elapsed)} />
            <Stat
              label={t("tasks.detail.tokensGenerated")}
              value={formatTokens(tokens.generated, i18n.language)}
            />
            <Stat
              label={t("tasks.detail.tokensTotal")}
              value={formatTokens(tokens.total, i18n.language)}
            />
            <Stat label={t("tasks.detail.model")} value={task.model || "—"} />
          </dl>
          {task.error && (
            <p
              role="alert"
              className="rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm text-destructive"
            >
              {task.error}
            </p>
          )}
          <Section title={t("tasks.detail.instructions")}>
            <Text testId="task-instructions">{task.instructions}</Text>
          </Section>
          {task.plan && (
            <Section title={t("tasks.detail.plan")}>
              <Report testId="task-plan">{task.plan}</Report>
            </Section>
          )}
          {task.outcome && (
            <Section title={t("tasks.detail.outcome")}>
              <Report testId="task-outcome">{task.outcome}</Report>
            </Section>
          )}
          <Chat task={task} canEdit={canEdit} />
        </div>
      </Modal>
      <ConfirmDialog
        isOpen={confirmDelete}
        title={t("tasks.detail.deleteTitle")}
        description={t("tasks.detail.deleteDescription", { title: task.title })}
        confirmLabel={t("tasks.detail.delete")}
        cancelLabel={t("tasks.detail.cancel")}
        onCancel={() => setConfirmDelete(false)}
        onConfirm={() => {
          setConfirmDelete(false);
          remove.mutate(task.id, { onSuccess: onClose });
        }}
      />
    </>
  );
}
