-- Read-only Share access is scoped to the current app, not linked team membership.
create function public.list_workspace_app_shares(workspace uuid, app_name text)
returns table(user_id uuid, email text, app text, access_level text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if app_name is null or app_name not in ('planner', 'shiplog') then
    raise exception 'Invalid app' using errcode = '22023';
  end if;
  if not public.workspace_is_owner(workspace) and not exists (
    select 1 from public.workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid() and c.app = app_name
      and c.access_level in ('viewer', 'editor')
  ) then
    raise exception 'Workspace sharing access required' using errcode = '42501';
  end if;
  return query select c.user_id, c.email, c.app, c.access_level
    from public.workspace_collaborators c
    where c.workspace_id = workspace and c.app = app_name
    order by c.email, c.user_id;
end;
$$;
revoke all on function public.list_workspace_app_shares(uuid, text) from public, anon;
grant execute on function public.list_workspace_app_shares(uuid, text) to authenticated;

create or replace function public.planner_roadmap_share(workspace uuid, enabled boolean default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if enabled is not null then
    if not public.workspace_is_owner(workspace) then
      raise exception 'Workspace owner access required' using errcode = '42501';
    end if;
  elsif not public.workspace_is_owner(workspace) and not exists (
    select 1 from public.workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid() and c.app = 'planner'
      and c.access_level in ('viewer', 'editor')
  ) then
    raise exception 'Workspace sharing access required' using errcode = '42501';
  end if;
  if enabled is not null then
    perform 1 from public.workspaces where id = workspace for update;
  end if;
  if enabled = false then
    delete from public.roadmap_shares s where s.workspace_id = workspace;
    return null;
  elsif enabled = true then
    insert into public.roadmap_shares(workspace_id) values (workspace)
      on conflict (workspace_id) do nothing;
  end if;
  select s.token into result from public.roadmap_shares s where s.workspace_id = workspace;
  return result;
end;
$$;
