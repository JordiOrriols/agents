-- A team now lives in exactly one workspace, so the Planner link table goes away and a
-- workspace's teams are simply the teams whose workspace_id points at it.

create or replace function public.planner_has_access(workspace uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.planner_is_owner(workspace) or exists (
    select 1 from public.planner_workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid()
  ) or exists (
    select 1 from public.teams t
    where t.workspace_id = workspace and public.can_view_team(t.id)
  );
$$;

create or replace function public.planner_can_view_team_availability(member uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.members m join public.teams t on t.id = m.team_id
    where m.id = member and (public.can_view_team(t.id) or public.planner_has_access(t.workspace_id))
  );
$$;

create or replace function public.planner_linked_teams(workspace uuid)
returns table(id uuid, name text) language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.planner_has_access(workspace) then raise exception 'Workspace access required'; end if;
  return query select t.id, t.name from public.teams t
    where t.workspace_id = workspace order by t.name, t.id;
end;
$$;

create or replace function public.planner_workspace_roster(workspace uuid)
returns table(id uuid, team_id uuid, name text, role text, can_edit boolean, vacation_token uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.planner_has_access(workspace) then raise exception 'Workspace access required'; end if;
  return query select m.id, m.team_id, m.name, m.planning_role, public.can_edit_member(m.id),
    case when public.can_edit_member(m.id) then m.vacation_token else null end
    from public.members m join public.teams t on t.id = m.team_id
    where t.workspace_id = workspace order by m.name, m.id;
end;
$$;

-- Choosing a team moves it here from wherever it was; a team that is no longer chosen
-- moves to a new workspace named after it, so it never ends up without one.
create or replace function public.planner_set_workspace_teams(workspace uuid, team_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare team record; own uuid;
begin
  if not public.planner_is_owner(workspace) then raise exception 'Only the workspace owner can link teams'; end if;
  if team_ids is null or cardinality(team_ids) <> (
    select count(distinct id) from unnest(team_ids) item(id)
  ) then raise exception 'Choose distinct Ladders teams'; end if;
  perform 1 from public.planner_workspaces where id = workspace for update;
  if exists (
    select 1 from unnest(team_ids) item(id)
    where id is null or not exists(
      select 1 from public.teams t where t.id = item.id and t.owner_id = auth.uid()
    )
  ) then raise exception 'You can only move your own teams into a workspace' using errcode = '42501'; end if;
  for team in
    select t.id, t.owner_id, t.name from public.teams t
    where t.workspace_id = workspace and not (t.id = any(team_ids))
  loop
    insert into public.workspaces(owner_id, name) values (team.owner_id, team.name) returning id into own;
    update public.teams set workspace_id = own where id = team.id;
  end loop;
  update public.teams set workspace_id = workspace
    where id = any(team_ids) and workspace_id <> workspace;
end;
$$;

-- A workspace that only existed to hold a team goes away once that team leaves it.
create function public.teams_release_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.workspaces w
    where w.id = old.workspace_id
      and not exists (select 1 from public.teams t where t.workspace_id = w.id)
      and not exists (select 1 from public.planner_workspaces p where p.id = w.id);
  return null;
end;
$$;
create trigger teams_release_workspace after delete or update of workspace_id on public.teams
  for each row execute function public.teams_release_workspace();
revoke all on function public.teams_release_workspace() from public;

drop table public.planner_workspace_teams;
