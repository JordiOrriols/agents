create function public.shiplog_delete_application(application uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_applications;
begin
  select * into target from public.shiplog_applications where id = application for update;
  if not found then raise exception 'Application not found' using errcode = 'P0002'; end if;
  if not public.shiplog_can_edit(target.workspace_id) then
    raise exception 'Shiplog edit access required' using errcode = '42501';
  end if;
  if exists (select 1 from public.shiplog_releases r where r.application_id = application) then
    raise exception 'Applications with releases cannot be deleted' using errcode = '23514';
  end if;
  delete from public.shiplog_applications where id = application;
  insert into public.shiplog_audit_events(workspace_id,event,actor_id,details)
    values(target.workspace_id,'application.deleted',auth.uid(),jsonb_build_object('before',to_jsonb(target)));
end;
$$;
revoke all on function public.shiplog_delete_application(uuid) from public, anon;
grant execute on function public.shiplog_delete_application(uuid) to authenticated;
