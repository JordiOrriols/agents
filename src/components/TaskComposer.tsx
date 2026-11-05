import React, { useId, useState, type FormEvent, type KeyboardEvent } from "react";
import { useTranslation } from "react-i18next";
import { Button, Input, Textarea } from "@jordiorriols/ui";
import { Plus } from "@jordiorriols/ui/icons";

/** One line to name the task; the instructions open up underneath once you start typing. */
export function TaskComposer({
  onCreate,
  disabled,
}: {
  onCreate: (task: { title: string; instructions: string }) => Promise<unknown>;
  disabled?: boolean;
}) {
  const { t } = useTranslation();
  const instructionsId = useId();
  const [title, setTitle] = useState("");
  const [instructions, setInstructions] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const expanded = title.length > 0 || instructions.length > 0;

  async function submit(event?: FormEvent) {
    event?.preventDefault();
    const name = title.trim();
    if (!name || saving) return;
    setSaving(true);
    setError(null);
    try {
      await onCreate({ title: name, instructions: instructions.trim() || name });
      setTitle("");
      setInstructions("");
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  }
  function submitWithShortcut(event: KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) void submit();
  }

  return (
    <form
      onSubmit={submit}
      aria-label={t("tasks.composer.label")}
      className="rounded-lg border border-border bg-card p-2 shadow-xs focus-within:border-foreground/25"
    >
      <div className="flex items-center gap-2">
        <Plus className="ml-2 size-4 shrink-0 text-muted-foreground" aria-hidden />
        <Input
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          placeholder={t("tasks.composer.title")}
          aria-label={t("tasks.composer.title")}
          maxLength={200}
          disabled={disabled}
          className="border-0 shadow-none focus-visible:ring-0"
        />
      </div>
      {expanded && (
        <div className="space-y-2 px-2 pb-1 pt-2">
          <Textarea
            id={instructionsId}
            value={instructions}
            onChange={(event) => setInstructions(event.target.value)}
            onKeyDown={submitWithShortcut}
            placeholder={t("tasks.composer.instructions")}
            aria-label={t("tasks.composer.instructions")}
            maxLength={20000}
            rows={4}
            disabled={disabled}
          />
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
          <div className="flex items-center justify-between gap-3">
            <p className="text-xs text-muted-foreground">{t("tasks.composer.hint")}</p>
            <Button type="submit" size="sm" disabled={disabled || saving || !title.trim()}>
              {t("tasks.composer.add")}
            </Button>
          </div>
        </div>
      )}
    </form>
  );
}
