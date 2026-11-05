alter table public.workspace_collaborators drop constraint workspace_collaborators_app_check;
alter table public.workspace_collaborators add constraint workspace_collaborators_app_check
  check (app in ('ladders', 'planner', 'pulse', 'shiplog'));

create or replace function public.list_workspaces(app_name text)
returns table(id uuid, name text, owner_id uuid, access_level text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if app_name is null or app_name not in ('ladders', 'planner', 'pulse', 'shiplog') then
    raise exception 'Invalid app';
  end if;
  return query select w.id, w.name, w.owner_id, public.workspace_access(w.id, app_name)
    from public.workspaces w where public.workspace_access(w.id, app_name) is not null
    order by lower(w.name), w.id;
end;
$$;

create or replace function public.share_workspace(workspace uuid, account_email text, app_name text, access text)
returns void language plpgsql security definer set search_path = '' as $$
declare account uuid; normalized_email text := lower(trim(account_email));
begin
  if not public.workspace_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  if app_name is null or app_name not in ('ladders', 'planner', 'pulse', 'shiplog') then raise exception 'Invalid app'; end if;
  if access is null or access not in ('viewer', 'editor') then raise exception 'Invalid access level'; end if;
  select u.id into account from auth.users u where lower(u.email) = normalized_email;
  if account is null or account = auth.uid() then raise exception 'User not found or cannot share workspace'; end if;
  insert into public.workspace_collaborators(workspace_id, user_id, email, app, access_level)
    values (workspace, account, normalized_email, app_name, access)
    on conflict (workspace_id, user_id, app)
    do update set email = excluded.email, access_level = excluded.access_level;
end;
$$;

create function public.shiplog_can_edit(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.workspace_access(workspace, 'shiplog') in ('owner', 'editor'), false);
$$;

create table public.shiplog_applications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  slug text not null check (length(slug) between 1 and 80 and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description text not null default '' check (length(description) <= 4000),
  platform text not null default 'web' check (platform in ('web','ios','android','backend','api','other')),
  public_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  unique (workspace_id, slug),
  unique (id, workspace_id)
);

create table public.shiplog_environments (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.shiplog_applications(id) on delete cascade,
  name text not null,
  slug text not null,
  kind text not null check (kind in ('staging','production','custom')),
  unique (application_id, slug),
  unique (id, application_id)
);

create table public.shiplog_releases (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  version text not null check (length(version) <= 100 and version ~
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(\+[0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*)?$'),
  release_type text not null check (release_type in ('major','minor','patch','hotfix')),
  title text not null check (length(btrim(title)) between 1 and 160),
  internal_notes text not null default '' check (length(internal_notes) <= 20000),
  public_notes text not null default '' check (length(public_notes) <= 20000),
  status text not null default 'draft' check (status in (
    'draft','ready_for_qa','qa_in_progress','qa_passed','approved','released','deprecated','rolled_back')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  foreign key (application_id, workspace_id) references public.shiplog_applications(id, workspace_id) on delete cascade,
  unique (application_id, version),
  unique (id, application_id)
);
create index on public.shiplog_releases(workspace_id, created_at desc, id);

create table public.shiplog_release_changes (
  id uuid primary key default gen_random_uuid(),
  release_id uuid not null references public.shiplog_releases(id) on delete cascade,
  category text not null check (category in ('feature','improvement','bug_fix','technical','breaking','security')),
  title text not null check (length(btrim(title)) between 1 and 160),
  description text not null default '',
  is_public boolean not null default false
);

create table public.shiplog_audit_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  application_id uuid references public.shiplog_applications(id) on delete cascade,
  release_id uuid references public.shiplog_releases(id) on delete cascade,
  event text not null,
  actor_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.shiplog_portals (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  token uuid not null unique default gen_random_uuid()
);

alter table public.shiplog_applications enable row level security;
alter table public.shiplog_environments enable row level security;
alter table public.shiplog_releases enable row level security;
alter table public.shiplog_release_changes enable row level security;
alter table public.shiplog_audit_events enable row level security;
alter table public.shiplog_portals enable row level security;
revoke all on public.shiplog_applications, public.shiplog_environments, public.shiplog_releases,
  public.shiplog_release_changes, public.shiplog_audit_events, public.shiplog_portals from anon, authenticated;
grant select on public.shiplog_applications, public.shiplog_environments, public.shiplog_releases,
  public.shiplog_release_changes, public.shiplog_audit_events to authenticated;

create policy shiplog_applications_read on public.shiplog_applications for select to authenticated
  using (public.workspace_access(workspace_id, 'shiplog') is not null);
create policy shiplog_releases_read on public.shiplog_releases for select to authenticated
  using (public.workspace_access(workspace_id, 'shiplog') is not null);
create policy shiplog_audit_read on public.shiplog_audit_events for select to authenticated
  using (public.workspace_access(workspace_id, 'shiplog') is not null);
create policy shiplog_environments_read on public.shiplog_environments for select to authenticated
  using (exists(select 1 from public.shiplog_applications a where a.id = application_id));
create policy shiplog_changes_read on public.shiplog_release_changes for select to authenticated
  using (exists(select 1 from public.shiplog_releases r where r.id = release_id));

create function public.shiplog_create_application(
  workspace uuid, application_name text, application_slug text,
  application_platform text, application_description text default ''
) returns public.shiplog_applications language plpgsql security definer set search_path = '' as $$
declare result public.shiplog_applications;
begin
  if not public.shiplog_can_edit(workspace) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  insert into public.shiplog_applications(workspace_id, name, slug, platform, description)
    values(workspace, btrim(application_name), lower(btrim(application_slug)), application_platform, application_description)
    returning * into result;
  insert into public.shiplog_environments(application_id, name, slug, kind) values
    (result.id, 'Staging', 'staging', 'staging'), (result.id, 'Production', 'production', 'production');
  insert into public.shiplog_audit_events(workspace_id, application_id, event, actor_id)
    values(workspace, result.id, 'application.created', auth.uid());
  return result;
end;
$$;

create function public.shiplog_set_application_public(application uuid, enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_applications;
begin
  select * into target from public.shiplog_applications where id = application for update;
  if not public.shiplog_can_edit(target.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  update public.shiplog_applications set public_enabled = enabled where id = application;
  insert into public.shiplog_audit_events(workspace_id, application_id, event, actor_id)
    values(target.workspace_id, application, case when enabled then 'application.public_enabled' else 'application.public_disabled' end, auth.uid());
end;
$$;

create function public.shiplog_create_release(input jsonb)
returns public.shiplog_releases language plpgsql security definer set search_path = '' as $$
declare app public.shiplog_applications; result public.shiplog_releases;
begin
  select * into app from public.shiplog_applications where id = (input->>'application_id')::uuid for update;
  if not public.shiplog_can_edit(app.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  insert into public.shiplog_releases(workspace_id, application_id, version, release_type, title, internal_notes, public_notes, created_by)
    values(app.workspace_id, app.id, input->>'version', input->>'release_type', btrim(input->>'title'),
      coalesce(input->>'internal_notes',''), coalesce(input->>'public_notes',''), auth.uid()) returning * into result;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id)
    values(app.workspace_id, app.id, result.id, 'release.created', auth.uid());
  return result;
end;
$$;

create function public.shiplog_publish_release(release uuid, published boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  if published is null then raise exception 'Publication state required'; end if;
  update public.shiplog_releases set published_at = case when published then coalesce(published_at, now()) else null end where id = release;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id)
    values(target.workspace_id, target.application_id, release, case when published then 'release.published' else 'release.unpublished' end, auth.uid());
end;
$$;

-- A single revocable catalog for the workspace, never one token per application.
create function public.shiplog_portal(workspace uuid, enabled boolean default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if not public.shiplog_can_edit(workspace) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  perform 1 from public.workspaces where id = workspace for update;
  if enabled = false then delete from public.shiplog_portals where workspace_id = workspace; return null; end if;
  if enabled = true then insert into public.shiplog_portals(workspace_id) values(workspace) on conflict do nothing; end if;
  select token into result from public.shiplog_portals where workspace_id = workspace;
  return result;
end;
$$;

create function public.shiplog_public_catalog(token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target uuid; result jsonb;
begin
  select p.workspace_id into target from public.shiplog_portals p where p.token = $1;
  if target is null then raise exception 'Release catalog unavailable' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'name', w.name,
    'applications', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name)
      from public.shiplog_applications a where a.workspace_id = target and a.public_enabled), '[]'::jsonb),
    'releases', coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'application_id', r.application_id, 'version', r.version,
      'title', r.title, 'release_type', r.release_type, 'public_notes', r.public_notes,
      'published_at', r.published_at) order by r.published_at desc, r.id)
      from public.shiplog_releases r join public.shiplog_applications a on a.id = r.application_id
      where a.workspace_id = target and a.public_enabled and r.published_at is not null), '[]'::jsonb)
  ) into result from public.workspaces w where w.id = target;
  return result;
end;
$$;

revoke all on function public.shiplog_can_edit(uuid),
  public.shiplog_create_application(uuid,text,text,text,text), public.shiplog_set_application_public(uuid,boolean),
  public.shiplog_create_release(jsonb), public.shiplog_publish_release(uuid,boolean),
  public.shiplog_portal(uuid,boolean), public.shiplog_public_catalog(uuid) from public, anon, authenticated;
grant execute on function public.shiplog_can_edit(uuid),
  public.shiplog_create_application(uuid,text,text,text,text), public.shiplog_set_application_public(uuid,boolean),
  public.shiplog_create_release(jsonb), public.shiplog_publish_release(uuid,boolean),
  public.shiplog_portal(uuid,boolean) to authenticated;
grant execute on function public.shiplog_public_catalog(uuid) to anon, authenticated;
