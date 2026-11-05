-- A team member can be linked to the account of the person it describes. The owner copies a
-- one-time invite from the member, the person opens it signed in and claims it. Claiming
-- shares the workspace in Planner and Pulse as a viewer (the owner can change that later);
-- in Ladders the person only reaches their own member page, and in Planner they edit their
-- own vacations.

alter table public.members add column user_id uuid references auth.users(id) on delete set null;
create unique index members_one_account_per_team on public.members(team_id, user_id)
  where user_id is not null;
create index on public.members(user_id);

-- Kept apart from members so that team viewers, who read member rows, never see invites.
create table public.member_invites (
  member_id uuid primary key references public.members(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.member_invites enable row level security;
revoke all on public.member_invites from anon, authenticated;

create function public.is_linked_member(member uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.members m where m.id = member and m.user_id = auth.uid());
$$;

-- Only claim_member_invite links an account; editors may only clear a link.
create or replace function public.members_before_insert()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_owner_id uuid;
begin
  if new.team_id is null then
    select t.id into new.team_id
    from teams t
    where t.owner_id = auth.uid() and t.is_default
    limit 1;
  end if;

  if new.team_id is null or not public.can_edit_team(new.team_id) then
    raise exception 'team edit access required' using errcode = '42501';
  end if;

  select t.owner_id into v_owner_id from teams t where t.id = new.team_id;
  new.owner_id := v_owner_id;
  new.self_token := gen_random_uuid();
  new.peer_token := gen_random_uuid();
  new.view_token := gen_random_uuid();
  new.view_enabled := coalesce(new.view_enabled, false);
  new.user_id := null;
  return new;
end;
$$;

create or replace function public.members_before_update()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_new_owner_id uuid;
begin
  if new.owner_id is distinct from old.owner_id
    or new.self_token is distinct from old.self_token
    or new.peer_token is distinct from old.peer_token
    or new.view_token is distinct from old.view_token
    or new.id is distinct from old.id then
    raise exception 'owner, id and share tokens are immutable';
  end if;

  if new.user_id is distinct from old.user_id and new.user_id is not null
    and current_setting('members.claiming', true) is distinct from new.id::text then
    raise exception 'Members are linked to an account only through an invite' using errcode = '42501';
  end if;

  if new.team_id is distinct from old.team_id then
    if not public.can_edit_team(old.team_id) or not public.can_edit_team(new.team_id) then
      raise exception 'both teams require edit access' using errcode = '42501';
    end if;
    select t.owner_id into v_new_owner_id from teams t where t.id = new.team_id;
    if v_new_owner_id is distinct from old.owner_id then
      raise exception 'members cannot move across team owners' using errcode = '42501';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- Creates (or replaces) the member's invite and returns its token.
create function public.create_member_invite(member uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if not public.can_edit_member(member) then raise exception 'Team edit access required'; end if;
  if exists (select 1 from public.members m where m.id = member and m.user_id is not null) then
    raise exception 'This member is already linked to an account';
  end if;
  insert into public.member_invites(member_id, created_by) values (member, auth.uid())
    on conflict (member_id) do update
      set token = gen_random_uuid(), created_by = excluded.created_by, created_at = now()
    returning token into result;
  return result;
end;
$$;

-- What an invite is for, so the person can check it before claiming it.
create function public.member_invite(invite uuid)
returns table(member_name text, workspace_id uuid, workspace_name text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  return query select m.name, w.id, w.name
    from public.member_invites i
    join public.members m on m.id = i.member_id
    join public.teams t on t.id = m.team_id
    join public.workspaces w on w.id = t.workspace_id
    where i.token = invite and i.created_at > now() - interval '30 days';
  if not found then raise exception 'This invite is no longer valid'; end if;
end;
$$;

create function public.claim_member_invite(invite uuid)
returns table(member_id uuid, workspace_id uuid)
language plpgsql security definer set search_path = '' as $$
declare
  target public.members;
  workspace public.workspaces;
  account_email text;
begin
  select u.email into account_email from auth.users u
    where u.id = auth.uid() and u.email_confirmed_at is not null;
  if account_email is null then raise exception 'Sign in with a verified email first'; end if;
  select m.* into target from public.member_invites i join public.members m on m.id = i.member_id
    where i.token = invite and i.created_at > now() - interval '30 days'
    for update of m;
  if target.id is null then raise exception 'This invite is no longer valid'; end if;
  if exists (select 1 from public.members m
      where m.team_id = target.team_id and m.user_id = auth.uid() and m.id <> target.id) then
    raise exception 'Your account is already linked to another member of this team';
  end if;
  select w.* into workspace from public.workspaces w join public.teams t on t.workspace_id = w.id
    where t.id = target.team_id;

  perform set_config('members.claiming', target.id::text, true);
  update public.members m set user_id = auth.uid() where m.id = target.id;
  perform set_config('members.claiming', '', true);
  delete from public.member_invites i where i.member_id = target.id;

  if workspace.owner_id <> auth.uid() then
    insert into public.workspace_collaborators(workspace_id, user_id, email, app, access_level)
      select workspace.id, auth.uid(), lower(account_email), app, 'viewer'
      from unnest(array['planner', 'pulse']) app
      on conflict on constraint workspace_collaborators_pkey do nothing;
  end if;
  return query select target.id, workspace.id;
end;
$$;

-- Unlinks the account. Its workspace shares stay until the owner changes them.
create function public.unlink_member(member uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.can_edit_member(member) then raise exception 'Team edit access required'; end if;
  update public.members m set user_id = null where m.id = member;
end;
$$;

-- Whether a member has a pending invite or a linked account, for the people who manage it.
create function public.member_links(team uuid)
returns table(member_id uuid, linked boolean, invited boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.can_edit_team(team) then raise exception 'Team edit access required'; end if;
  return query select m.id, m.user_id is not null,
      exists (select 1 from public.member_invites i
        where i.member_id = m.id and i.created_at > now() - interval '30 days')
    from public.members m where m.team_id = team order by m.id;
end;
$$;

-- The member the signed-in account is linked to in a workspace.
create function public.my_member(workspace uuid)
returns table(id uuid, name text, view_token uuid)
language sql stable security definer set search_path = '' as $$
  select m.id, m.name, m.view_token
  from public.members m join public.teams t on t.id = m.team_id
  where t.workspace_id = workspace and m.user_id = auth.uid()
  order by m.created_at, m.id limit 1;
$$;

-- Ladders lists the workspace of a linked member even without a share, as 'member'.
create or replace function public.workspace_access(workspace uuid, app_name text)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when w.owner_id = auth.uid() then 'owner'
    else coalesce(
      (select c.access_level from public.workspace_collaborators c
        where c.workspace_id = w.id and c.user_id = auth.uid() and c.app = app_name),
      case when app_name = 'planner' and exists (
        select 1 from public.teams t where t.workspace_id = w.id and public.can_view_team(t.id)
      ) then 'viewer' end,
      case when app_name = 'ladders' and exists (
        select 1 from public.teams t join public.members m on m.team_id = t.id
        where t.workspace_id = w.id and m.user_id = auth.uid()
      ) then 'member' end
    )
  end
  from public.workspaces w where w.id = workspace;
$$;

-- A linked person always reaches their own view page, shared or not.
create or replace function public.public_view(p_token uuid)
returns setof public.evaluations language sql stable security definer set search_path = '' as $$
  select e.id, e.member_id, e.kind, e.status, e.author_name, e.current_levels,
    e.goal_levels, coalesce((
      select jsonb_object_agg(comment.key, comment.value)
      from jsonb_each(e.comments) comment
      where coalesce((e.comment_visibility ->> comment.key)::boolean, e.kind <> 'peer')
    ), '{}'::jsonb), e.created_at, '{}'::jsonb
  from public.evaluations e join public.members m on m.id = e.member_id
  where m.view_token = p_token and (m.view_enabled or m.user_id = auth.uid())
    and (e.kind = 'self' or e.status = 'published')
  order by e.created_at desc;
$$;

create or replace function public.resolve_token(p_token uuid)
returns table(link_kind text, member_name text, member_role text, template_id text)
language sql stable security definer set search_path to 'public' as $$
  select 'self', m.name, m.role, m.template_id from members m where m.self_token = p_token
  union all
  select 'peer', m.name, m.role, m.template_id from members m where m.peer_token = p_token
  union all
  select 'view', m.name, m.role, m.template_id from members m
    where m.view_token = p_token and (m.view_enabled or m.user_id = auth.uid());
$$;

create or replace function public.goal_member_for_token(p_token uuid)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select id from members where view_token = p_token and (view_enabled or user_id = auth.uid());
$$;

create or replace function public.view_sharing_links(p_token uuid)
returns table(self_token uuid, peer_token uuid)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  return query select m.self_token, m.peer_token
    from members m where m.view_token = p_token and (m.view_enabled or m.user_id = auth.uid());
  if not found then
    raise exception 'invalid view link' using errcode = '28000';
  end if;
end;
$$;

-- Planner: a linked person edits their own vacations.
create function public.planner_can_edit_vacations(member uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.can_edit_member(member) or public.is_linked_member(member);
$$;

drop policy vacations_write on public.vacations;
create policy vacations_write on public.vacations for all to authenticated
  using (public.planner_can_edit_vacations(member_id))
  with check (public.planner_can_edit_vacations(member_id));

create or replace function public.planner_set_vacations(member uuid, start_date date, end_date date, working boolean)
returns void language plpgsql set search_path to '' as $$
begin
  if not public.planner_can_edit_vacations(member) then raise exception 'Team edit access required'; end if;
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

create or replace function public.planner_workspace_roster(workspace uuid)
returns table(id uuid, team_id uuid, name text, role text, can_edit boolean, vacation_token uuid)
language plpgsql stable security definer set search_path to '' as $$
begin
  if not public.planner_has_access(workspace) then raise exception 'Workspace access required'; end if;
  return query select m.id, m.team_id, m.name, m.planning_role,
    public.planner_can_edit_vacations(m.id),
    case when public.can_edit_member(m.id) then m.vacation_token else null end
    from public.members m join public.teams t on t.id = m.team_id
    where t.workspace_id = workspace order by m.name, m.id;
end;
$$;

revoke all on function public.is_linked_member(uuid), public.create_member_invite(uuid),
  public.member_invite(uuid), public.claim_member_invite(uuid), public.unlink_member(uuid),
  public.member_links(uuid), public.my_member(uuid), public.planner_can_edit_vacations(uuid)
  from public, anon;
grant execute on function public.is_linked_member(uuid), public.create_member_invite(uuid),
  public.member_invite(uuid), public.claim_member_invite(uuid), public.unlink_member(uuid),
  public.member_links(uuid), public.my_member(uuid), public.planner_can_edit_vacations(uuid)
  to authenticated;
