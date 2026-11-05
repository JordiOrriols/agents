-- Remove retired deployment data and publication state without changing application privacy.
drop function public.shiplog_record_deployment(jsonb);
drop view public.shiplog_environment_versions;
drop table public.shiplog_deployments;
drop table public.shiplog_environments;
drop function public.shiplog_publish_release(uuid,boolean);
drop function public.shiplog_preview_release(uuid);

delete from public.shiplog_audit_events
  where event in ('deployment.recorded','release.published','release.unpublished');
update public.shiplog_audit_events set details =
  (details - 'published_at' - 'first_published_at' - 'first_deployed_at')
  || case when jsonb_typeof(details->'before') = 'object'
    then jsonb_build_object('before', (details->'before') - 'published_at' - 'first_published_at' - 'first_deployed_at') else '{}'::jsonb end
  || case when jsonb_typeof(details->'after') = 'object'
    then jsonb_build_object('after', (details->'after') - 'published_at' - 'first_published_at' - 'first_deployed_at') else '{}'::jsonb end;
alter table public.shiplog_releases
  drop column published_at, drop column first_published_at, drop column first_deployed_at;

create or replace function public.shiplog_save_application(workspace uuid, application_name text,
  application_description text default '', team uuid default null, application uuid default null)
returns public.shiplog_applications language plpgsql security definer set search_path = '' as $$
declare result public.shiplog_applications; previous public.shiplog_applications;
begin
  if not public.shiplog_can_edit(workspace) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  if application is null then
    insert into public.shiplog_applications(workspace_id,name,description,team_id)
      values(workspace,btrim(application_name),application_description,team) returning * into result;
  else
    select * into previous from public.shiplog_applications where id = application and workspace_id = workspace for update;
    if not found then raise exception 'Application not found'; end if;
    update public.shiplog_applications set name = btrim(application_name),description = application_description,team_id = team
      where id = application returning * into result;
  end if;
  insert into public.shiplog_audit_events(workspace_id,application_id,event,actor_id,details)
    values(workspace,result.id,case when application is null then 'application.created' else 'application.updated' end,
      auth.uid(),jsonb_build_object('before',to_jsonb(previous),'after',to_jsonb(result)));
  return result;
end;
$$;

create or replace function public.shiplog_lock_draft(release uuid)
returns public.shiplog_releases language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then
    raise exception 'Shiplog edit access required' using errcode = '42501';
  end if;
  if target.status <> 'draft' then raise exception 'Only drafts can be edited' using errcode = '23514'; end if;
  return target;
end;
$$;

create or replace function public.shiplog_public_release_content(release uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id',r.id,'application_id',r.application_id,'version',r.version,
    'title',r.title,'release_type',r.release_type,'public_notes',r.public_notes,
    'status',r.status,'created_at',r.created_at,
    'changes',coalesce((select jsonb_agg(jsonb_build_object(
      'category',c.category,'title',c.title,'description',c.description)
      order by c.created_at,c.id)
      from public.shiplog_release_changes c where c.release_id = r.id and c.is_public),'[]'::jsonb)
  ) from public.shiplog_releases r where r.id = release;
$$;

create or replace function public.shiplog_public_catalog(token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target uuid; result jsonb;
begin
  select p.workspace_id into target from public.shiplog_portals p where p.token = $1;
  if target is null then raise exception 'Release catalog unavailable' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'name',w.name,
    'applications',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.name) order by a.name,a.id)
      from public.shiplog_applications a where a.workspace_id = target and a.public_enabled),'[]'::jsonb),
    'releases',coalesce((select jsonb_agg(public.shiplog_public_release_content(r.id) order by r.created_at desc,r.id)
      from public.shiplog_releases r join public.shiplog_applications a on a.id = r.application_id
      where r.workspace_id = target and a.public_enabled),'[]'::jsonb)
  ) into result from public.workspaces w where w.id = target;
  return result;
end;
$$;
