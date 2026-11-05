-- Application inclusion is automatic; the workspace token remains the public gate.
drop function public.shiplog_set_application_public(uuid,boolean);
alter table public.shiplog_applications drop column public_enabled;
delete from public.shiplog_audit_events
  where event in ('application.public_enabled','application.public_disabled');
update public.shiplog_audit_events set details =
  (details - 'public_enabled')
  || case when jsonb_typeof(details->'before') = 'object'
    then jsonb_build_object('before', (details->'before') - 'public_enabled') else '{}'::jsonb end
  || case when jsonb_typeof(details->'after') = 'object'
    then jsonb_build_object('after', (details->'after') - 'public_enabled') else '{}'::jsonb end;

create or replace function public.shiplog_public_catalog(token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target uuid; result jsonb;
begin
  select p.workspace_id into target from public.shiplog_portals p where p.token = $1;
  if target is null then raise exception 'Release catalog unavailable' using errcode = 'P0002'; end if;
  select jsonb_build_object(
    'name',w.name,
    'applications',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'name',a.name) order by a.name,a.id)
      from public.shiplog_applications a where a.workspace_id = target),'[]'::jsonb),
    'releases',coalesce((select jsonb_agg(public.shiplog_public_release_content(r.id) order by r.created_at desc,r.id)
      from public.shiplog_releases r where r.workspace_id = target),'[]'::jsonb)
  ) into result from public.workspaces w where w.id = target;
  return result;
end;
$$;
