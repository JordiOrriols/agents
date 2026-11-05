import React, { createContext, useContext, useMemo, type ReactNode } from "react";
import { useSupabaseAuth } from "@jordiorriols/ui/hooks";
import { createWorkspaceApi, getAuthRedirectUrl, type WorkspaceApi } from "@jordiorriols/ui";
import i18n from "@/i18n";
import { authCallback, supabase } from "./supabaseClient";
import { createTaskApi, type TaskApi } from "./tasks";

type DataContextValue = ReturnType<typeof useSupabaseAuth> & {
  workspaceApi: WorkspaceApi | null;
  taskApi: TaskApi | null;
};
const DataContext = createContext<DataContextValue | null>(null);

export function DataProvider({ children }: { children: ReactNode }) {
  const auth = useSupabaseAuth(supabase, getAuthRedirectUrl("agents"), authCallback);
  const signedIn = !!auth.user;
  const apis = useMemo(
    () =>
      supabase && signedIn
        ? { workspaceApi: createWorkspaceApi(supabase), taskApi: createTaskApi(supabase) }
        : { workspaceApi: null, taskApi: null },
    [signedIn]
  );
  return <DataContext.Provider value={{ ...auth, ...apis }}>{children}</DataContext.Provider>;
}

const unavailable = async (): Promise<never> => {
  throw new Error(i18n.t("auth.notConfigured"));
};
const fallback: DataContextValue = {
  authEnabled: false,
  user: null,
  loading: false,
  passwordRecovery: false,
  authError: null,
  linkError: null,
  workspaceApi: null,
  taskApi: null,
  signIn: unavailable,
  signInWithGitHub: unavailable,
  signUp: unavailable,
  requestPasswordReset: unavailable,
  updatePassword: unavailable,
  signOut: unavailable,
};

export function useData(): DataContextValue {
  return useContext(DataContext) ?? fallback;
}
