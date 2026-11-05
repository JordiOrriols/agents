-- Owners manage the catalog; explicit app collaborators may read an existing link.
create or replace function public.shiplog_portal(workspace uuid, enabled boolean default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if enabled is not null then
    if not public.workspace_is_owner(workspace) then
      raise exception 'Workspace owner access required' using errcode = '42501';
    end if;
  elsif not public.workspace_is_owner(workspace) and not exists (
    select 1 from public.workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid() and c.app = 'shiplog'
      and c.access_level in ('viewer', 'editor')
  ) then
    raise exception 'Workspace sharing access required' using errcode = '42501';
  end if;
  if enabled is not null then
    perform 1 from public.workspaces where id = workspace for update;
  end if;
  if enabled = false then
    delete from public.shiplog_portals p where p.workspace_id = workspace;
    return null;
  elsif enabled = true then
    insert into public.shiplog_portals(workspace_id) values (workspace)
      on conflict (workspace_id) do nothing;
  end if;
  select p.token into result from public.shiplog_portals p where p.workspace_id = workspace;
  return result;
end;
$$;
