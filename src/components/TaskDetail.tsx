import React, { useState, type FormEvent, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { Button, ConfirmDialog, ErrorState, Modal, Textarea, cn } from "@jordiorriols/ui";
import { RotateCcw, Trash2 } from "@jordiorriols/ui/icons";
import { useTaskActions, useTaskMessages } from "@/hooks/useTasks";
import { formatDuration, formatTokens, type AgentTask } from "@/lib/tasks";
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

function Chat({ task, canEdit }: { task: AgentTask; canEdit: boolean }) {
  const { t } = useTranslation();
  const { data: messages = [] } = useTaskMessages(task);
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
              {item.body}
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
            <Stat label={t("tasks.detail.timeSpent")} value={formatDuration(task.secondsSpent)} />
            <Stat
              label={t("tasks.detail.tokensGenerated")}
              value={formatTokens(task.tokensGenerated, i18n.language)}
            />
            <Stat
              label={t("tasks.detail.tokensTotal")}
              value={formatTokens(task.tokensTotal, i18n.language)}
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
              <Text testId="task-plan">{task.plan}</Text>
            </Section>
          )}
          {task.outcome && (
            <Section title={t("tasks.detail.outcome")}>
              <Text testId="task-outcome">{task.outcome}</Text>
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
