create table public.planner_main_projects (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.planner_workspaces(id) on delete cascade,
  name text not null check (name = trim(name) and length(name) between 1 and 80),
  created_at timestamptz not null default now(),
  unique (id, workspace_id)
);
create unique index planner_main_projects_unique_name
  on public.planner_main_projects(workspace_id, lower(name));

alter table public.planner_main_projects enable row level security;
create policy planner_main_projects_read on public.planner_main_projects for select to authenticated
  using (public.planner_has_access(workspace_id));
create policy planner_main_projects_write on public.planner_main_projects for all to authenticated
  using (public.planner_can_edit_workspace(workspace_id))
  with check (public.planner_can_edit_workspace(workspace_id));
grant select, insert, update, delete on public.planner_main_projects to authenticated;

-- The composite key keeps a feature inside its workspace's project list; deleting a project
-- only clears the feature's project, never the feature's workspace.
alter table public.planner_projects
  add column main_project_id uuid,
  add constraint planner_projects_main_project_fk
    foreign key (main_project_id, workspace_id)
    references public.planner_main_projects(id, workspace_id)
    on delete set null (main_project_id);
create index on public.planner_projects(main_project_id);
