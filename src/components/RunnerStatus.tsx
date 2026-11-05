import React from "react";
import { useTranslation } from "react-i18next";
import { cn } from "@jordiorriols/ui";
import { formatRelative, isRunnerOnline, type RunnerStatus as Runner } from "@/lib/tasks";

/** Whether a local runner is checking this workspace for work. */
export function RunnerStatus({ runners }: { runners: Runner[] }) {
  const { t, i18n } = useTranslation();
  const runner = runners[0];
  const online = !!runner && isRunnerOnline(runner);
  return (
    <p
      data-testid="runner-status"
      data-online={online}
      className="flex items-center gap-2 text-xs text-muted-foreground"
    >
      <span
        aria-hidden
        className={cn(
          "size-1.5 rounded-full",
          online ? "bg-emerald-500" : "bg-muted-foreground/40"
        )}
      />
      {runner
        ? t(online ? "runner.online" : "runner.offline", {
            name: runner.name,
            time: formatRelative(runner.lastSeen, i18n.language),
          })
        : t("runner.none")}
    </p>
  );
}
