import React from "react";
import { useTranslation } from "react-i18next";
import { Navigate, Route, Routes } from "react-router-dom";
import { ErrorBoundary, type FallbackProps } from "react-error-boundary";
import { Button } from "@jordiorriols/ui";
import AppLayout from "./components/AppLayout";
import { EntryGate } from "./components/EntryGate";
import { PasswordResetDialog } from "./components/PasswordResetDialog";
import { DataProvider } from "./data/DataProvider";
import { WorkspaceProvider } from "./data/WorkspaceProvider";
import TasksPage from "./pages/TasksPage";

function ErrorFallback({ error, resetErrorBoundary }: FallbackProps) {
  const { t } = useTranslation();

  return (
    <div className="p-8 space-y-4">
      <h1>{t("app.errors.title")}</h1>
      <p role="alert">{error instanceof Error ? error.message : String(error)}</p>
      <Button onClick={resetErrorBoundary}>{t("app.actions.tryAgain")}</Button>
    </div>
  );
}

export default function App() {
  return (
    <ErrorBoundary FallbackComponent={ErrorFallback}>
      <DataProvider>
        <PasswordResetDialog />
        <EntryGate>
          <WorkspaceProvider>
            <Routes>
              <Route element={<AppLayout />}>
                <Route path="/" element={<TasksPage />} />
                <Route path="/tasks/:taskId" element={<TasksPage />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Route>
            </Routes>
          </WorkspaceProvider>
        </EntryGate>
      </DataProvider>
    </ErrorBoundary>
  );
}
