-- Ladders shares move onto workspaces: sharing a team shares the Ladders part of its whole
-- workspace, so every team in that workspace is visible (or editable) to the account. The
-- team-based RPCs keep their signatures and act on the team's workspace.

-- One level per account and workspace; where team shares disagree the least access wins.
insert into public.workspace_collaborators(workspace_id, user_id, email, app, access_level, shared_at)
  select t.workspace_id, tc.user_id, min(tc.email), 'ladders',
    case when bool_or(tc.access_level = 'viewer') then 'viewer' else 'editor' end,
    min(tc.shared_at)
  from public.team_collaborators tc join public.teams t on t.id = tc.team_id
  group by t.workspace_id, tc.user_id
  on conflict (workspace_id, user_id, app) do nothing;

create or replace function public.team_access_level(p_team_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when t.owner_id = auth.uid() then 'owner'
    else (
      select c.access_level from public.workspace_collaborators c
      where c.workspace_id = t.workspace_id and c.user_id = auth.uid() and c.app = 'ladders'
    )
  end
  from public.teams t
  where t.id = p_team_id;
$$;

create or replace function public.list_team_shares(p_team_id uuid)
returns table(team_id uuid, user_id uuid, email text, access_level text, shared_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  return query
    select p_team_id, c.user_id, c.email, c.access_level, c.shared_at
    from public.workspace_collaborators c join public.teams t on t.workspace_id = c.workspace_id
    where t.id = p_team_id and c.app = 'ladders'
    order by lower(c.email);
end;
$$;

create or replace function public.share_team_by_email(p_team_id uuid, p_email text, p_access text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_user_id uuid;
  v_email text := lower(trim(p_email));
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  if p_access is null or p_access not in ('viewer', 'editor') then
    raise exception 'invalid access level' using errcode = '22023';
  end if;
  select u.id into v_user_id from auth.users u where lower(u.email) = v_email limit 1;
  if v_user_id is null or v_user_id = auth.uid() then
    raise exception 'user not found or cannot share team' using errcode = '22023';
  end if;
  insert into public.workspace_collaborators(workspace_id, user_id, email, app, access_level)
    select t.workspace_id, v_user_id, v_email, 'ladders', p_access from public.teams t where t.id = p_team_id
    on conflict (workspace_id, user_id, app)
    do update set access_level = excluded.access_level, email = excluded.email;
end;
$$;

create or replace function public.update_team_share(p_team_id uuid, p_user_id uuid, p_access text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  if p_access is null or p_access not in ('viewer', 'editor') then
    raise exception 'invalid access level' using errcode = '22023';
  end if;
  update public.workspace_collaborators c set access_level = p_access
    from public.teams t
    where t.id = p_team_id and c.workspace_id = t.workspace_id
      and c.user_id = p_user_id and c.app = 'ladders';
  if not found then raise exception 'team share not found' using errcode = '22023'; end if;
end;
$$;

create or replace function public.remove_team_share(p_team_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_team_owner(p_team_id) then
    raise exception 'team owner access required' using errcode = '42501';
  end if;
  delete from public.workspace_collaborators c
    using public.teams t
    where t.id = p_team_id and c.workspace_id = t.workspace_id
      and c.user_id = p_user_id and c.app = 'ladders';
  if not found then raise exception 'team share not found' using errcode = '22023'; end if;
end;
$$;

-- A workspace that only existed for a team goes away once it holds nothing, together with
-- its shares: a team that moves takes on the sharing of the workspace it moves into.
create or replace function public.teams_release_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  delete from public.workspaces w
    where w.id = old.workspace_id and w.created_for_team
      and not exists (select 1 from public.teams t where t.workspace_id = w.id)
      and not exists (select 1 from public.features f where f.workspace_id = w.id)
      and not exists (select 1 from public.projects p where p.workspace_id = w.id);
  return null;
end;
$$;

drop table public.team_collaborators;
