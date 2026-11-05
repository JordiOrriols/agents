create table public.roadmap_markers (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  date date not null check (date between '0001-01-01' and '9999-12-31')
);
create index roadmap_markers_workspace on public.roadmap_markers(workspace_id);
alter table public.roadmap_markers enable row level security;
grant select, insert, delete on public.roadmap_markers to authenticated;
create policy roadmap_markers_read on public.roadmap_markers for select to authenticated
  using (public.planner_has_access(workspace_id));
create policy roadmap_markers_create on public.roadmap_markers for insert to authenticated
  with check (public.planner_can_edit_workspace(workspace_id));
create policy roadmap_markers_delete on public.roadmap_markers for delete to authenticated
  using (public.planner_can_edit_workspace(workspace_id));

create or replace function public.planner_roadmap_source(token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target uuid; result jsonb;
begin
  select s.workspace_id into target from public.roadmap_shares s where s.token = $1;
  if target is null then raise exception 'Roadmap link unavailable' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'name', w.name, 'startDate', w.plan_start_date,
    'markers', coalesce((select jsonb_agg(jsonb_build_object('name', m.name, 'date', m.date)
      order by m.date, m.name, m.id)
      from public.roadmap_markers m where m.workspace_id = target), '[]'::jsonb),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name))
      from public.projects p where p.workspace_id = target), '[]'::jsonb),
    'features', coalesce((select jsonb_agg(jsonb_build_object(
      'id', f.id, 'project_id', f.project_id, 'name', f.name, 'description', '',
      'in_backlog', f.in_backlog, 'delivered', f.delivered, 'status', f.status,
      'priority', f.priority,
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
