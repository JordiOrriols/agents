import React, { type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { AppSkeleton } from "@jordiorriols/ui";
import { useData } from "@/data/DataProvider";
import { WelcomePage } from "@/pages/WelcomePage";

/** Signed-out visitors land on the welcome page; everything else needs an account. */
export function EntryGate({ children }: { children: ReactNode }) {
  const { t } = useTranslation();
  const { user, loading } = useData();
  if (loading) return <AppSkeleton label={t("app.loading")} />;
  if (!user) return <WelcomePage />;
  return children;
}
