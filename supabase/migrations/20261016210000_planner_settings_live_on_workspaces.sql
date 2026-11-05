-- Planner workspaces merge into workspaces: the plan and sprint settings move onto the
-- shared workspace, Planner data hangs from it directly, and planner_workspaces goes away.

alter table public.workspaces
  add column plan_start_date date not null default current_date,
  add column sprint_start_date date not null default current_date,
  add column sprint_history jsonb not null default '[]'::jsonb,
  -- Workspaces created only to hold a team disappear once nothing is left in them.
  add column created_for_team boolean not null default false;

update public.workspaces w set
  plan_start_date = p.plan_start_date,
  sprint_start_date = p.sprint_start_date,
  sprint_history = p.sprint_history
from public.planner_workspaces p where p.id = w.id;
update public.workspaces w set created_for_team = true
  where not exists (select 1 from public.planner_workspaces p where p.id = w.id);

alter table public.features drop constraint features_workspace_id_fkey,
  add constraint features_workspace_id_fkey foreign key (workspace_id)
    references public.workspaces(id) on delete cascade;
alter table public.projects drop constraint projects_workspace_id_fkey,
  add constraint projects_workspace_id_fkey foreign key (workspace_id)
    references public.workspaces(id) on delete cascade;
alter table public.planner_workspace_collaborators
  drop constraint planner_workspace_collaborators_workspace_id_fkey,
  add constraint planner_workspace_collaborators_workspace_id_fkey foreign key (workspace_id)
    references public.workspaces(id) on delete cascade;

create trigger planner_sprint_calibration_valid
  before insert or update of sprint_start_date, sprint_history on public.workspaces
  for each row execute function public.planner_validate_sprint_calibration();
create trigger workspaces_identity before update on public.workspaces
  for each row execute function public.planner_workspace_identity();

create or replace function public.planner_is_owner(workspace uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.workspaces where id = workspace and owner_id = auth.uid());
$$;

drop function public.planner_create_linked_workspace(text);
create function public.planner_create_linked_workspace(workspace_name text)
returns public.workspaces language plpgsql security definer set search_path = '' as $$
declare result public.workspaces;
begin
  if not exists(select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null)
    then raise exception 'Sign in with a verified email first'; end if;
  insert into public.workspaces(owner_id, name)
    values(auth.uid(), trim(workspace_name)) returning * into result;
  return result;
end;
$$;
revoke all on function public.planner_create_linked_workspace(text) from public, anon;
grant execute on function public.planner_create_linked_workspace(text) to authenticated;

create or replace function public.planner_reorder_features(workspace uuid, feature_ids uuid[])
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  if feature_ids is null then raise exception 'Choose features'; end if;
  perform 1 from public.workspaces where id = workspace for update;
  if cardinality(feature_ids) <> (select count(*) from public.features where workspace_id = workspace and in_backlog)
    or cardinality(feature_ids) <> (select count(distinct item.id) from unnest(feature_ids) item(id))
    or exists(select 1 from unnest(feature_ids) item(id) where not exists(
      select 1 from public.features f where f.id = item.id and f.workspace_id = workspace and f.in_backlog))
  then raise exception 'Roadmap changed. Refresh before reordering.'; end if;
  update public.features f set priority = ordered.position
    from unnest(feature_ids) with ordinality ordered(id, position)
    where f.id = ordered.id and f.workspace_id = workspace;
end;
$$;

create or replace function public.planner_toggle_backlog(workspace uuid, feature uuid, included boolean)
returns public.features language plpgsql security invoker set search_path = '' as $$
declare result public.features; next_priority integer;
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  perform 1 from public.workspaces where id = workspace for update;
  select coalesce(max(priority), 0) + 1 into next_priority from public.features
    where workspace_id = workspace and in_backlog;
  update public.features set in_backlog = included,
    priority = case when included and not in_backlog then next_priority else priority end
  where id = feature and workspace_id = workspace returning * into result;
  if not found then raise exception 'Feature no longer exists in this workspace'; end if;
  return result;
end;
$$;

create or replace function public.teams_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.workspace_id is null then
    if tg_op = 'UPDATE' then
      raise exception 'Teams must live in a workspace' using errcode = '23502';
    end if;
    insert into public.workspaces(owner_id, name, created_for_team) values (new.owner_id, new.name, true)
      returning id into new.workspace_id;
  elsif not exists (
    select 1 from public.workspaces w where w.id = new.workspace_id and w.owner_id = new.owner_id
  ) then
    raise exception 'Teams can only live in a workspace of their owner' using errcode = '42501';
  end if;
  return new;
end;
$$;

create or replace function public.planner_set_workspace_teams(workspace uuid, team_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare team record; own uuid;
begin
  if not public.planner_is_owner(workspace) then raise exception 'Only the workspace owner can link teams'; end if;
  if team_ids is null or cardinality(team_ids) <> (
    select count(distinct id) from unnest(team_ids) item(id)
  ) then raise exception 'Choose distinct Ladders teams'; end if;
  perform 1 from public.workspaces where id = workspace for update;
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
    insert into public.workspaces(owner_id, name, created_for_team)
      values (team.owner_id, team.name, true) returning id into own;
    update public.teams set workspace_id = own where id = team.id;
  end loop;
  update public.teams set workspace_id = workspace
    where id = any(team_ids) and workspace_id <> workspace;
end;
$$;

-- Only direct team moves clean up; moves made while a workspace is being deleted must not
-- delete that same workspace from inside its own delete.
create or replace function public.teams_release_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  delete from public.workspaces w
    where w.id = old.workspace_id and w.created_for_team
      and not exists (select 1 from public.teams t where t.workspace_id = w.id)
      and not exists (select 1 from public.features f where f.workspace_id = w.id)
      and not exists (select 1 from public.projects p where p.workspace_id = w.id)
      and not exists (select 1 from public.planner_workspace_collaborators c where c.workspace_id = w.id);
  return null;
end;
$$;

-- Deleting a workspace never deletes or strands its teams: each moves to a workspace of its own.
create function public.workspaces_release_teams() returns trigger
language plpgsql security definer set search_path = '' as $$
declare team record; own uuid;
begin
  for team in
    select t.id, t.owner_id, t.name from public.teams t
    where t.workspace_id = old.id and exists (select 1 from auth.users u where u.id = t.owner_id)
  loop
    insert into public.workspaces(owner_id, name, created_for_team)
      values (team.owner_id, team.name, true) returning id into own;
    update public.teams set workspace_id = own where id = team.id;
  end loop;
  return old;
end;
$$;
create trigger workspaces_release_teams before delete on public.workspaces
  for each row execute function public.workspaces_release_teams();
revoke all on function public.workspaces_release_teams() from public;

drop policy workspaces_owner_read on public.workspaces;
create policy workspaces_read on public.workspaces for select to authenticated
  using (public.planner_has_access(id));
create policy workspaces_update on public.workspaces for update to authenticated
  using (public.planner_can_edit_workspace(id)) with check (public.planner_can_edit_workspace(id));
create policy workspaces_delete on public.workspaces for delete to authenticated
  using (owner_id = auth.uid());
revoke all on public.workspaces from anon;
revoke insert, update, delete, truncate on public.workspaces from authenticated;
grant update (name, plan_start_date, sprint_start_date, sprint_history), delete
  on public.workspaces to authenticated;

drop table public.planner_workspaces;
drop function public.planner_workspaces_sync();
