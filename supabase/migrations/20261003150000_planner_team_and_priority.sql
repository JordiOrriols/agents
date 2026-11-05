create function public.planner_toggle_backlog(workspace uuid, project uuid, included boolean)
returns public.planner_projects language plpgsql security invoker set search_path = '' as $$
declare result public.planner_projects; next_priority integer;
begin
  if not public.planner_is_owner(workspace) then raise exception 'Only the owner can change the backlog'; end if;
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
create function public.planner_update_member(member uuid, member_name text, member_role text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.planner_members set name = trim(member_name), role = member_role
  where id = member and public.planner_is_owner(workspace_id);
  if not found then raise exception 'Only the owner can edit this team member'; end if;
end;
$$;
revoke all on function public.planner_toggle_backlog(uuid,uuid,boolean),
  public.planner_update_member(uuid,text,text) from public, anon;
grant execute on function public.planner_toggle_backlog(uuid,uuid,boolean),
  public.planner_update_member(uuid,text,text) to authenticated;
