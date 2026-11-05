-- Explicitly requested destructive cleanup, including private audit snapshots.
update public.shiplog_audit_events set details =
  (details - 'internal_notes' - 'slug' - 'platform')
  || case when jsonb_typeof(details->'before') = 'object'
    then jsonb_build_object('before', (details->'before') - 'internal_notes' - 'slug' - 'platform') else '{}'::jsonb end
  || case when jsonb_typeof(details->'after') = 'object'
    then jsonb_build_object('after', (details->'after') - 'internal_notes' - 'slug' - 'platform') else '{}'::jsonb end;
drop function public.shiplog_create_application(uuid,text,text,text,text);
alter table public.shiplog_applications drop column slug, drop column platform;
alter table public.shiplog_applications add column team_id uuid references public.teams(id) on delete set null;
alter table public.shiplog_releases drop column internal_notes;
alter table public.shiplog_releases drop constraint shiplog_releases_status_check;
update public.shiplog_releases set status = case
  when status = 'draft' then 'draft'
  when status in ('released','deprecated','rolled_back') then 'released' else 'qa' end;
alter table public.shiplog_releases add constraint shiplog_releases_status_check check (status in ('draft','qa','released'));

create function public.shiplog_validate_application_team()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.team_id is not null then
    perform 1 from public.teams where id = new.team_id and workspace_id = new.workspace_id for share;
    if not found then raise exception 'Team must belong to this workspace'; end if;
  end if;
  return new;
end;
$$;
create trigger shiplog_application_team before insert or update of team_id,workspace_id
  on public.shiplog_applications for each row execute function public.shiplog_validate_application_team();

create function public.shiplog_list_teams(workspace uuid)
returns table(id uuid,name text) language plpgsql stable security definer set search_path = '' as $$
begin
  if public.workspace_access(workspace,'shiplog') is null then raise exception 'Shiplog access required' using errcode = '42501'; end if;
  return query select t.id,t.name from public.teams t where t.workspace_id = workspace order by t.name,t.id;
end;
$$;

create function public.shiplog_save_application(workspace uuid, application_name text,
  application_description text default '', team uuid default null, application uuid default null)
returns public.shiplog_applications language plpgsql security definer set search_path = '' as $$
declare result public.shiplog_applications; previous public.shiplog_applications;
begin
  if not public.shiplog_can_edit(workspace) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  if application is null then
    insert into public.shiplog_applications(workspace_id,name,description,team_id)
      values(workspace,btrim(application_name),application_description,team) returning * into result;
    insert into public.shiplog_environments(application_id,name,slug,kind) values
      (result.id,'Staging','staging','staging'),(result.id,'Production','production','production');
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

-- Full SemVer precedence, including numeric prerelease identifiers and ignored build metadata.
create function public.shiplog_compare_versions(a text,b text)
returns integer language plpgsql immutable set search_path = '' as $$
declare ac text[] := string_to_array(split_part(split_part(a,'+',1),'-',1),'.');
  bc text[] := string_to_array(split_part(split_part(b,'+',1),'-',1),'.');
  ap text; bp text; ax text[]; bx text[]; i integer;
begin
  for i in 1..3 loop
    if ac[i]::numeric <> bc[i]::numeric then return case when ac[i]::numeric > bc[i]::numeric then 1 else -1 end; end if;
  end loop;
  ap := substring(split_part(a,'+',1) from '^[^-]+-(.*)$');
  bp := substring(split_part(b,'+',1) from '^[^-]+-(.*)$');
  if ap is null and bp is null then return 0; end if;
  if ap is null then return 1; end if;
  if bp is null then return -1; end if;
  ax := string_to_array(ap,'.'); bx := string_to_array(bp,'.');
  for i in 1..least(array_length(ax,1),array_length(bx,1)) loop
    if ax[i] = bx[i] then continue; end if;
    if ax[i] ~ '^[0-9]+$' and bx[i] ~ '^[0-9]+$' then
      return case when ax[i]::numeric > bx[i]::numeric then 1 else -1 end;
    elsif ax[i] ~ '^[0-9]+$' then return -1;
    elsif bx[i] ~ '^[0-9]+$' then return 1;
    else return case when ax[i] collate "C" > bx[i] collate "C" then 1 else -1 end;
    end if;
  end loop;
  return case when array_length(ax,1) = array_length(bx,1) then 0
    when array_length(ax,1) > array_length(bx,1) then 1 else -1 end;
end;
$$;
create function public.shiplog_detect_release_type(application uuid,version text,excluded uuid default null)
returns text language plpgsql stable set search_path = '' as $$
declare latest text := '0.0.0'; candidate text; parts text[]; previous text[];
begin
  for candidate in select r.version from public.shiplog_releases r where r.application_id = application
    and (excluded is null or r.id <> excluded) loop
    if public.shiplog_compare_versions(candidate,latest) > 0 then latest := candidate; end if;
  end loop;
  parts := string_to_array(split_part(split_part(version,'+',1),'-',1),'.');
  previous := string_to_array(split_part(split_part(latest,'+',1),'-',1),'.');
  if parts[1]::numeric > previous[1]::numeric then return 'major'; end if;
  if parts[1]::numeric = previous[1]::numeric and parts[2]::numeric > previous[2]::numeric then return 'minor'; end if;
  return 'patch';
end;
$$;

create or replace function public.shiplog_create_release(input jsonb)
returns public.shiplog_releases language plpgsql security definer set search_path = '' as $$
declare app public.shiplog_applications; result public.shiplog_releases;
begin
  select * into app from public.shiplog_applications where id = (input->>'application_id')::uuid for update;
  if not public.shiplog_can_edit(app.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  insert into public.shiplog_releases(workspace_id,application_id,version,release_type,title,public_notes,created_by)
    values(app.workspace_id,app.id,input->>'version',public.shiplog_detect_release_type(app.id,input->>'version'),
      btrim(input->>'title'),coalesce(input->>'public_notes',''),auth.uid()) returning * into result;
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id)
    values(app.workspace_id,app.id,result.id,'release.created',auth.uid());
  return result;
end;
$$;

create or replace function public.shiplog_update_draft(release uuid,input jsonb)
returns public.shiplog_releases language plpgsql security definer set search_path = '' as $$
declare previous public.shiplog_releases; result public.shiplog_releases; app uuid;
begin
  select application_id into app from public.shiplog_releases where id = release;
  perform 1 from public.shiplog_applications where id = app for update;
  previous := public.shiplog_lock_draft(release);
  if input->>'application_id' is distinct from previous.application_id::text then raise exception 'The release application cannot be changed'; end if;
  update public.shiplog_releases set version = input->>'version',
    release_type = public.shiplog_detect_release_type(app,input->>'version',release),
    title = btrim(input->>'title'),public_notes = coalesce(input->>'public_notes','')
    where id = release returning * into result;
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id,details)
    values(result.workspace_id,app,release,'release.updated',auth.uid(),
      jsonb_build_object('before',to_jsonb(previous),'after',to_jsonb(result)));
  return result;
end;
$$;

create function public.shiplog_update_public_notes(release uuid,notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  if notes is null or length(notes) > 20000 then raise exception 'Invalid public notes'; end if;
  update public.shiplog_releases set public_notes = notes where id = release;
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id,details)
    values(target.workspace_id,target.application_id,release,'release.notes_updated',auth.uid(),
      jsonb_build_object('before',target.public_notes,'after',notes));
end;
$$;

create function public.shiplog_set_release_status(release uuid,status text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  if status is null or status not in ('draft','qa','released') then raise exception 'Invalid release status'; end if;
  update public.shiplog_releases set status = $2 where id = release;
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id,details)
    values(target.workspace_id,target.application_id,release,'release.status_updated',auth.uid(),
      jsonb_build_object('before',target.status,'after',status));
end;
$$;

-- Replace aggregate approval/override machinery with independent member decisions.
drop function public.shiplog_transition_readiness(uuid,text,text);
drop function public.shiplog_record_manual_qa(uuid,text,text);
drop function public.shiplog_lock_readiness(uuid);
create or replace function public.shiplog_complete_checklist_item(release uuid,item uuid,completed boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then raise exception 'Shiplog edit access required' using errcode = '42501'; end if;
  if completed is null then raise exception 'Completion state required'; end if;
  update public.shiplog_checklist_items set
    completed_at = case when completed then coalesce(completed_at,now()) else null end,
    completed_by = case when completed then coalesce(completed_by,auth.uid()) else null end
    where id = item and release_id = release;
  if not found then raise exception 'Checklist item not found'; end if;
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id,details)
    values(target.workspace_id,target.application_id,release,'checklist.item_updated',auth.uid(),
      jsonb_build_object('item_id',item,'completed',completed));
end;
$$;
create table public.shiplog_release_decisions (
  release_id uuid not null references public.shiplog_releases(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  approved boolean not null,
  decided_at timestamptz not null default now(),
  primary key(release_id,user_id)
);
alter table public.shiplog_release_decisions enable row level security;
revoke all on public.shiplog_release_decisions from anon,authenticated;
grant select on public.shiplog_release_decisions to authenticated;
create policy shiplog_decisions_read on public.shiplog_release_decisions for select to authenticated
  using(exists(select 1 from public.shiplog_releases r where r.id = release_id));
-- Preserve an existing approval as that owner's individual decision.
insert into public.shiplog_release_decisions(release_id,user_id,approved,decided_at)
  select release_id,approved_by,true,approved_at from public.shiplog_readiness
  where approved_by is not null and approved_at is not null;

create function public.shiplog_decide_release(release uuid,approved boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if public.workspace_access(target.workspace_id,'shiplog') is null then raise exception 'Shiplog access required' using errcode = '42501'; end if;
  if approved is null then raise exception 'Approval decision required'; end if;
  insert into public.shiplog_release_decisions(release_id,user_id,approved)
    values(release,auth.uid(),approved) on conflict(release_id,user_id)
    do update set approved = excluded.approved,decided_at = now();
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id,details)
    values(target.workspace_id,target.application_id,release,'release.decision',auth.uid(),jsonb_build_object('approved',approved));
end;
$$;
create function public.shiplog_list_release_decisions(release uuid)
returns table(user_id uuid,name text,approved boolean,decided_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare workspace uuid;
begin
  select workspace_id into workspace from public.shiplog_releases where id = release;
  if public.workspace_access(workspace,'shiplog') is null then raise exception 'Shiplog access required' using errcode = '42501'; end if;
  return query select u.id,u.email,d.approved,d.decided_at
    from auth.users u left join public.shiplog_release_decisions d on d.user_id = u.id and d.release_id = release
    where u.id = (select w.owner_id from public.workspaces w where w.id = workspace)
      or exists(select 1 from public.workspace_collaborators c where c.workspace_id = workspace and c.app = 'shiplog' and c.user_id = u.id)
    order by u.email,u.id;
end;
$$;

revoke all on function public.shiplog_validate_application_team(),public.shiplog_list_teams(uuid),
  public.shiplog_save_application(uuid,text,text,uuid,uuid),public.shiplog_compare_versions(text,text),
  public.shiplog_detect_release_type(uuid,text,uuid),public.shiplog_update_public_notes(uuid,text),
  public.shiplog_set_release_status(uuid,text),public.shiplog_decide_release(uuid,boolean),
  public.shiplog_list_release_decisions(uuid) from public,anon,authenticated;
grant execute on function public.shiplog_list_teams(uuid),public.shiplog_save_application(uuid,text,text,uuid,uuid),
  public.shiplog_update_public_notes(uuid,text),public.shiplog_set_release_status(uuid,text),
  public.shiplog_decide_release(uuid,boolean),public.shiplog_list_release_decisions(uuid) to authenticated;

-- Keep the append-only ledger and rollback rules, but derive warnings from checks/member decisions.
create or replace function public.shiplog_record_deployment(input jsonb)
returns public.shiplog_deployments language plpgsql security definer set search_path = '' as $$
declare env public.shiplog_environments; target public.shiplog_releases;
  effective public.shiplog_releases; result public.shiplog_deployments;
  outcome text := input->>'outcome'; rollback_target uuid := (input->>'rollback_target_id')::uuid;
  started timestamptz := (input->>'started_at')::timestamptz; completed timestamptz := (input->>'completed_at')::timestamptz;
  warnings jsonb := '[]'::jsonb; previous uuid; missing integer;
  has_approval boolean; has_disapproval boolean;
begin
  select * into env from public.shiplog_environments where id = (input->>'environment_id')::uuid for update;
  if not public.shiplog_can_edit((select workspace_id from public.shiplog_applications where id = env.application_id)) then
    raise exception 'Shiplog edit access required' using errcode = '42501';
  end if;
  if started is null or completed is null or not isfinite(started) or not isfinite(completed)
    or started > completed or completed > now() then raise exception 'Deployment timestamps must describe a completed outcome'; end if;
  select * into target from public.shiplog_releases where id = (input->>'release_id')::uuid and application_id = env.application_id;
  if not found then raise exception 'Release must belong to the environment application'; end if;
  effective := target;
  if outcome = 'rollback' then
    select * into effective from public.shiplog_releases where id = rollback_target and application_id = env.application_id;
    if not found or rollback_target = target.id then raise exception 'Invalid rollback target'; end if;
    if not exists(select 1 from public.shiplog_deployments d where d.environment_id = env.id and d.completed_at <= completed
      and ((d.outcome = 'succeeded' and d.release_id = rollback_target) or (d.outcome = 'rollback' and d.rollback_target_id = rollback_target))) then
      raise exception 'Rollback target must have been deployed to this environment before';
    end if;
    select case when d.outcome = 'rollback' then d.rollback_target_id else d.release_id end into previous
      from public.shiplog_deployments d where d.environment_id = env.id and d.completed_at <= completed and d.outcome in ('succeeded','rollback')
      order by d.completed_at desc,d.sequence desc limit 1;
    if previous is distinct from target.id then raise exception 'Rollback source must match the reported environment version at that time'; end if;
  end if;
  perform 1 from public.shiplog_releases where id = effective.id for update;
  if env.kind = 'production' then
    select coalesce(bool_or(d.approved),false),coalesce(bool_or(not d.approved),false)
      into has_approval,has_disapproval from public.shiplog_list_release_decisions(effective.id) d;
    if not has_approval or has_disapproval then
      warnings := warnings || '["release_not_approved"]'::jsonb;
    end if;
    select count(*) into missing from public.shiplog_checklist_items i where i.release_id = effective.id and i.mandatory and i.completed_at is null;
    if missing > 0 then warnings := warnings || '["mandatory_items_incomplete"]'::jsonb; end if;
  end if;
  insert into public.shiplog_deployments(application_id,environment_id,release_id,outcome,rollback_target_id,
    started_at,completed_at,source,build_reference,pipeline_url,notes,error_details,recorded_by,readiness_warnings)
    values(env.application_id,env.id,target.id,outcome,rollback_target,started,completed,btrim(input->>'source'),
      coalesce(input->>'build_reference',''),coalesce(input->>'pipeline_url',''),coalesce(input->>'notes',''),
      coalesce(input->>'error_details',''),auth.uid(),warnings) returning * into result;
  if outcome in ('succeeded','rollback') then
    update public.shiplog_releases set first_deployed_at = case when first_deployed_at is null then completed else least(first_deployed_at,completed) end
      where id = effective.id;
  end if;
  insert into public.shiplog_audit_events(workspace_id,application_id,release_id,event,actor_id,details)
    values(target.workspace_id,env.application_id,target.id,'deployment.recorded',auth.uid(),to_jsonb(result));
  return result;
end;
$$;
