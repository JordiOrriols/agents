-- Planner's tables get the names the product uses: a feature belongs to a project,
-- and a member's vacations are just vacations.
alter table public.planner_team_availability rename to vacations;
alter table public.planner_projects rename to features;
alter table public.planner_main_projects rename to projects;
alter table public.features rename column main_project_id to project_id;

-- Constraints, indexes and policies follow their table's new name.
do $$
declare item record; renames constant text[][] := array[
  ['planner_team_availability', 'vacations'],
  ['planner_projects_main_project', 'features_project'],
  ['planner_projects', 'features'],
  ['planner_main_projects', 'projects']];
  pair text[];
begin
  foreach pair slice 1 in array renames loop
    for item in
      select c.conname as name, t.relname as tbl from pg_constraint c
        join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace
        where n.nspname = 'public' and t.relname in ('vacations', 'features', 'projects')
          and c.conname like pair[1] || '%'
    loop
      execute format('alter table public.%I rename constraint %I to %I', item.tbl, item.name,
        pair[2] || substr(item.name, length(pair[1]) + 1));
    end loop;
    for item in
      select indexname as name from pg_indexes
        where schemaname = 'public' and tablename in ('vacations', 'features', 'projects')
          and indexname like pair[1] || '%'
    loop
      execute format('alter index public.%I rename to %I', item.name,
        pair[2] || substr(item.name, length(pair[1]) + 1));
    end loop;
    for item in
      select policyname as name, tablename as tbl from pg_policies
        where schemaname = 'public' and tablename in ('vacations', 'features', 'projects')
          and policyname like pair[1] || '%'
    loop
      execute format('alter policy %I on public.%I rename to %I', item.name, item.tbl,
        pair[2] || substr(item.name, length(pair[1]) + 1));
    end loop;
  end loop;
end;
$$;

-- Function bodies name their tables, so the ones that touch these are written again.
drop function public.planner_set_team_availability(uuid, date, date, boolean);
create function public.planner_set_vacations(member uuid, start_date date, end_date date, working boolean)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.can_edit_member(member) then raise exception 'Team edit access required'; end if;
  if start_date is null or end_date is null or end_date < start_date or end_date - start_date > 365
    or start_date < date '2026-01-01' or end_date > date '2027-12-31'
    or working is null then raise exception 'Choose a verified date range of at most 366 days'; end if;
  if working then
    delete from public.vacations v
      where v.member_id = member and v.date between start_date and end_date and not v.is_working;
  else
    insert into public.vacations(member_id, date, is_working)
      select member, day::date, false
      from pg_catalog.generate_series(start_date::timestamp, end_date::timestamp, interval '1 day') day
      on conflict(member_id, date) do update set is_working = false;
  end if;
end;
$$;
revoke all on function public.planner_set_vacations(uuid, date, date, boolean) from public, anon;
grant execute on function public.planner_set_vacations(uuid, date, date, boolean) to authenticated;

create or replace function public.planner_vacation_save(token uuid, start_date date, end_date date, working boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare member uuid;
begin
  select m.id into member from public.members m where m.vacation_token = token;
  if member is null then raise exception 'Invalid vacation link'; end if;
  if start_date is null or end_date is null or end_date < start_date or end_date - start_date > 365
    or start_date < date '2026-01-01' or end_date > date '2027-12-31'
    or working is null then raise exception 'Choose a verified date range of at most 366 days'; end if;
  if working then
    delete from public.vacations v
      where v.member_id = member and v.date between start_date and end_date and not v.is_working;
  else
    insert into public.vacations(member_id, date, is_working)
      select member, day::date, false
      from pg_catalog.generate_series(start_date::timestamp, end_date::timestamp, interval '1 day') day
      on conflict(member_id, date) do update set is_working = false;
  end if;
end;
$$;

create or replace function public.planner_vacation_clear(token uuid, day date)
returns void language plpgsql security definer set search_path = '' as $$
declare member uuid;
begin
  select m.id into member from public.members m where m.vacation_token = token;
  if member is null then raise exception 'Invalid vacation link'; end if;
  if day is null then raise exception 'Choose a date'; end if;
  delete from public.vacations where member_id = member and date = day;
end;
$$;

create or replace function public.planner_vacation_list(token uuid)
returns table(member_id uuid, date date, is_working boolean)
language plpgsql stable security definer set search_path = '' as $$
declare member uuid;
begin
  select m.id into member from public.members m where m.vacation_token = token;
  if member is null then raise exception 'Invalid vacation link'; end if;
  return query select v.member_id, v.date, v.is_working from public.vacations v
    where v.member_id = member order by v.date;
end;
$$;

create or replace function public.planner_vacation_team_list(token uuid)
returns table(member_id uuid, date date, is_working boolean)
language plpgsql stable security definer set search_path = '' as $$
declare token_member uuid; member_team uuid;
begin
  select m.id, m.team_id into token_member, member_team
    from public.members m where m.vacation_token = token;
  if token_member is null then raise exception 'Invalid vacation link'; end if;
  return query select v.member_id, v.date, v.is_working
    from public.vacations v
    join public.members m on m.id = v.member_id
    where m.team_id = member_team and (m.id = token_member or not v.is_working)
    order by v.date, v.member_id;
end;
$$;

drop function public.planner_reorder_projects(uuid, uuid[]);
create function public.planner_reorder_features(workspace uuid, feature_ids uuid[])
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  if feature_ids is null then raise exception 'Choose features'; end if;
  perform 1 from public.planner_workspaces where id = workspace for update;
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
revoke all on function public.planner_reorder_features(uuid, uuid[]) from public, anon;
grant execute on function public.planner_reorder_features(uuid, uuid[]) to authenticated;

drop function public.planner_toggle_backlog(uuid, uuid, boolean);
create function public.planner_toggle_backlog(workspace uuid, feature uuid, included boolean)
returns public.features language plpgsql security invoker set search_path = '' as $$
declare result public.features; next_priority integer;
begin
  if not public.planner_can_edit_workspace(workspace) then raise exception 'Workspace edit access required'; end if;
  perform 1 from public.planner_workspaces where id = workspace for update;
  select coalesce(max(priority), 0) + 1 into next_priority from public.features
    where workspace_id = workspace and in_backlog;
  update public.features set in_backlog = included,
    priority = case when included and not in_backlog then next_priority else priority end
  where id = feature and workspace_id = workspace returning * into result;
  if not found then raise exception 'Feature no longer exists in this workspace'; end if;
  return result;
end;
$$;
revoke all on function public.planner_toggle_backlog(uuid, uuid, boolean) from public, anon;
grant execute on function public.planner_toggle_backlog(uuid, uuid, boolean) to authenticated;
