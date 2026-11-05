-- Preserve public change text in notes; internal changes and their audit text are retired.
do $$
begin
  if exists (
    select 1 from public.shiplog_releases r
    where length(concat_ws(E'\n\n', nullif(r.public_notes,''),
      (select string_agg(c.title || case when c.description <> '' then E'\n' || c.description else '' end,
        E'\n\n' order by c.created_at,c.id)
       from public.shiplog_release_changes c where c.release_id = r.id and c.is_public))) > 20000
  ) then
    raise exception 'Migrated release notes exceed 20000 characters; review before migration';
  end if;
end;
$$;
update public.shiplog_releases r set public_notes = concat_ws(E'\n\n', nullif(r.public_notes,''),
  (select string_agg(c.title || case when c.description <> '' then E'\n' || c.description else '' end,
    E'\n\n' order by c.created_at,c.id)
   from public.shiplog_release_changes c where c.release_id = r.id and c.is_public));

create table public.shiplog_release_features (
  release_id uuid not null references public.shiplog_releases(id) on delete cascade,
  feature_id uuid not null references public.features(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  primary key(release_id,feature_id)
);
alter table public.shiplog_release_features enable row level security;
revoke all on public.shiplog_release_features from public, anon, authenticated;

create function public.shiplog_list_features(release uuid, candidates boolean default false)
returns table(id uuid,name text,linked boolean)
language plpgsql stable security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select r.* into target from public.shiplog_releases r where r.id = release;
  if public.workspace_access(target.workspace_id,'shiplog') is null then
    raise exception 'Shiplog access required' using errcode = '42501';
  end if;
  if candidates and coalesce(public.workspace_access(target.workspace_id,'planner') in ('owner','editor','viewer'),false) = false then
    raise exception 'Planner access required' using errcode = '42501';
  end if;
  if candidates then
    return query select f.id,f.name,exists(
      select 1 from public.shiplog_release_features l where l.release_id = release and l.feature_id = f.id)
      from public.features f join public.projects p on p.id = f.project_id
      where p.workspace_id = target.workspace_id order by lower(f.name),f.id;
  else
    return query select l.feature_id,l.name,true from public.shiplog_release_features l
      where l.release_id = release order by lower(l.name),l.feature_id;
  end if;
end;
$$;

create function public.shiplog_link_feature(release uuid, feature uuid, linked boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases; feature_name text;
begin
  target := public.shiplog_lock_draft(release);
  if coalesce(public.workspace_access(target.workspace_id,'planner') in ('owner','editor','viewer'),false) = false then
    raise exception 'Planner access required' using errcode = '42501';
  end if;
  if linked is null then raise exception 'Link state required' using errcode = '22023'; end if;
  select f.name into feature_name from public.features f join public.projects p on p.id = f.project_id
    where f.id = feature and p.workspace_id = target.workspace_id for share of f,p;
  if not found then raise exception 'Planner feature unavailable' using errcode = 'P0002'; end if;
  if linked then
    insert into public.shiplog_release_features(release_id,feature_id,name) values(release,feature,feature_name)
      on conflict (release_id,feature_id) do nothing;
  else
    delete from public.shiplog_release_features l where l.release_id = release and l.feature_id = feature;
  end if;
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id,details)
    values(target.workspace_id,target.application_id,release,
      case when linked then 'feature.linked' else 'feature.unlinked' end,auth.uid(),
      jsonb_build_object('feature_id',feature));
end;
$$;

create function public.shiplog_update_details(release uuid,input jsonb,status text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases; app uuid;
begin
  select application_id into app from public.shiplog_releases where id = release;
  perform 1 from public.shiplog_applications where id = app for update;
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then
    raise exception 'Shiplog edit access required' using errcode = '42501';
  end if;
  if status is null or status not in ('draft','qa','released') then
    raise exception 'Invalid release status' using errcode = '22023';
  end if;
  if target.status = 'draft' then
    perform public.shiplog_update_draft(release,input);
  else
    if input->>'version' is distinct from target.version or input->>'title' is distinct from target.title
      or input->>'application_id' is distinct from target.application_id::text then
      raise exception 'Only drafts can be edited' using errcode = '23514';
    end if;
    perform public.shiplog_update_public_notes(release,input->>'public_notes');
  end if;
  if target.status <> status then perform public.shiplog_set_release_status(release,status); end if;
end;
$$;

create or replace function public.shiplog_public_release_content(release uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id',r.id,'application_id',r.application_id,'version',r.version,
    'title',r.title,'release_type',r.release_type,'public_notes',r.public_notes,
    'status',r.status,'created_at',r.created_at,
    'features',coalesce((select jsonb_agg(jsonb_build_object('name',l.name) order by lower(l.name),l.feature_id)
      from public.shiplog_release_features l where l.release_id = r.id),'[]'::jsonb)
  ) from public.shiplog_releases r where r.id = release;
$$;

drop function public.shiplog_save_change(uuid,jsonb,uuid);
drop function public.shiplog_delete_change(uuid,uuid);
drop table public.shiplog_release_changes;
delete from public.shiplog_audit_events where event in ('change.created','change.updated','change.deleted');

revoke all on function public.shiplog_list_features(uuid,boolean),
  public.shiplog_link_feature(uuid,uuid,boolean),public.shiplog_update_details(uuid,jsonb,text)
  from public,anon;
grant execute on function public.shiplog_list_features(uuid,boolean),
  public.shiplog_link_feature(uuid,uuid,boolean),public.shiplog_update_details(uuid,jsonb,text)
  to authenticated;
