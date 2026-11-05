-- Only the Edge Function reads scheduling inputs. Public visitors receive its
-- calculated, minimal projection, never staff, vacations or role estimates.
create table public.roadmap_shares (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  token uuid not null unique default gen_random_uuid()
);
alter table public.roadmap_shares enable row level security;
revoke all on public.roadmap_shares from anon, authenticated;

create function public.planner_roadmap_share(workspace uuid, enabled boolean default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if not public.planner_can_edit_workspace(workspace) then
    raise exception 'Workspace edit access required' using errcode = '42501';
  end if;
  perform 1 from public.workspaces where id = workspace for update;
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
revoke all on function public.planner_roadmap_share(uuid, boolean) from public, anon;
grant execute on function public.planner_roadmap_share(uuid, boolean) to authenticated;

create function public.planner_roadmap_source(token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target uuid; result jsonb;
begin
  select s.workspace_id into target from public.roadmap_shares s where s.token = $1;
  if target is null then raise exception 'Roadmap link unavailable' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'name', w.name, 'startDate', w.plan_start_date,
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name))
      from public.projects p where p.workspace_id = target), '[]'::jsonb),
    'features', coalesce((select jsonb_agg(jsonb_build_object(
      'id', f.id, 'project_id', f.project_id, 'name', f.name, 'description', '',
      'in_backlog', f.in_backlog, 'delivered', f.delivered, 'priority', f.priority,
      'backend_devs', f.backend_devs, 'backend_weeks', f.backend_weeks,
      'frontend_devs', f.frontend_devs, 'frontend_weeks', f.frontend_weeks,
      'design_devs', f.design_devs, 'design_weeks', f.design_weeks,
      'qa_devs', f.qa_devs, 'qa_weeks', f.qa_weeks))
      from public.features f join public.projects p on p.id = f.project_id
      where p.workspace_id = target and f.in_backlog), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object(
      'id', m.id, 'role', m.planning_role))
      from public.members m join public.teams t on t.id = m.team_id
      where t.workspace_id = target), '[]'::jsonb),
    'vacations', coalesce((select jsonb_agg(jsonb_build_object(
      'member_id', v.member_id, 'date', v.date, 'is_working', v.is_working))
      from public.vacations v join public.members m on m.id = v.member_id
      join public.teams t on t.id = m.team_id
      where t.workspace_id = target), '[]'::jsonb)
  ) into result from public.workspaces w where w.id = target;
  return result;
end;
$$;
revoke all on function public.planner_roadmap_source(uuid) from public, anon, authenticated;
grant execute on function public.planner_roadmap_source(uuid) to service_role;
