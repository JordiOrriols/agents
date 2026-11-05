-- Existing Planner rosters/availability are retained, not matched by name or deleted.
alter table public.members
  add column planning_role text check (planning_role in ('backend', 'frontend', 'design', 'qa')),
  add column vacation_token uuid not null unique default gen_random_uuid();

create function public.planner_member_vacation_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.vacation_token := gen_random_uuid();
  elsif new.vacation_token is distinct from old.vacation_token then
    raise exception 'Vacation tokens are immutable';
  end if;
  return new;
end;
$$;
create trigger planner_member_vacation_identity
before insert or update on public.members
for each row execute function public.planner_member_vacation_identity();

create table public.planner_workspace_teams (
  workspace_id uuid not null references public.planner_workspaces(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  primary key (workspace_id, team_id)
);
create index on public.planner_workspace_teams(team_id);
create table public.planner_team_availability (
  member_id uuid not null references public.members(id) on delete cascade,
  date date not null check (date between date '2026-01-01' and date '2027-12-31'),
  is_working boolean not null,
  primary key (member_id, date)
);

-- Existing workspace collaborators retain access; linked team accounts also see plans.
create or replace function public.planner_has_access(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.planner_is_owner(workspace) or exists (
    select 1 from public.planner_members where workspace_id = workspace and user_id = auth.uid()
  ) or exists (
    select 1 from public.planner_workspace_teams wt
    where wt.workspace_id = workspace and public.can_view_team(wt.team_id)
  );
$$;
create function public.planner_can_view_team_availability(member uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.members m where m.id = member and (
      public.can_view_team(m.team_id) or exists (
        select 1 from public.planner_workspace_teams wt
        where wt.team_id = m.team_id and public.planner_has_access(wt.workspace_id)
      )
    )
  );
$$;

alter table public.planner_workspace_teams enable row level security;
alter table public.planner_team_availability enable row level security;
create policy planner_workspace_teams_read on public.planner_workspace_teams
for select to authenticated using (public.planner_has_access(workspace_id));
create policy planner_team_availability_read on public.planner_team_availability
for select to authenticated using (public.planner_can_view_team_availability(member_id));
create policy planner_team_availability_write on public.planner_team_availability
for all to authenticated using (public.can_edit_member(member_id))
with check (public.can_edit_member(member_id));
grant select on public.planner_workspace_teams to authenticated;
grant select, insert, update, delete on public.planner_team_availability to authenticated;

create function public.planner_create_linked_workspace(workspace_name text)
returns public.planner_workspaces language plpgsql security definer set search_path = '' as $$
declare result public.planner_workspaces;
begin
  if not exists(select 1 from auth.users where id = auth.uid() and email_confirmed_at is not null)
    then raise exception 'Sign in with a verified email first'; end if;
  insert into public.planner_workspaces(owner_id, name)
    values(auth.uid(), trim(workspace_name)) returning * into result;
  return result;
end;
$$;

create function public.planner_set_workspace_teams(workspace uuid, team_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.planner_is_owner(workspace) then raise exception 'Only the workspace owner can link teams'; end if;
  if team_ids is null or cardinality(team_ids) <> (
    select count(distinct id) from unnest(team_ids) item(id)
  ) then raise exception 'Choose distinct Ladders teams'; end if;
  perform 1 from public.planner_workspaces where id = workspace for update;
  -- Retained links do not require fresh grants; adding a team always requires edit access.
  if exists (
    select 1 from unnest(team_ids) item(id)
    where id is null or not exists(select 1 from public.teams t where t.id = item.id)
      or (not public.can_edit_team(id) and not exists(
        select 1 from public.planner_workspace_teams wt
        where wt.workspace_id = workspace and wt.team_id = item.id
      ))
  ) then raise exception 'Team edit access required to link a new team'; end if;
  delete from public.planner_workspace_teams where workspace_id = workspace and not (team_id = any(team_ids));
  insert into public.planner_workspace_teams(workspace_id, team_id)
    select workspace, id from unnest(team_ids) item(id) on conflict do nothing;
end;
$$;
create function public.planner_linked_teams(workspace uuid)
returns table(id uuid, name text) language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.planner_has_access(workspace) then raise exception 'Workspace access required'; end if;
  return query select t.id, t.name from public.teams t
    join public.planner_workspace_teams wt on wt.team_id = t.id
    where wt.workspace_id = workspace order by t.name, t.id;
end;
$$;
create function public.planner_workspace_roster(workspace uuid)
returns table(id uuid, team_id uuid, name text, role text, can_edit boolean, vacation_token uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.planner_has_access(workspace) then raise exception 'Workspace access required'; end if;
  return query select m.id, m.team_id, m.name, m.planning_role, public.can_edit_member(m.id),
    case when public.can_edit_member(m.id) then m.vacation_token else null end
    from public.members m join public.planner_workspace_teams wt on wt.team_id = m.team_id
    where wt.workspace_id = workspace order by m.name, m.id;
end;
$$;
create function public.planner_update_planning_role(member uuid, member_role text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_edit_member(member) then raise exception 'Team edit access required'; end if;
  update public.members set planning_role = member_role where id = member;
  if not found then raise exception 'Member no longer exists'; end if;
end;
$$;
create function public.planner_set_team_availability(member uuid, start_date date, end_date date, working boolean)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.can_edit_member(member) then raise exception 'Team edit access required'; end if;
  if start_date is null or end_date is null or end_date < start_date or end_date - start_date > 365
    or start_date < date '2026-01-01' or end_date > date '2027-12-31'
    or working is null then raise exception 'Choose a verified date range of at most 366 days'; end if;
  insert into public.planner_team_availability(member_id, date, is_working)
    select member, day::date, working
    from pg_catalog.generate_series(start_date::timestamp, end_date::timestamp, interval '1 day') day
    on conflict(member_id, date) do update set is_working = excluded.is_working;
end;
$$;

-- Token capabilities expose only the named member and that member's overrides.
create function public.planner_vacation_member(token uuid)
returns table(id uuid, name text, role text)
language plpgsql stable security definer set search_path = '' as $$
begin
  return query select m.id, m.name, m.planning_role from public.members m where m.vacation_token = token;
  if not found then raise exception 'Invalid vacation link'; end if;
end;
$$;
create function public.planner_vacation_list(token uuid)
returns table(member_id uuid, date date, is_working boolean)
language plpgsql stable security definer set search_path = '' as $$
declare member uuid;
begin
  select m.id into member from public.members m where m.vacation_token = token;
  if member is null then raise exception 'Invalid vacation link'; end if;
  return query select a.member_id, a.date, a.is_working from public.planner_team_availability a
    where a.member_id = member order by a.date;
end;
$$;
create function public.planner_vacation_save(token uuid, start_date date, end_date date, working boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare member uuid;
begin
  select m.id into member from public.members m where m.vacation_token = token;
  if member is null then raise exception 'Invalid vacation link'; end if;
  if start_date is null or end_date is null or end_date < start_date or end_date - start_date > 365
    or start_date < date '2026-01-01' or end_date > date '2027-12-31'
    or working is null then raise exception 'Choose a verified date range of at most 366 days'; end if;
  insert into public.planner_team_availability(member_id, date, is_working)
    select member, day::date, working
    from pg_catalog.generate_series(start_date::timestamp, end_date::timestamp, interval '1 day') day
    on conflict(member_id, date) do update set is_working = excluded.is_working;
end;
$$;
create function public.planner_vacation_clear(token uuid, day date)
returns void language plpgsql security definer set search_path = '' as $$
declare member uuid;
begin
  select m.id into member from public.members m where m.vacation_token = token;
  if member is null then raise exception 'Invalid vacation link'; end if;
  if day is null then raise exception 'Choose a date'; end if;
  delete from public.planner_team_availability where member_id = member and date = day;
end;
$$;

revoke all on function public.planner_member_vacation_identity(),
  public.planner_can_view_team_availability(uuid), public.planner_create_linked_workspace(text),
  public.planner_set_workspace_teams(uuid,uuid[]), public.planner_linked_teams(uuid),
  public.planner_workspace_roster(uuid), public.planner_update_planning_role(uuid,text),
  public.planner_set_team_availability(uuid,date,date,boolean),
  public.planner_vacation_member(uuid), public.planner_vacation_list(uuid),
  public.planner_vacation_save(uuid,date,date,boolean), public.planner_vacation_clear(uuid,date)
from public, anon, authenticated;
grant execute on function public.planner_can_view_team_availability(uuid),
  public.planner_create_linked_workspace(text), public.planner_set_workspace_teams(uuid,uuid[]),
  public.planner_linked_teams(uuid), public.planner_workspace_roster(uuid),
  public.planner_update_planning_role(uuid,text), public.planner_set_team_availability(uuid,date,date,boolean)
to authenticated;
grant execute on function public.planner_vacation_member(uuid), public.planner_vacation_list(uuid),
  public.planner_vacation_save(uuid,date,date,boolean), public.planner_vacation_clear(uuid,date)
to anon, authenticated;
