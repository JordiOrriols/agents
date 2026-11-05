-- Every app lists and creates workspaces the same way, so the shared workspace bar in
-- @jordiorriols/ui can drive Ladders, Planner and Pulse alike.

-- The account's access to a workspace in one app: owner, editor, viewer or null.
-- Planner also opens, read-only, the workspaces of the Ladders teams the account can view.
create function public.workspace_access(workspace uuid, app_name text)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when w.owner_id = auth.uid() then 'owner'
    else coalesce(
      (select c.access_level from public.workspace_collaborators c
        where c.workspace_id = w.id and c.user_id = auth.uid() and c.app = app_name),
      case when app_name = 'planner' and exists (
        select 1 from public.teams t where t.workspace_id = w.id and public.can_view_team(t.id)
      ) then 'viewer' end
    )
  end
  from public.workspaces w where w.id = workspace;
$$;

create function public.list_workspaces(app_name text)
returns table(id uuid, name text, owner_id uuid, access_level text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if app_name is null or app_name not in ('ladders', 'planner', 'pulse') then
    raise exception 'Invalid app';
  end if;
  return query
    select w.id, w.name, w.owner_id, access.level
    from public.workspaces w
    cross join lateral (select public.workspace_access(w.id, app_name) as level) access
    where access.level is not null
    order by lower(w.name), w.id;
end;
$$;

create function public.create_workspace(workspace_name text)
returns public.workspaces language plpgsql security definer set search_path = '' as $$
declare result public.workspaces;
begin
  if not exists(select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null)
    then raise exception 'Sign in with a verified email first'; end if;
  if workspace_name is null or length(trim(workspace_name)) not between 1 and 120
    then raise exception 'Workspace names need between 1 and 120 characters'; end if;
  insert into public.workspaces(owner_id, name)
    values(auth.uid(), trim(workspace_name)) returning * into result;
  return result;
end;
$$;

revoke all on function public.workspace_access(uuid, text), public.list_workspaces(text),
  public.create_workspace(text) from public, anon;
grant execute on function public.workspace_access(uuid, text), public.list_workspaces(text),
  public.create_workspace(text) to authenticated;
