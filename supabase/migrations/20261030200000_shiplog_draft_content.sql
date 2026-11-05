-- Unpublishing hides a release; it must not unlock previously published history.
alter table public.shiplog_releases add column first_published_at timestamptz;
update public.shiplog_releases r set first_published_at = coalesce(
  (select min(e.created_at) from public.shiplog_audit_events e
    where e.release_id = r.id and e.event = 'release.published'), r.published_at);
alter table public.shiplog_audit_events add column details jsonb not null default '{}'::jsonb;
alter table public.shiplog_release_changes add constraint shiplog_change_description_length
  check (length(description) <= 10000);
alter table public.shiplog_release_changes add column created_at timestamptz not null default now();
create index on public.shiplog_release_changes(release_id, created_at, id);

-- This lock is also taken by publication, serializing publication with all content edits.
create function public.shiplog_lock_draft(release uuid)
returns public.shiplog_releases language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then
    raise exception 'Shiplog edit access required' using errcode = '42501';
  end if;
  if target.status <> 'draft' or target.first_published_at is not null then
    raise exception 'Only never-published drafts can be edited' using errcode = '23514';
  end if;
  return target;
end;
$$;

create function public.shiplog_update_draft(release uuid, input jsonb)
returns public.shiplog_releases language plpgsql security definer set search_path = '' as $$
declare previous public.shiplog_releases; result public.shiplog_releases;
begin
  previous := public.shiplog_lock_draft(release);
  if input->>'application_id' is distinct from previous.application_id::text then
    raise exception 'The release application cannot be changed';
  end if;
  update public.shiplog_releases set
    version = input->>'version', release_type = input->>'release_type',
    title = btrim(input->>'title'), internal_notes = coalesce(input->>'internal_notes',''),
    public_notes = coalesce(input->>'public_notes','')
    where id = release returning * into result;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id, details)
    values(result.workspace_id, result.application_id, release, 'release.updated', auth.uid(),
      jsonb_build_object('before', to_jsonb(previous), 'after', to_jsonb(result)));
  return result;
end;
$$;

create function public.shiplog_save_change(release uuid, input jsonb, change_id uuid default null)
returns public.shiplog_release_changes language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases; previous public.shiplog_release_changes;
  result public.shiplog_release_changes;
begin
  target := public.shiplog_lock_draft(release);
  if change_id is null then
    insert into public.shiplog_release_changes(release_id, category, title, description, is_public)
      values(release, input->>'category', btrim(input->>'title'),
        coalesce(input->>'description',''), coalesce((input->>'is_public')::boolean,false))
      returning * into result;
  else
    select * into previous from public.shiplog_release_changes where id = change_id and release_id = release;
    if not found then raise exception 'Release change not found' using errcode = 'P0002'; end if;
    update public.shiplog_release_changes set category = input->>'category',
      title = btrim(input->>'title'), description = coalesce(input->>'description',''),
      is_public = coalesce((input->>'is_public')::boolean,false)
      where id = change_id and release_id = release returning * into result;
  end if;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id, details)
    values(target.workspace_id, target.application_id, release,
      case when change_id is null then 'change.created' else 'change.updated' end, auth.uid(),
      jsonb_build_object('before', to_jsonb(previous), 'after', to_jsonb(result)));
  return result;
end;
$$;

create function public.shiplog_delete_change(release uuid, change_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases; previous public.shiplog_release_changes;
begin
  target := public.shiplog_lock_draft(release);
  delete from public.shiplog_release_changes where id = change_id and release_id = release returning * into previous;
  if not found then raise exception 'Release change not found' using errcode = 'P0002'; end if;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id, details)
    values(target.workspace_id, target.application_id, release, 'change.deleted', auth.uid(),
      jsonb_build_object('before', to_jsonb(previous)));
end;
$$;

create or replace function public.shiplog_publish_release(release uuid, published boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  if published is null then raise exception 'Publication state required'; end if;
  update public.shiplog_releases set
    first_published_at = case when published then coalesce(first_published_at, now()) else first_published_at end,
    published_at = case when published then coalesce(published_at, now()) else null end
    where id = release;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id)
    values(target.workspace_id, target.application_id, release,
      case when published then 'release.published' else 'release.unpublished' end, auth.uid());
end;
$$;

-- The same explicit projection serves authenticated previews and the public catalog.
-- Not granted to clients: only the authorized wrappers below may call it.
create function public.shiplog_public_release_content(release uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'application_id', r.application_id, 'version', r.version,
    'title', r.title, 'release_type', r.release_type, 'public_notes', r.public_notes,
    'published_at', r.published_at,
    'changes', coalesce((select jsonb_agg(jsonb_build_object(
      'category', c.category, 'title', c.title, 'description', c.description)
      order by c.created_at, c.id)
      from public.shiplog_release_changes c where c.release_id = r.id and c.is_public), '[]'::jsonb)
  ) from public.shiplog_releases r where r.id = release;
$$;

create function public.shiplog_preview_release(release uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release;
  if public.workspace_access(target.workspace_id, 'shiplog') is null then
    raise exception 'Shiplog access required' using errcode = '42501';
  end if;
  return public.shiplog_public_release_content(release);
end;
$$;

create or replace function public.shiplog_public_catalog(token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target uuid; result jsonb;
begin
  select p.workspace_id into target from public.shiplog_portals p where p.token = $1;
  if target is null then raise exception 'Release catalog unavailable' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'name', w.name,
    'applications', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name)
      from public.shiplog_applications a where a.workspace_id = target and a.public_enabled), '[]'::jsonb),
    'releases', coalesce((select jsonb_agg(public.shiplog_public_release_content(r.id) order by r.published_at desc, r.id)
      from public.shiplog_releases r join public.shiplog_applications a on a.id = r.application_id
      where a.workspace_id = target and a.public_enabled and r.published_at is not null), '[]'::jsonb)
  ) into result from public.workspaces w where w.id = target;
  return result;
end;
$$;

revoke all on function public.shiplog_lock_draft(uuid), public.shiplog_update_draft(uuid,jsonb),
  public.shiplog_save_change(uuid,jsonb,uuid), public.shiplog_delete_change(uuid,uuid),
  public.shiplog_public_release_content(uuid), public.shiplog_preview_release(uuid) from public, anon, authenticated;
grant execute on function public.shiplog_update_draft(uuid,jsonb), public.shiplog_save_change(uuid,jsonb,uuid),
  public.shiplog_delete_change(uuid,uuid), public.shiplog_preview_release(uuid) to authenticated;
