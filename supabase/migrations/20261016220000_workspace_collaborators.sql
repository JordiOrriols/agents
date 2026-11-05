-- One sharing table for every app: a workspace is shared with an account per app
-- (Ladders, Planner, Pulse) as viewer or editor. Planner sharing moves here now; Ladders
-- keeps its team shares until it switches to workspaces.

create table public.workspace_collaborators (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  email text not null check (char_length(email) between 3 and 320),
  app text not null check (app in ('ladders', 'planner', 'pulse')),
  access_level text not null check (access_level in ('viewer', 'editor')),
  shared_at timestamptz not null default now(),
  primary key (workspace_id, user_id, app)
);
create index on public.workspace_collaborators(user_id);
alter table public.workspace_collaborators enable row level security;
revoke all on public.workspace_collaborators from anon, authenticated;

insert into public.workspace_collaborators(workspace_id, user_id, email, app, access_level)
  select workspace_id, user_id, email, 'planner', access_level
  from public.planner_workspace_collaborators;

create function public.workspace_is_owner(workspace uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.workspaces where id = workspace and owner_id = auth.uid());
$$;

create or replace function public.planner_has_access(workspace uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.workspace_is_owner(workspace) or exists (
    select 1 from public.workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid() and c.app = 'planner'
  ) or exists (
    select 1 from public.teams t
    where t.workspace_id = workspace and public.can_view_team(t.id)
  );
$$;

create or replace function public.planner_can_edit_workspace(workspace uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.workspace_is_owner(workspace) or exists (
    select 1 from public.workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid()
      and c.app = 'planner' and c.access_level = 'editor'
  );
$$;

create or replace function public.teams_release_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  delete from public.workspaces w
    where w.id = old.workspace_id and w.created_for_team
      and not exists (select 1 from public.teams t where t.workspace_id = w.id)
      and not exists (select 1 from public.features f where f.workspace_id = w.id)
      and not exists (select 1 from public.projects p where p.workspace_id = w.id)
      and not exists (select 1 from public.workspace_collaborators c where c.workspace_id = w.id);
  return null;
end;
$$;

create function public.list_workspace_shares(workspace uuid)
returns table(user_id uuid, email text, app text, access_level text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.workspace_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  return query select c.user_id, c.email, c.app, c.access_level
    from public.workspace_collaborators c where c.workspace_id = workspace
    order by c.email, c.user_id, c.app;
end;
$$;

create function public.share_workspace(workspace uuid, account_email text, app_name text, access text)
returns void language plpgsql security definer set search_path = '' as $$
declare account uuid; normalized_email text := lower(trim(account_email));
begin
  if not public.workspace_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  if app_name is null or app_name not in ('ladders', 'planner', 'pulse') then raise exception 'Invalid app'; end if;
  if access is null or access not in ('viewer', 'editor') then raise exception 'Invalid access level'; end if;
  select u.id into account from auth.users u where lower(u.email) = normalized_email;
  if account is null or account = auth.uid() then raise exception 'User not found or cannot share workspace'; end if;
  insert into public.workspace_collaborators(workspace_id, user_id, email, app, access_level)
    values (workspace, account, normalized_email, app_name, access)
    on conflict (workspace_id, user_id, app)
    do update set email = excluded.email, access_level = excluded.access_level;
end;
$$;

create function public.update_workspace_share(workspace uuid, account uuid, app_name text, access text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.workspace_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  if access is null or access not in ('viewer', 'editor') then raise exception 'Invalid access level'; end if;
  update public.workspace_collaborators c set access_level = access
    where c.workspace_id = workspace and c.user_id = account and c.app = app_name;
  if not found then raise exception 'Workspace share not found'; end if;
end;
$$;

create function public.remove_workspace_share(workspace uuid, account uuid, app_name text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.workspace_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  delete from public.workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = account and c.app = app_name;
  if not found then raise exception 'Workspace share not found'; end if;
end;
$$;

revoke all on function public.workspace_is_owner(uuid), public.list_workspace_shares(uuid),
  public.share_workspace(uuid, text, text, text), public.update_workspace_share(uuid, uuid, text, text),
  public.remove_workspace_share(uuid, uuid, text) from public, anon;
grant execute on function public.workspace_is_owner(uuid), public.list_workspace_shares(uuid),
  public.share_workspace(uuid, text, text, text), public.update_workspace_share(uuid, uuid, text, text),
  public.remove_workspace_share(uuid, uuid, text) to authenticated;

drop function public.planner_list_workspace_shares(uuid);
drop function public.planner_share_workspace(uuid, text, text);
drop function public.planner_update_workspace_share(uuid, uuid, text);
drop function public.planner_remove_workspace_share(uuid, uuid);
drop table public.planner_workspace_collaborators;
