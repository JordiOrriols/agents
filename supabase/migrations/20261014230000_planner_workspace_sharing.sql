create table public.planner_workspace_collaborators (
  workspace_id uuid not null references public.planner_workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null,
  access_level text not null check (access_level in ('viewer', 'editor')),
  primary key (workspace_id, user_id)
);
create index on public.planner_workspace_collaborators(user_id);
alter table public.planner_workspace_collaborators enable row level security;

create or replace function public.planner_has_access(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.planner_is_owner(workspace) or exists (
    select 1 from public.planner_workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid()
  ) or exists (
    select 1 from public.planner_members where workspace_id = workspace and user_id = auth.uid()
  ) or exists (
    select 1 from public.planner_workspace_teams wt
    where wt.workspace_id = workspace and public.can_view_team(wt.team_id)
  );
$$;
create function public.planner_can_edit_workspace(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.planner_is_owner(workspace) or exists (
    select 1 from public.planner_workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid() and c.access_level = 'editor'
  );
$$;

create function public.planner_workspace_identity() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id or new.owner_id is distinct from old.owner_id
    or new.created_at is distinct from old.created_at then
    raise exception 'Workspace identity is immutable';
  end if;
  return new;
end;
$$;
create trigger planner_workspace_identity before update on public.planner_workspaces
for each row execute function public.planner_workspace_identity();

alter policy planner_workspaces_update on public.planner_workspaces
  using (public.planner_can_edit_workspace(id)) with check (public.planner_can_edit_workspace(id));
alter policy planner_projects_write on public.planner_projects
  using (public.planner_can_edit_workspace(workspace_id))
  with check (public.planner_can_edit_workspace(workspace_id));

create function public.planner_list_workspace_shares(workspace uuid)
returns table(user_id uuid, email text, access_level text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.planner_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  return query select c.user_id, c.email, c.access_level
    from public.planner_workspace_collaborators c where c.workspace_id = workspace
    order by c.email, c.user_id;
end;
$$;
create function public.planner_share_workspace(workspace uuid, account_email text, access text)
returns void language plpgsql security definer set search_path = '' as $$
declare account uuid; normalized_email text := lower(trim(account_email));
begin
  if not public.planner_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  if access is null or access not in ('viewer', 'editor') then raise exception 'Invalid access level'; end if;
  select u.id into account from auth.users u where lower(u.email) = normalized_email;
  if account is null or account = auth.uid() then raise exception 'User not found or cannot share workspace'; end if;
  insert into public.planner_workspace_collaborators(workspace_id, user_id, email, access_level)
    values(workspace, account, normalized_email, access)
    on conflict(workspace_id, user_id) do update set email = excluded.email, access_level = excluded.access_level;
end;
$$;
create function public.planner_update_workspace_share(workspace uuid, account uuid, access text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.planner_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  if access is null or access not in ('viewer', 'editor') then raise exception 'Invalid access level'; end if;
  update public.planner_workspace_collaborators c set access_level = access
    where c.workspace_id = workspace and c.user_id = account;
  if not found then raise exception 'Workspace share not found'; end if;
end;
$$;
create function public.planner_remove_workspace_share(workspace uuid, account uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.planner_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  delete from public.planner_workspace_collaborators c where c.workspace_id = workspace and c.user_id = account;
  if not found then raise exception 'Workspace share not found'; end if;
end;
$$;

create or replace function public.planner_toggle_backlog(workspace uuid, project uuid, included boolean)
returns public.planner_projects language plpgsql security invoker set search_path = '' as $$
declare result public.planner_projects; next_priority integer;
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  perform 1 from public.planner_workspaces where id = workspace for update;
  select coalesce(max(priority), 0) + 1 into next_priority from public.planner_projects
    where workspace_id = workspace and in_backlog;
  update public.planner_projects set in_backlog = included,
    priority = case when included and not in_backlog then next_priority else priority end
  where id = project and workspace_id = workspace returning * into result;
  if not found then raise exception 'Project no longer exists in this workspace'; end if;
  return result;
end;
$$;
create or replace function public.planner_reorder_projects(workspace uuid, project_ids uuid[])
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  if project_ids is null then raise exception 'Choose projects'; end if;
  perform 1 from public.planner_workspaces where id = workspace for update;
  if cardinality(project_ids) <> (select count(*) from public.planner_projects where workspace_id = workspace and in_backlog)
    or cardinality(project_ids) <> (select count(distinct item.id) from unnest(project_ids) item(id))
    or exists(select 1 from unnest(project_ids) item(id) where not exists(
      select 1 from public.planner_projects p where p.id = item.id and p.workspace_id = workspace and p.in_backlog))
  then raise exception 'Backlog changed. Refresh before reordering.'; end if;
  update public.planner_projects p set priority = ordered.position
    from unnest(project_ids) with ordinality ordered(id, position)
    where p.id = ordered.id and p.workspace_id = workspace;
end;
$$;

revoke all on function public.planner_can_edit_workspace(uuid), public.planner_workspace_identity(),
  public.planner_list_workspace_shares(uuid), public.planner_share_workspace(uuid,text,text),
  public.planner_update_workspace_share(uuid,uuid,text), public.planner_remove_workspace_share(uuid,uuid)
  from public, anon;
grant execute on function public.planner_can_edit_workspace(uuid), public.planner_list_workspace_shares(uuid),
  public.planner_share_workspace(uuid,text,text), public.planner_update_workspace_share(uuid,uuid,text),
  public.planner_remove_workspace_share(uuid,uuid) to authenticated;
