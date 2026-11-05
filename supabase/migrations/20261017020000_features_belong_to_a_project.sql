-- Every feature belongs to a project, and reaches its workspace through that project.
-- Features that had none move into a "General" project of their workspace.

insert into public.projects(workspace_id, name)
  select distinct f.workspace_id, 'General' from public.features f
  where f.project_id is null
    and not exists (
      select 1 from public.projects p where p.workspace_id = f.workspace_id and lower(p.name) = 'general'
    );
update public.features f set project_id = p.id
  from public.projects p
  where f.project_id is null and p.workspace_id = f.workspace_id and lower(p.name) = 'general';

create function public.project_workspace(project uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select workspace_id from public.projects where id = project;
$$;
revoke all on function public.project_workspace(uuid) from public, anon;
grant execute on function public.project_workspace(uuid) to authenticated;

drop policy features_read on public.features;
drop policy features_write on public.features;
alter table public.features drop constraint features_project_fk;
drop index public.features_workspace_id_priority_idx;
alter table public.features drop column workspace_id;
alter table public.features alter column project_id set not null,
  add constraint features_project_id_fkey foreign key (project_id)
    references public.projects(id) on delete cascade;
alter table public.projects drop constraint projects_id_workspace_id_key;

-- A project with features cannot be deleted on its own; deleting its workspace still removes everything.
create function public.projects_keep_features() returns trigger
language plpgsql set search_path = '' as $$
begin
  if pg_trigger_depth() = 1 and exists (select 1 from public.features where project_id = old.id) then
    raise exception 'Move or delete the features of this project first';
  end if;
  return old;
end;
$$;
create trigger projects_keep_features before delete on public.projects
  for each row execute function public.projects_keep_features();

create policy features_read on public.features for select to authenticated
  using (public.planner_has_access(public.project_workspace(project_id)));
create policy features_write on public.features for all to authenticated
  using (public.planner_can_edit_workspace(public.project_workspace(project_id)))
  with check (public.planner_can_edit_workspace(public.project_workspace(project_id)));

create or replace function public.planner_reorder_features(workspace uuid, feature_ids uuid[])
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  if feature_ids is null then raise exception 'Choose features'; end if;
  perform 1 from public.workspaces where id = workspace for update;
  if cardinality(feature_ids) <> (
      select count(*) from public.features f join public.projects p on p.id = f.project_id
      where p.workspace_id = workspace and f.in_backlog)
    or cardinality(feature_ids) <> (select count(distinct item.id) from unnest(feature_ids) item(id))
    or exists(select 1 from unnest(feature_ids) item(id) where not exists(
      select 1 from public.features f join public.projects p on p.id = f.project_id
      where f.id = item.id and p.workspace_id = workspace and f.in_backlog))
  then raise exception 'Roadmap changed. Refresh before reordering.'; end if;
  update public.features f set priority = ordered.position
    from unnest(feature_ids) with ordinality ordered(id, position)
    where f.id = ordered.id;
end;
$$;

drop function public.planner_toggle_backlog(uuid, uuid, boolean);
create function public.planner_toggle_backlog(workspace uuid, feature uuid, included boolean)
returns public.features language plpgsql security invoker set search_path = '' as $$
declare result public.features; next_priority integer;
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  perform 1 from public.workspaces where id = workspace for update;
  select coalesce(max(f.priority), 0) + 1 into next_priority
    from public.features f join public.projects p on p.id = f.project_id
    where p.workspace_id = workspace and f.in_backlog;
  update public.features f set in_backlog = included,
    priority = case when included and not f.in_backlog then next_priority else f.priority end
  from public.projects p
  where f.id = feature and p.id = f.project_id and p.workspace_id = workspace
  returning f.* into result;
  if not found then raise exception 'Feature no longer exists in this workspace'; end if;
  return result;
end;
$$;
revoke all on function public.planner_toggle_backlog(uuid, uuid, boolean) from public, anon;
grant execute on function public.planner_toggle_backlog(uuid, uuid, boolean) to authenticated;

create or replace function public.teams_release_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  delete from public.workspaces w
    where w.id = old.workspace_id and w.created_for_team
      and not exists (select 1 from public.teams t where t.workspace_id = w.id)
      and not exists (select 1 from public.projects p where p.workspace_id = w.id);
  return null;
end;
$$;
