import React, { createContext, useContext, type ReactNode } from "react";
import { useWorkspaceList } from "@jordiorriols/ui/hooks";
import { useData } from "./DataProvider";

type WorkspaceContextValue = ReturnType<typeof useWorkspaceList>;
const WorkspaceContext = createContext<WorkspaceContextValue | null>(null);

/** The Agents workspaces of the signed-in account and the one currently open. */
export function WorkspaceProvider({ children }: { children: ReactNode }) {
  const { workspaceApi } = useData();
  const list = useWorkspaceList(workspaceApi, "agents");
  return <WorkspaceContext.Provider value={list}>{children}</WorkspaceContext.Provider>;
}

const fallback: WorkspaceContextValue = {
  workspaces: [],
  workspace: null,
  select: () => undefined,
  refresh: async () => undefined,
  error: null,
  loading: false,
};

export function useWorkspace(): WorkspaceContextValue {
  return useContext(WorkspaceContext) ?? fallback;
}
