-- Teams stay in the workspace they are created in. Sharing, plans and surveys hang off the
-- workspace, so moving a team would silently change who can see it. A workspace that still
-- holds teams cannot be deleted either: its owner deletes the teams first.

create or replace function public.teams_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.workspace_id is distinct from old.workspace_id then
      raise exception 'Teams cannot move to another workspace' using errcode = '42501';
    end if;
    return new;
  end if;
  if new.workspace_id is null then
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

-- Deleting an account still removes its workspaces together with its teams.
drop trigger workspaces_release_teams on public.workspaces;
drop function public.workspaces_release_teams();
create function public.workspaces_keep_teams() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (
    select 1 from public.teams t
    where t.workspace_id = old.id and exists (select 1 from auth.users u where u.id = t.owner_id)
  ) then
    raise exception 'Delete the teams of this workspace first' using errcode = '23503';
  end if;
  return old;
end;
$$;
create trigger workspaces_keep_teams before delete on public.workspaces
  for each row execute function public.workspaces_keep_teams();
revoke all on function public.workspaces_keep_teams() from public, anon, authenticated;

drop function public.planner_set_workspace_teams(uuid, uuid[]);

-- New teams go straight into the chosen workspace of the caller.
create function public.create_team(p_name text, p_workspace uuid)
returns public.teams language plpgsql security definer set search_path = '' as $$
declare created_team public.teams;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not public.workspace_is_owner(p_workspace) then
    raise exception 'Only the workspace owner can add teams' using errcode = '42501';
  end if;
  insert into public.teams (owner_id, name, workspace_id)
    values (auth.uid(), trim(p_name), p_workspace)
    returning * into created_team;
  return created_team;
end;
$$;
revoke all on function public.create_team(text, uuid) from public, anon;
grant execute on function public.create_team(text, uuid) to authenticated;
