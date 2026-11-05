import React from "react";
import { useTranslation } from "react-i18next";
import { CircleCheck, CircleDashed, CircleX, LoaderCircle } from "@jordiorriols/ui/icons";
import { cn } from "@jordiorriols/ui";
import type { TaskStatus } from "@/lib/tasks";

const marks = {
  pending: { icon: CircleDashed, className: "text-muted-foreground" },
  running: { icon: LoaderCircle, className: "animate-spin text-cyan-600" },
  completed: { icon: CircleCheck, className: "text-emerald-600" },
  failed: { icon: CircleX, className: "text-destructive" },
} as const;

export function StatusMark({ status, className }: { status: TaskStatus; className?: string }) {
  const { t } = useTranslation();
  const { icon: Icon, className: tone } = marks[status];
  return (
    <Icon
      role="img"
      aria-label={t(`tasks.status.${status}`)}
      data-status={status}
      className={cn("size-4 shrink-0", tone, className)}
    />
  );
}
