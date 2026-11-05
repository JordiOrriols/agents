-- First-class teams, authenticated sharing, and team-aware member/evaluation access.

-- ---------------------------------------------------------------------------
-- Tables and existing-data migration
-- ---------------------------------------------------------------------------

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 120),
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index teams_owner_idx on public.teams (owner_id);
create unique index teams_one_default_per_owner_idx
  on public.teams (owner_id)
  where is_default;

create table public.team_collaborators (
  team_id uuid not null references public.teams (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  email text not null check (char_length(trim(email)) between 3 and 320),
  access_level text not null check (access_level in ('viewer', 'editor')),
  shared_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

create index team_collaborators_user_idx on public.team_collaborators (user_id);

insert into public.teams (owner_id, name, is_default)
select u.id, 'Default Team', true
from auth.users u
where not exists (
  select 1 from public.teams t where t.owner_id = u.id and t.is_default
);

alter table public.members add column team_id uuid;

update public.members m
set team_id = (
  select t.id
  from public.teams t
  where t.owner_id = m.owner_id and t.is_default
  limit 1
)
where m.team_id is null;

alter table public.members alter column team_id set not null;
alter table public.members
  add constraint members_team_id_fkey
  foreign key (team_id) references public.teams (id) on delete cascade;
create index members_team_idx on public.members (team_id);

-- ---------------------------------------------------------------------------
-- Default teams and timestamps
-- ---------------------------------------------------------------------------

create or replace function public.create_default_team_for_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into teams (owner_id, name, is_default)
  values (new.id, 'Default Team', true)
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.create_default_team_for_user() from public, anon, authenticated;

drop trigger if exists create_default_team_after_signup on auth.users;
create trigger create_default_team_after_signup
after insert on auth.users
for each row execute function public.create_default_team_for_user();

create or replace function public.teams_before_update()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id
    or new.owner_id is distinct from old.owner_id
    or new.is_default is distinct from old.is_default then
    raise exception 'team identity and default status are immutable';
  end if;
  new.name := trim(new.name);
  new.updated_at := now();
  return new;
end;
$$;

create trigger teams_before_update
before update on public.teams
for each row execute function public.teams_before_update();

create or replace function public.teams_before_delete()
returns trigger
language plpgsql
as $$
begin
  if old.is_default then
    raise exception 'default team cannot be deleted' using errcode = '23503';
  end if;
  if exists (select 1 from public.members m where m.team_id = old.id) then
    raise exception 'team is not empty' using errcode = '23503';
  end if;
  return old;
end;
$$;

create trigger teams_before_delete
before delete on public.teams
for each row execute function public.teams_before_delete();

-- ---------------------------------------------------------------------------
-- Team-aware authorization helpers
-- ---------------------------------------------------------------------------

create or replace function public.team_access_level(p_team_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when t.owner_id = auth.uid() then 'owner'
    else (
      select tc.access_level
      from team_collaborators tc
      where tc.team_id = t.id and tc.user_id = auth.uid()
    )
  end
  from teams t
  where t.id = p_team_id;
$$;

create or replace function public.can_view_team(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.team_access_level(p_team_id) in ('owner', 'editor', 'viewer'), false);
$$;

create or replace function public.can_edit_team(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.team_access_level(p_team_id) in ('owner', 'editor'), false);
$$;

create or replace function public.is_team_owner(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from teams t where t.id = p_team_id and t.owner_id = auth.uid());
$$;

create or replace function public.can_view_member(p_member_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from members m where m.id = p_member_id and public.can_view_team(m.team_id)
  );
$$;

create or replace function public.can_edit_member(p_member_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from members m where m.id = p_member_id and public.can_edit_team(m.team_id)
  );
$$;

create or replace function public.is_member_team_owner(p_member_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from members m where m.id = p_member_id and public.is_team_owner(m.team_id)
  );
$$;

create or replace function public.owns_member(p_member_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.can_edit_member(p_member_id);
$$;

revoke execute on function
  public.team_access_level(uuid),
  public.can_view_team(uuid),
  public.can_edit_team(uuid),
  public.is_team_owner(uuid),
  public.can_view_member(uuid),
  public.can_edit_member(uuid),
  public.is_member_team_owner(uuid),
  public.owns_member(uuid)
from public, anon;

grant execute on function
  public.team_access_level(uuid),
  public.can_view_team(uuid),
  public.can_edit_team(uuid),
  public.is_team_owner(uuid),
  public.can_view_member(uuid),
  public.can_edit_member(uuid),
  public.is_member_team_owner(uuid),
  public.owns_member(uuid)
to authenticated;

-- ---------------------------------------------------------------------------
-- Member triggers and RLS replacement
-- ---------------------------------------------------------------------------

create or replace function public.members_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
  return new;
end;
$$;

create or replace function public.members_before_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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

alter table public.teams enable row level security;
alter table public.team_collaborators enable row level security;

revoke all on public.teams from anon;
revoke all on public.team_collaborators from anon, authenticated;
grant select, insert, update, delete on public.teams to authenticated;

drop policy if exists members_owner_all on public.members;
drop policy if exists evaluations_owner_select on public.evaluations;
drop policy if exists evaluations_owner_insert on public.evaluations;
drop policy if exists evaluations_owner_update on public.evaluations;
drop policy if exists evaluations_owner_delete on public.evaluations;

create policy teams_accessible_select on public.teams
  for select to authenticated
  using (public.can_view_team(id));

create policy teams_owner_insert on public.teams
  for insert to authenticated
  with check (owner_id = auth.uid());

create policy teams_owner_update on public.teams
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create policy teams_owner_delete on public.teams
  for delete to authenticated
  using (owner_id = auth.uid());

create policy members_team_select on public.members
  for select to authenticated
  using (public.can_view_team(team_id));

create policy members_team_insert on public.members
  for insert to authenticated
  with check (public.can_edit_team(team_id));

create policy members_team_update on public.members
  for update to authenticated
  using (public.can_edit_team(team_id))
  with check (public.can_edit_team(team_id));

create policy members_owner_delete on public.members
  for delete to authenticated
  using (public.is_team_owner(team_id));

create policy evaluations_team_select on public.evaluations
  for select to authenticated
  using (
    public.can_view_member(member_id)
    and (kind <> 'self' or status = 'published')
  );

create policy evaluations_team_insert on public.evaluations
  for insert to authenticated
  with check (public.can_edit_member(member_id));

create policy evaluations_team_update on public.evaluations
  for update to authenticated
  using (public.can_edit_member(member_id) and kind <> 'self')
  with check (public.can_edit_member(member_id) and kind <> 'self');

create policy evaluations_owner_delete on public.evaluations
  for delete to authenticated
  using (
    public.is_member_team_owner(member_id)
    and (kind <> 'self' or status = 'published')
  );

-- ---------------------------------------------------------------------------
-- Owner-only sharing and member movement RPCs
-- ---------------------------------------------------------------------------

create or replace function public.list_accessible_teams()
returns table (
  id uuid,
  owner_id uuid,
  name text,
  is_default boolean,
  access_level text,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    t.id,
    t.owner_id,
    t.name,
    t.is_default,
    public.team_access_level(t.id),
    t.created_at,
    t.updated_at
  from teams t
  where public.can_view_team(t.id)
  order by t.is_default desc, lower(t.name), t.created_at;
$$;

create or replace function public.list_team_shares(p_team_id uuid)
returns table (
  team_id uuid,
  user_id uuid,
  email text,
  access_level text,
  shared_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  return query
    select tc.team_id, tc.user_id, tc.email, tc.access_level, tc.shared_at
    from team_collaborators tc
    where tc.team_id = p_team_id
    order by lower(tc.email);
end;
$$;

create or replace function public.share_team_by_email(
  p_team_id uuid,
  p_email text,
  p_access text
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_user_id uuid;
  v_email text := lower(trim(p_email));
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  if p_access not in ('viewer', 'editor') then
    raise exception 'invalid access level' using errcode = '22023';
  end if;

  select u.id into v_user_id from auth.users u where lower(u.email) = v_email limit 1;
  if v_user_id is null or v_user_id = auth.uid() then
    raise exception 'user not found or cannot share team' using errcode = '22023';
  end if;

  insert into public.team_collaborators (team_id, user_id, email, access_level)
  values (p_team_id, v_user_id, v_email, p_access)
  on conflict (team_id, user_id)
  do update set access_level = excluded.access_level, email = excluded.email;
end;
$$;

create or replace function public.update_team_share(
  p_team_id uuid,
  p_user_id uuid,
  p_access text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  if p_access not in ('viewer', 'editor') then
    raise exception 'invalid access level' using errcode = '22023';
  end if;
  update team_collaborators
  set access_level = p_access
  where team_id = p_team_id and user_id = p_user_id;
  if not found then raise exception 'team share not found' using errcode = '22023'; end if;
end;
$$;

create or replace function public.remove_team_share(p_team_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  delete from team_collaborators where team_id = p_team_id and user_id = p_user_id;
  if not found then raise exception 'team share not found' using errcode = '22023'; end if;
end;
$$;

create or replace function public.move_member_to_team(p_member_id uuid, p_team_id uuid)
returns public.members
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member members;
  v_source_team uuid;
  v_source_owner uuid;
  v_target_owner uuid;
begin
  select m.team_id, m.owner_id into v_source_team, v_source_owner
  from members m where m.id = p_member_id;
  select t.owner_id into v_target_owner from teams t where t.id = p_team_id;

  if v_source_team is null or v_target_owner is null then
    raise exception 'member or team not found' using errcode = '22023';
  end if;
  if v_source_owner is distinct from v_target_owner then
    raise exception 'members cannot move across team owners' using errcode = '42501';
  end if;
  if not public.can_edit_team(v_source_team) or not public.can_edit_team(p_team_id) then
    raise exception 'both teams require edit access' using errcode = '42501';
  end if;

  update members set team_id = p_team_id where id = p_member_id returning * into v_member;
  return v_member;
end;
$$;

revoke execute on function
  public.list_accessible_teams(),
  public.list_team_shares(uuid),
  public.share_team_by_email(uuid, text, text),
  public.update_team_share(uuid, uuid, text),
  public.remove_team_share(uuid, uuid),
  public.move_member_to_team(uuid, uuid)
from public, anon;

grant execute on function
  public.list_accessible_teams(),
  public.list_team_shares(uuid),
  public.share_team_by_email(uuid, text, text),
  public.update_team_share(uuid, uuid, text),
  public.remove_team_share(uuid, uuid),
  public.move_member_to_team(uuid, uuid)
to authenticated;
