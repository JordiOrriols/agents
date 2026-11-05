-- Features move from a delivered flag to a workflow status. `delivered` stays in
-- sync (done <=> delivered) so already deployed clients keep working; drop it
-- once every client reads `status`.
alter table public.features
  add column status text not null default 'pending'
  constraint features_status_check check (status in ('pending', 'in_progress', 'done', 'paused'));
update public.features set status = 'done' where delivered;

create function public.features_sync_status() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.delivered and new.status = 'pending' then new.status := 'done'; end if;
  elsif new.status is not distinct from old.status
    and new.delivered is distinct from old.delivered then
    new.status := case
      when new.delivered then 'done'
      when old.status = 'done' then 'pending'
      else old.status end;
  end if;
  new.delivered := new.status = 'done';
  return new;
end;
$$;
create trigger features_sync_status before insert or update on public.features
  for each row execute function public.features_sync_status();

create or replace function public.planner_roadmap_source(token uuid)
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
