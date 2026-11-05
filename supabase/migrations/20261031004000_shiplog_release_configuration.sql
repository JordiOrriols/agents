create function public.shiplog_workspace_features(workspace uuid)
returns table(id uuid, name text, linked boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.workspace_access(workspace,'shiplog') is null then
    raise exception 'Shiplog access required' using errcode = '42501';
  end if;
  if public.workspace_access(workspace,'planner') is null then
    raise exception 'Planner access required' using errcode = '42501';
  end if;
  return query select f.id,f.name,false from public.features f
    join public.projects p on p.id = f.project_id
    where p.workspace_id = workspace order by lower(f.name),f.id;
end;
$$;

-- Save links before changing status: linking is draft-only, and a failed save
-- must roll back the release, feature links and audit events together.
create function public.shiplog_save_configuration(
  input jsonb, status text, feature_ids uuid[] default null, release uuid default null
)
returns public.shiplog_releases
language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases; feature uuid; app uuid;
begin
  if release is null then
    target := public.shiplog_create_release(input);
  else
    select application_id into app from public.shiplog_releases where id = release;
    if not found then raise exception 'Release not found' using errcode = 'P0002'; end if;
    perform 1 from public.shiplog_applications where id = app for update;
    select * into target from public.shiplog_releases where id = release for update;
    if not public.shiplog_can_edit(target.workspace_id) then
      raise exception 'Shiplog edit access required' using errcode = '42501';
    end if;
  end if;
  if feature_ids is not null then
    if target.status <> 'draft' then
      raise exception 'Only drafts can be edited' using errcode = '23514';
    end if;
    if array_position(feature_ids,null) is not null then
      raise exception 'Planner feature unavailable' using errcode = '22023';
    end if;
    if public.workspace_access(target.workspace_id,'planner') is null then
      raise exception 'Planner access required' using errcode = '42501';
    end if;
    for feature in select l.feature_id from public.shiplog_release_features l
      where l.release_id = target.id and not (l.feature_id = any(feature_ids))
    loop
      perform public.shiplog_link_feature(target.id,feature,false);
    end loop;
    for feature in select distinct unnest(feature_ids) loop
      if not exists (select 1 from public.shiplog_release_features l
        where l.release_id = target.id and l.feature_id = feature) then
        perform public.shiplog_link_feature(target.id,feature,true);
      end if;
    end loop;
  end if;
  perform public.shiplog_update_details(target.id,input,status);
  select * into target from public.shiplog_releases where id = target.id;
  return target;
end;
$$;

revoke all on function public.shiplog_workspace_features(uuid),
  public.shiplog_save_configuration(jsonb,text,uuid[],uuid) from public,anon;
grant execute on function public.shiplog_workspace_features(uuid),
  public.shiplog_save_configuration(jsonb,text,uuid[],uuid) to authenticated;
