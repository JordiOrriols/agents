alter table public.shiplog_releases add column first_deployed_at timestamptz;

create table public.shiplog_deployments (
  id uuid primary key default gen_random_uuid(),
  sequence bigint generated always as identity unique,
  application_id uuid not null references public.shiplog_applications(id) on delete cascade,
  environment_id uuid not null,
  release_id uuid not null,
  outcome text not null check (outcome in ('succeeded','failed','cancelled','rollback')),
  rollback_target_id uuid,
  started_at timestamptz not null check (isfinite(started_at)),
  completed_at timestamptz not null check (isfinite(completed_at) and completed_at >= started_at),
  source text not null check (length(btrim(source)) between 1 and 120),
  build_reference text not null default '' check (length(build_reference) <= 300),
  pipeline_url text not null default '' check (length(pipeline_url) <= 2000 and
    (pipeline_url = '' or pipeline_url ~ '^https?://[^[:space:]]+$')),
  notes text not null default '' check (length(notes) <= 10000),
  error_details text not null default '' check (length(error_details) <= 10000),
  recorded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  readiness_warnings jsonb not null,
  foreign key (environment_id, application_id) references public.shiplog_environments(id, application_id),
  foreign key (release_id, application_id) references public.shiplog_releases(id, application_id),
  foreign key (rollback_target_id, application_id) references public.shiplog_releases(id, application_id),
  check ((outcome = 'rollback' and rollback_target_id is not null and rollback_target_id <> release_id
    and length(btrim(notes)) > 0) or (outcome <> 'rollback' and rollback_target_id is null))
);
create index on public.shiplog_deployments(application_id, completed_at desc, sequence desc);
create index on public.shiplog_deployments(environment_id, completed_at desc, sequence desc);
alter table public.shiplog_deployments enable row level security;
revoke all on public.shiplog_deployments from anon, authenticated;
grant select on public.shiplog_deployments to authenticated;
create policy shiplog_deployments_read on public.shiplog_deployments for select to authenticated
  using (exists(select 1 from public.shiplog_applications a where a.id = application_id));

-- A view of reported outcomes, not a claim that Shiplog queried the running system.
create view public.shiplog_environment_versions with (security_invoker = true) as
  select distinct on (d.environment_id)
    d.environment_id, d.application_id, d.id as deployment_id,
    case when d.outcome = 'rollback' then d.rollback_target_id else d.release_id end as release_id,
    d.completed_at
  from public.shiplog_deployments d where d.outcome in ('succeeded','rollback')
  order by d.environment_id, d.completed_at desc, d.sequence desc;
revoke all on public.shiplog_environment_versions from anon, authenticated;
grant select on public.shiplog_environment_versions to authenticated;

create function public.shiplog_record_deployment(input jsonb)
returns public.shiplog_deployments language plpgsql security definer set search_path = '' as $$
declare env public.shiplog_environments; target public.shiplog_releases;
  effective public.shiplog_releases; result public.shiplog_deployments;
  outcome text := input->>'outcome'; rollback_target uuid := (input->>'rollback_target_id')::uuid;
  started timestamptz := (input->>'started_at')::timestamptz;
  completed timestamptz := (input->>'completed_at')::timestamptz;
  warnings jsonb := '[]'::jsonb; missing integer; qa text; previous uuid;
begin
  select * into env from public.shiplog_environments where id = (input->>'environment_id')::uuid for update;
  if not public.shiplog_can_edit((select workspace_id from public.shiplog_applications where id = env.application_id)) then
    raise exception 'Shiplog edit access required' using errcode = '42501';
  end if;
  if started is null or completed is null or not isfinite(started) or not isfinite(completed)
    or started > completed or completed > now() then
    raise exception 'Deployment timestamps must describe a completed outcome';
  end if;
  select * into target from public.shiplog_releases
    where id = (input->>'release_id')::uuid and application_id = env.application_id;
  if not found then raise exception 'Release must belong to the environment application'; end if;
  effective := target;
  if outcome = 'rollback' then
    select * into effective from public.shiplog_releases
      where id = rollback_target and application_id = env.application_id;
    if not found or rollback_target = target.id then raise exception 'Invalid rollback target'; end if;
    if not exists(select 1 from public.shiplog_deployments d
      where d.environment_id = env.id and d.completed_at <= completed
      and ((d.outcome = 'succeeded' and d.release_id = rollback_target)
        or (d.outcome = 'rollback' and d.rollback_target_id = rollback_target))) then
      raise exception 'Rollback target must have been deployed to this environment before';
    end if;
    select case when d.outcome = 'rollback' then d.rollback_target_id else d.release_id end
      into previous from public.shiplog_deployments d
      where d.environment_id = env.id and d.completed_at <= completed and d.outcome in ('succeeded','rollback')
      order by d.completed_at desc, d.sequence desc limit 1;
    if previous is distinct from target.id then
      raise exception 'Rollback source must match the reported environment version at that time';
    end if;
  end if;
  -- Readiness decisions and draft edits lock this same release row.
  perform 1 from public.shiplog_releases where id = effective.id for update;
  select * into effective from public.shiplog_releases where id = effective.id;
  if env.kind = 'production' then
    if effective.status <> 'approved' then warnings := warnings || '["release_not_approved"]'::jsonb; end if;
    select q.qa_status into qa from public.shiplog_readiness q where q.release_id = effective.id;
    if qa is distinct from 'passed' then warnings := warnings || '["manual_qa_not_passed"]'::jsonb; end if;
    select count(*) into missing from public.shiplog_checklist_items i
      where i.release_id = effective.id and i.mandatory and i.completed_at is null;
    if missing > 0 then warnings := warnings || '["mandatory_items_incomplete"]'::jsonb; end if;
  end if;
  insert into public.shiplog_deployments(application_id, environment_id, release_id, outcome, rollback_target_id,
    started_at, completed_at, source, build_reference, pipeline_url, notes, error_details, recorded_by, readiness_warnings)
    values(env.application_id, env.id, target.id, outcome, rollback_target, started, completed,
      btrim(input->>'source'), coalesce(input->>'build_reference',''), coalesce(input->>'pipeline_url',''),
      coalesce(input->>'notes',''), coalesce(input->>'error_details',''), auth.uid(), warnings)
    returning * into result;
  if outcome in ('succeeded','rollback') then
    -- Lock the effective release as content edits do; do not rewrite QA/lifecycle or publication.
    update public.shiplog_releases set first_deployed_at =
      case when first_deployed_at is null then completed else least(first_deployed_at,completed) end
      where id = effective.id;
  end if;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id, details)
    values(target.workspace_id, env.application_id, target.id, 'deployment.recorded', auth.uid(), to_jsonb(result));
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
  if target.status <> 'draft' or target.first_published_at is not null or target.first_deployed_at is not null then
    raise exception 'Only never-published drafts that have never been deployed can be edited' using errcode = '23514';
  end if;
  return target;
end;
$$;
revoke all on function public.shiplog_record_deployment(jsonb) from public, anon, authenticated;
grant execute on function public.shiplog_record_deployment(jsonb) to authenticated;
