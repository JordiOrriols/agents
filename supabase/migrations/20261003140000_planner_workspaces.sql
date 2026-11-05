-- Additive migration for the existing Ladders project. No Ladders tables are changed.
create table public.planner_workspaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 120),
  created_at timestamptz not null default now()
);
create table public.planner_members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.planner_workspaces(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  email text not null check (email = lower(trim(email)) and email like '%@%'),
  name text not null check (length(trim(name)) between 1 and 120),
  role text not null check (role in ('backend', 'frontend', 'design', 'qa')),
  unique (workspace_id, email),
  unique (workspace_id, user_id)
);
create table public.planner_projects (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.planner_workspaces(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 120),
  description text not null default '',
  in_backlog boolean not null default false,
  priority integer not null default 0,
  backend_devs numeric not null default 0 check (backend_devs between 0 and 100),
  backend_weeks numeric not null default 0 check (backend_weeks between 0 and 104),
  frontend_devs numeric not null default 0 check (frontend_devs between 0 and 100),
  frontend_weeks numeric not null default 0 check (frontend_weeks between 0 and 104),
  design_devs numeric not null default 0 check (design_devs between 0 and 100),
  design_weeks numeric not null default 0 check (design_weeks between 0 and 104),
  qa_devs numeric not null default 0 check (qa_devs between 0 and 100),
  qa_weeks numeric not null default 0 check (qa_weeks between 0 and 104),
  created_at timestamptz not null default now(),
  check ((backend_devs = 0) = (backend_weeks = 0)),
  check ((frontend_devs = 0) = (frontend_weeks = 0)),
  check ((design_devs = 0) = (design_weeks = 0)),
  check ((qa_devs = 0) = (qa_weeks = 0))
);
create table public.planner_availability (
  member_id uuid not null references public.planner_members(id) on delete cascade,
  date date not null,
  is_working boolean not null,
  primary key (member_id, date)
);
create index on public.planner_members(user_id);
create index on public.planner_members(workspace_id);
create index on public.planner_projects(workspace_id, priority);

create function public.planner_is_owner(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.planner_workspaces where id = workspace and owner_id = auth.uid());
$$;
create function public.planner_has_access(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.planner_is_owner(workspace) or exists(
    select 1 from public.planner_members where workspace_id = workspace and user_id = auth.uid()
  );
$$;
create function public.planner_can_edit_availability(member uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.planner_members where id = member and
    (user_id = auth.uid() or public.planner_is_owner(workspace_id)));
$$;
alter table public.planner_workspaces enable row level security;
alter table public.planner_members enable row level security;
alter table public.planner_projects enable row level security;
alter table public.planner_availability enable row level security;
create policy planner_workspaces_read on public.planner_workspaces for select to authenticated
  using (public.planner_has_access(id));
create policy planner_workspaces_update on public.planner_workspaces for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy planner_workspaces_delete on public.planner_workspaces for delete to authenticated
  using (owner_id = auth.uid());
create policy planner_members_read on public.planner_members for select to authenticated
  using (public.planner_has_access(workspace_id));
-- Invitations are created through the RPC, never by letting clients assign user_id.
create policy planner_members_delete on public.planner_members for delete to authenticated
  using (public.planner_is_owner(workspace_id) and user_id is distinct from auth.uid());
create policy planner_projects_read on public.planner_projects for select to authenticated
  using (public.planner_has_access(workspace_id));
create policy planner_projects_write on public.planner_projects for all to authenticated
  using (public.planner_is_owner(workspace_id)) with check (public.planner_is_owner(workspace_id));
create policy planner_availability_read on public.planner_availability for select to authenticated
  using (exists(select 1 from public.planner_members m where m.id = member_id and public.planner_has_access(m.workspace_id)));
create policy planner_availability_write on public.planner_availability for all to authenticated
  using (public.planner_can_edit_availability(member_id)) with check (public.planner_can_edit_availability(member_id));

create function public.planner_create_workspace(workspace_name text, member_name text, member_role text)
returns public.planner_workspaces language plpgsql security definer set search_path = '' as $$
declare workspace public.planner_workspaces; account_email text;
begin
  select lower(email) into account_email from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if account_email is null then raise exception 'Sign in with a verified email first'; end if;
  insert into public.planner_workspaces(owner_id, name) values(auth.uid(), trim(workspace_name)) returning * into workspace;
  insert into public.planner_members(workspace_id, user_id, email, name, role)
    values(workspace.id, auth.uid(), account_email, trim(member_name), member_role);
  return workspace;
end;
$$;
create function public.planner_invite_member(workspace uuid, member_email text, member_name text, member_role text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.planner_is_owner(workspace) then raise exception 'Only the workspace owner can invite members'; end if;
  insert into public.planner_members(workspace_id, email, name, role)
    values(workspace, lower(trim(member_email)), trim(member_name), member_role);
end;
$$;
create function public.planner_list_invitations()
returns table(member_id uuid, workspace_name text) language sql stable security definer set search_path = '' as $$
  select m.id, w.name from public.planner_members m
  join public.planner_workspaces w on w.id = m.workspace_id
  join auth.users u on u.id = auth.uid() and lower(u.email) = m.email and u.email_confirmed_at is not null
  where m.user_id is null;
$$;
create function public.planner_accept_invitation(member uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.planner_members set user_id = auth.uid()
  where id = member and user_id is null and email = (
    select lower(email) from auth.users where id = auth.uid() and email_confirmed_at is not null
  );
  if not found then raise exception 'No invitation for your verified email'; end if;
end;
$$;
create function public.planner_set_availability(member uuid, start_date date, end_date date, working boolean)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.planner_can_edit_availability(member) then raise exception 'You cannot change this member availability'; end if;
  if start_date is null or end_date is null or end_date < start_date or end_date - start_date > 365
    or working is null then raise exception 'Choose a date range of at most 366 days'; end if;
  insert into public.planner_availability(member_id, date, is_working)
  select member, day::date, working from pg_catalog.generate_series(start_date::timestamp, end_date::timestamp, interval '1 day') day
  on conflict(member_id, date) do update set is_working = excluded.is_working;
end;
$$;
create function public.planner_reorder_projects(workspace uuid, project_ids uuid[])
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.planner_is_owner(workspace) then raise exception 'Only the owner can reorder the backlog'; end if;
  -- Serialize concurrent reorders and reject incomplete/stale client lists.
  perform 1 from public.planner_workspaces where id = workspace for update;
  if cardinality(project_ids) <> (select count(*) from public.planner_projects where workspace_id = workspace and in_backlog)
    or cardinality(project_ids) <> (select count(distinct item.id) from unnest(project_ids) item(id))
    or exists(select 1 from unnest(project_ids) item(id) where not exists(
      select 1 from public.planner_projects p where p.id = item.id and p.workspace_id = workspace and p.in_backlog))
  then raise exception 'Backlog changed. Refresh before reordering.'; end if;
  update public.planner_projects p set priority = ordered.position
  from unnest(project_ids) with ordinality ordered(id, position)
  where p.id = ordered.id and p.workspace_id = workspace;
end;
$$;

grant select, update, delete on public.planner_workspaces to authenticated;
grant select, delete on public.planner_members to authenticated;
grant select, insert, update, delete on public.planner_projects, public.planner_availability to authenticated;
revoke all on function public.planner_is_owner(uuid), public.planner_has_access(uuid),
  public.planner_can_edit_availability(uuid), public.planner_create_workspace(text,text,text),
  public.planner_invite_member(uuid,text,text,text), public.planner_list_invitations(),
  public.planner_accept_invitation(uuid), public.planner_set_availability(uuid,date,date,boolean),
  public.planner_reorder_projects(uuid,uuid[]) from public, anon;
grant execute on function public.planner_is_owner(uuid), public.planner_has_access(uuid),
  public.planner_can_edit_availability(uuid), public.planner_create_workspace(text,text,text),
  public.planner_invite_member(uuid,text,text,text), public.planner_list_invitations(),
  public.planner_accept_invitation(uuid), public.planner_set_availability(uuid,date,date,boolean),
  public.planner_reorder_projects(uuid,uuid[]) to authenticated;
