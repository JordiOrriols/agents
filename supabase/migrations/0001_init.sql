-- Ladders schema: members owned by a manager, versioned evaluations, and permanent share tokens.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------

create or replace function public.valid_levels(p jsonb)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(p) = 'object'
    and not exists (
      select 1
      from jsonb_each(p) as e(key, value)
      where e.key not in ('Technology', 'System', 'People', 'Process', 'Influence')
        or case
             when jsonb_typeof(e.value) <> 'number' then true
             else (e.value::text)::numeric < 0
               or (e.value::text)::numeric > 5.5
               or mod((e.value::text)::numeric * 2, 1) <> 0
           end
    );
$$;

create or replace function public.valid_comments(p jsonb)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(p) = 'object'
    and not exists (
      select 1
      from jsonb_each(p) as e(key, value)
      where e.key not in ('Technology', 'System', 'People', 'Process', 'Influence')
        or case
             when jsonb_typeof(e.value) <> 'string' then true
             else char_length(e.value #>> '{}') > 2000
           end
    );
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.members (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  role text not null default '' check (char_length(role) <= 120),
  template_id text check (char_length(template_id) <= 10),
  self_token uuid not null unique default gen_random_uuid(),
  peer_token uuid not null unique default gen_random_uuid(),
  view_token uuid not null unique default gen_random_uuid(),
  view_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index members_owner_idx on public.members (owner_id);

create table public.evaluations (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members (id) on delete cascade,
  kind text not null check (kind in ('manager', 'self', 'peer')),
  status text not null default 'draft' check (status in ('draft', 'published')),
  author_name text check (char_length(author_name) <= 120),
  current_levels jsonb not null default '{}' check (public.valid_levels(current_levels)),
  goal_levels jsonb not null default '{}' check (public.valid_levels(goal_levels)),
  comments jsonb not null default '{}' check (public.valid_comments(comments)),
  created_at timestamptz not null default now()
);

create index evaluations_member_idx on public.evaluations (member_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Integrity triggers: tokens are generated server-side and never change;
-- evaluation versions are immutable except for their status.
-- ---------------------------------------------------------------------------

create or replace function public.members_before_insert()
returns trigger
language plpgsql
as $$
begin
  new.owner_id := auth.uid();
  new.self_token := gen_random_uuid();
  new.peer_token := gen_random_uuid();
  new.view_token := gen_random_uuid();
  new.view_enabled := coalesce(new.view_enabled, false);
  return new;
end;
$$;

create trigger members_before_insert
before insert on public.members
for each row execute function public.members_before_insert();

create or replace function public.members_before_update()
returns trigger
language plpgsql
as $$
begin
  if new.owner_id is distinct from old.owner_id
    or new.self_token is distinct from old.self_token
    or new.peer_token is distinct from old.peer_token
    or new.view_token is distinct from old.view_token
    or new.id is distinct from old.id then
    raise exception 'owner, id and share tokens are immutable';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger members_before_update
before update on public.members
for each row execute function public.members_before_update();

create or replace function public.evaluations_before_update()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id
    or new.member_id is distinct from old.member_id
    or new.kind is distinct from old.kind
    or new.author_name is distinct from old.author_name
    or new.current_levels is distinct from old.current_levels
    or new.goal_levels is distinct from old.goal_levels
    or new.comments is distinct from old.comments
    or new.created_at is distinct from old.created_at then
    raise exception 'evaluation versions are immutable; only status can change';
  end if;
  return new;
end;
$$;

create trigger evaluations_before_update
before update on public.evaluations
for each row execute function public.evaluations_before_update();

-- ---------------------------------------------------------------------------
-- Row level security: owners only. Anonymous access goes through the RPCs below.
-- ---------------------------------------------------------------------------

alter table public.members enable row level security;
alter table public.evaluations enable row level security;

revoke all on public.members from anon;
revoke all on public.evaluations from anon;
grant select, insert, update, delete on public.members to authenticated;
grant select, insert, update, delete on public.evaluations to authenticated;

create policy members_owner_all on public.members
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

create or replace function public.owns_member(p_member_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from members where id = p_member_id and owner_id = auth.uid());
$$;

-- Self versions are private to the evaluated person until they publish them.
create policy evaluations_owner_select on public.evaluations
  for select to authenticated
  using (public.owns_member(member_id) and (kind <> 'self' or status = 'published'));

create policy evaluations_owner_insert on public.evaluations
  for insert to authenticated
  with check (public.owns_member(member_id));

create policy evaluations_owner_update on public.evaluations
  for update to authenticated
  using (public.owns_member(member_id) and kind <> 'self')
  with check (public.owns_member(member_id) and kind <> 'self');

create policy evaluations_owner_delete on public.evaluations
  for delete to authenticated
  using (public.owns_member(member_id) and (kind <> 'self' or status = 'published'));

-- ---------------------------------------------------------------------------
-- Token RPCs (callable without login). Every function checks the token itself.
-- ---------------------------------------------------------------------------

create or replace function public.resolve_token(p_token uuid)
returns table (link_kind text, member_name text, member_role text, template_id text)
language sql
stable
security definer
set search_path = public
as $$
  select 'self', m.name, m.role, m.template_id from members m where m.self_token = p_token
  union all
  select 'peer', m.name, m.role, m.template_id from members m where m.peer_token = p_token
  union all
  select 'view', m.name, m.role, m.template_id from members m
    where m.view_token = p_token and m.view_enabled;
$$;

create or replace function public.self_list(p_token uuid)
returns setof public.evaluations
language sql
stable
security definer
set search_path = public
as $$
  select e.*
  from evaluations e
  join members m on m.id = e.member_id
  where m.self_token = p_token and e.kind = 'self'
  order by e.created_at desc;
$$;

create or replace function public.self_save(
  p_token uuid,
  p_status text,
  p_current jsonb,
  p_goal jsonb,
  p_comments jsonb
)
returns public.evaluations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_row evaluations;
begin
  select id into v_member_id from members where self_token = p_token;
  if v_member_id is null then
    raise exception 'invalid link' using errcode = '28000';
  end if;

  insert into evaluations (member_id, kind, status, author_name, current_levels, goal_levels, comments)
  select v_member_id, 'self', p_status, m.name, p_current, p_goal, p_comments
  from members m where m.id = v_member_id
  returning * into v_row;

  return v_row;
end;
$$;

create or replace function public.self_set_status(p_token uuid, p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update evaluations e
  set status = p_status
  from members m
  where e.id = p_id and e.kind = 'self' and m.id = e.member_id and m.self_token = p_token;
  if not found then
    raise exception 'invalid link' using errcode = '28000';
  end if;
end;
$$;

create or replace function public.self_delete(p_token uuid, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from evaluations e
  using members m
  where e.id = p_id and e.kind = 'self' and m.id = e.member_id and m.self_token = p_token;
  if not found then
    raise exception 'invalid link' using errcode = '28000';
  end if;
end;
$$;

-- Peers can only write. Their versions arrive as drafts for the owner to review.
create or replace function public.peer_submit(
  p_token uuid,
  p_author text,
  p_current jsonb,
  p_goal jsonb,
  p_comments jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_id uuid;
begin
  select id into v_member_id from members where peer_token = p_token;
  if v_member_id is null then
    raise exception 'invalid link' using errcode = '28000';
  end if;
  if p_author is null or char_length(trim(p_author)) = 0 then
    raise exception 'author name is required';
  end if;

  insert into evaluations (member_id, kind, status, author_name, current_levels, goal_levels, comments)
  values (v_member_id, 'peer', 'draft', trim(p_author), p_current, p_goal, p_comments)
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.public_view(p_token uuid)
returns setof public.evaluations
language sql
stable
security definer
set search_path = public
as $$
  select e.*
  from evaluations e
  join members m on m.id = e.member_id
  where m.view_token = p_token
    and m.view_enabled
    and (e.kind = 'self' or e.status = 'published')
  order by e.created_at desc;
$$;

revoke execute on function
  public.resolve_token(uuid),
  public.self_list(uuid),
  public.self_save(uuid, text, jsonb, jsonb, jsonb),
  public.self_set_status(uuid, uuid, text),
  public.self_delete(uuid, uuid),
  public.peer_submit(uuid, text, jsonb, jsonb, jsonb),
  public.public_view(uuid)
from public;

grant execute on function
  public.resolve_token(uuid),
  public.self_list(uuid),
  public.self_save(uuid, text, jsonb, jsonb, jsonb),
  public.self_set_status(uuid, uuid, text),
  public.self_delete(uuid, uuid),
  public.peer_submit(uuid, text, jsonb, jsonb, jsonb),
  public.public_view(uuid)
to anon, authenticated;

revoke execute on function public.owns_member(uuid) from public, anon;
grant execute on function public.owns_member(uuid) to authenticated;
