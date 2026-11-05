-- Shared workspaces: the folder Ladders, Planner and Pulse all hang their data from.
-- Every team lives in exactly one workspace, and every Planner workspace is a workspace
-- with the same id. Access still comes from team_collaborators and
-- planner_workspace_collaborators; a later migration moves sharing onto workspaces.

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 120),
  created_at timestamptz not null default now()
);
create index on public.workspaces(owner_id);
alter table public.workspaces enable row level security;
create policy workspaces_owner_read on public.workspaces for select to authenticated
  using (owner_id = auth.uid());
grant select on public.workspaces to authenticated;

-- Planner workspaces become Planner's settings for a workspace.
insert into public.workspaces(id, owner_id, name, created_at)
  select id, owner_id, name, created_at from public.planner_workspaces;
alter table public.planner_workspaces
  add constraint planner_workspaces_workspace_fkey
  foreign key (id) references public.workspaces(id) on delete cascade;

alter table public.teams add column workspace_id uuid references public.workspaces(id);

-- A team linked to exactly one Planner workspace of its own owner moves into it.
update public.teams t set workspace_id = link.workspace_id
from (
  select wt.team_id, min(wt.workspace_id::text)::uuid as workspace_id
  from public.planner_workspace_teams wt
  join public.planner_workspaces w on w.id = wt.workspace_id
  join public.teams team on team.id = wt.team_id and team.owner_id = w.owner_id
  group by wt.team_id having count(*) = 1
) link
where t.id = link.team_id;

-- Every other team gets a workspace of its own, so its current sharing carries over as is.
do $$
declare team record; created uuid;
begin
  for team in select id, owner_id, name, created_at from public.teams where workspace_id is null loop
    insert into public.workspaces(owner_id, name, created_at)
      values (team.owner_id, team.name, team.created_at) returning id into created;
    update public.teams set workspace_id = created where id = team.id;
  end loop;
end;
$$;

alter table public.teams alter column workspace_id set not null;
create index on public.teams(workspace_id);

-- New teams get a workspace named after them unless they are created inside one,
-- and teams can only live in a workspace owned by their own owner.
create function public.teams_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.workspace_id is null then
    if tg_op = 'UPDATE' then
      raise exception 'Teams must live in a workspace' using errcode = '23502';
    end if;
    insert into public.workspaces(owner_id, name) values (new.owner_id, new.name)
      returning id into new.workspace_id;
  elsif not exists (
    select 1 from public.workspaces w where w.id = new.workspace_id and w.owner_id = new.owner_id
  ) then
    raise exception 'Teams can only live in a workspace of their owner' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger teams_workspace before insert or update of workspace_id on public.teams
  for each row execute function public.teams_workspace();

-- Creating or renaming a Planner workspace keeps its workspace in step.
create function public.planner_workspaces_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.workspaces(id, owner_id, name, created_at)
      values (new.id, new.owner_id, new.name, new.created_at)
      on conflict (id) do nothing;
    if not exists (
      select 1 from public.workspaces w where w.id = new.id and w.owner_id = new.owner_id
    ) then
      raise exception 'Workspace belongs to another account' using errcode = '42501';
    end if;
  elsif new.name is distinct from old.name then
    update public.workspaces set name = new.name where id = new.id;
  end if;
  return new;
end;
$$;
create trigger planner_workspaces_sync before insert or update of name on public.planner_workspaces
  for each row execute function public.planner_workspaces_sync();

revoke all on function public.teams_workspace(), public.planner_workspaces_sync() from public;
