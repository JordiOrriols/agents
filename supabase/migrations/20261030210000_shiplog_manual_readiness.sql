create table public.shiplog_checklist_templates (
  application_id uuid primary key references public.shiplog_applications(id) on delete cascade,
  revision integer not null check (revision > 0),
  items jsonb not null
);
create table public.shiplog_readiness (
  release_id uuid primary key references public.shiplog_releases(id) on delete cascade,
  template_revision integer not null default 0,
  qa_status text not null default 'not_started'
    check (qa_status in ('not_started','running','passed','failed','partially_passed','skipped')),
  qa_notes text not null default '' check (length(qa_notes) <= 10000),
  qa_recorded_by uuid references auth.users(id) on delete set null,
  qa_recorded_at timestamptz,
  approved_by uuid references auth.users(id) on delete set null,
  approved_at timestamptz,
  approval_override_reason text not null default ''
);
create table public.shiplog_checklist_items (
  id uuid primary key default gen_random_uuid(),
  release_id uuid not null references public.shiplog_readiness(release_id) on delete cascade,
  position integer not null,
  category text not null,
  title text not null,
  description text not null,
  mandatory boolean not null,
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz,
  unique(release_id, position)
);

alter table public.shiplog_checklist_templates enable row level security;
alter table public.shiplog_readiness enable row level security;
alter table public.shiplog_checklist_items enable row level security;
revoke all on public.shiplog_checklist_templates, public.shiplog_readiness,
  public.shiplog_checklist_items from anon, authenticated;
grant select on public.shiplog_checklist_templates, public.shiplog_readiness,
  public.shiplog_checklist_items to authenticated;
create policy shiplog_templates_read on public.shiplog_checklist_templates for select to authenticated
  using (exists(select 1 from public.shiplog_applications a where a.id = application_id));
create policy shiplog_readiness_read on public.shiplog_readiness for select to authenticated
  using (exists(select 1 from public.shiplog_releases r where r.id = release_id));
create policy shiplog_checklist_read on public.shiplog_checklist_items for select to authenticated
  using (exists(select 1 from public.shiplog_releases r where r.id = release_id));

create function public.shiplog_save_checklist_template(application uuid, items jsonb, expected_revision integer)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_applications; item jsonb; current_revision integer;
begin
  select * into target from public.shiplog_applications where id = application for update;
  if not public.workspace_is_owner(target.workspace_id) then
    raise exception 'Workspace owner access required' using errcode = '42501';
  end if;
  select coalesce((select t.revision from public.shiplog_checklist_templates t
    where t.application_id = application),0) into current_revision;
  if expected_revision is distinct from current_revision then
    raise exception 'Checklist template changed. Reload before saving.' using errcode = '40001';
  end if;
  if items is null or jsonb_typeof(items) <> 'array' then raise exception 'Checklist items must be an array'; end if;
  if jsonb_array_length(items) > 100 then raise exception 'At most 100 checklist items are allowed'; end if;
  for item in select value from jsonb_array_elements(items) loop
    if jsonb_typeof(item) <> 'object'
      or jsonb_typeof(item->'title') is distinct from 'string'
      or length(btrim(item->>'title')) not between 1 and 160
      or jsonb_typeof(item->'category') is distinct from 'string'
      or length(btrim(item->>'category')) not between 1 and 80
      or jsonb_typeof(item->'description') is distinct from 'string'
      or length(item->>'description') > 4000
      or jsonb_typeof(item->'mandatory') is distinct from 'boolean' then
      raise exception 'Invalid checklist item';
    end if;
  end loop;
  insert into public.shiplog_checklist_templates(application_id, revision, items)
    values(application, current_revision + 1, items)
    on conflict(application_id) do update set revision = excluded.revision, items = excluded.items;
  insert into public.shiplog_audit_events(workspace_id, application_id, event, actor_id, details)
    values(target.workspace_id, application, 'checklist.template_updated', auth.uid(),
      jsonb_build_object('revision', current_revision + 1, 'items', items));
end;
$$;

-- Serialize release creation with template edits, then copy immutable item definitions.
create function public.shiplog_snapshot_checklist()
returns trigger language plpgsql security definer set search_path = '' as $$
declare template public.shiplog_checklist_templates;
begin
  perform 1 from public.shiplog_applications where id = new.application_id for update;
  select * into template from public.shiplog_checklist_templates where application_id = new.application_id;
  insert into public.shiplog_readiness(release_id, template_revision) values(new.id, coalesce(template.revision,0));
  insert into public.shiplog_checklist_items(release_id, position, category, title, description, mandatory)
    select new.id, n::integer, btrim(item->>'category'), btrim(item->>'title'),
      item->>'description', (item->>'mandatory')::boolean
    from jsonb_array_elements(coalesce(template.items,'[]'::jsonb)) with ordinality as items(item,n);
  return new;
end;
$$;
create trigger shiplog_release_checklist after insert on public.shiplog_releases
  for each row execute function public.shiplog_snapshot_checklist();
-- Existing releases did not have a template. Never retroactively apply today's checklist.
insert into public.shiplog_readiness(release_id) select id from public.shiplog_releases;

create function public.shiplog_get_readiness(release uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release;
  if public.workspace_access(target.workspace_id,'shiplog') is null then
    raise exception 'Shiplog access required' using errcode = '42501';
  end if;
  return (select to_jsonb(q) || jsonb_build_object('items',coalesce(
    (select jsonb_agg(to_jsonb(i) order by i.position) from public.shiplog_checklist_items i where i.release_id = release),
    '[]'::jsonb)) from public.shiplog_readiness q where q.release_id = release);
end;
$$;

create function public.shiplog_lock_readiness(release uuid)
returns public.shiplog_releases language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  select * into target from public.shiplog_releases where id = release for update;
  if not public.shiplog_can_edit(target.workspace_id) then
    raise exception 'Shiplog edit access required' using errcode = '42501';
  end if;
  if target.status not in ('draft','ready_for_qa','qa_in_progress','qa_passed','approved') then
    raise exception 'Readiness is locked for this release';
  end if;
  return target;
end;
$$;

create function public.shiplog_complete_checklist_item(release uuid, item uuid, completed boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  target := public.shiplog_lock_readiness(release);
  if target.status = 'approved' then raise exception 'Reopen QA before changing an approved release'; end if;
  if completed is null then raise exception 'Completion state required'; end if;
  update public.shiplog_checklist_items set
    completed_at = case when completed then coalesce(completed_at,now()) else null end,
    completed_by = case when completed then coalesce(completed_by,auth.uid()) else null end
    where id = item and release_id = release;
  if not found then raise exception 'Checklist item not found' using errcode = 'P0002'; end if;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id, details)
    values(target.workspace_id, target.application_id, release, 'checklist.item_updated', auth.uid(),
      jsonb_build_object('item_id',item,'completed',completed));
end;
$$;

create function public.shiplog_record_manual_qa(release uuid, qa_status text, notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases;
begin
  target := public.shiplog_lock_readiness(release);
  if target.status = 'approved' then raise exception 'Reopen QA before changing an approved release'; end if;
  if target.status = 'draft' then raise exception 'Mark the release ready for QA first'; end if;
  if qa_status is null or qa_status not in ('not_started','running','passed','failed','partially_passed','skipped')
    or notes is null or length(notes) > 10000 then raise exception 'Invalid manual QA result'; end if;
  update public.shiplog_readiness set qa_status = $2, qa_notes = notes,
    qa_recorded_by = auth.uid(), qa_recorded_at = now() where release_id = release;
  update public.shiplog_releases set status = case when qa_status = 'passed' then 'qa_passed' else 'qa_in_progress' end where id = release;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id, details)
    values(target.workspace_id, target.application_id, release, 'qa.recorded', auth.uid(),
      jsonb_build_object('status',qa_status,'notes',notes));
end;
$$;

create function public.shiplog_transition_readiness(release uuid, transition text, override_reason text default '')
returns void language plpgsql security definer set search_path = '' as $$
declare target public.shiplog_releases; reason text := btrim(override_reason);
  missing_items integer; qa text; blockers boolean;
begin
  target := public.shiplog_lock_readiness(release);
  if reason is null or length(reason) > 4000 then raise exception 'Invalid override reason'; end if;
  select count(*) into missing_items from public.shiplog_checklist_items
    where release_id = release and mandatory and completed_at is null;
  select qa_status into qa from public.shiplog_readiness where release_id = release;
  if transition = 'ready_for_qa' then
    if target.status <> 'draft' then raise exception 'Only drafts can be marked ready for QA'; end if;
    blockers := missing_items > 0;
  elsif transition = 'approved' then
    if not public.workspace_is_owner(target.workspace_id) then
      raise exception 'Workspace owner access required' using errcode = '42501';
    end if;
    if target.status not in ('ready_for_qa','qa_in_progress','qa_passed') then
      raise exception 'Release must enter QA before approval';
    end if;
    blockers := missing_items > 0 or qa <> 'passed';
  elsif transition = 'reopen_qa' then
    if target.status <> 'approved' then raise exception 'Only approved releases can reopen QA'; end if;
    if reason = '' then raise exception 'A reason is required to reopen QA'; end if;
    update public.shiplog_readiness set qa_status = 'not_started', qa_notes = '',
      qa_recorded_by = null, qa_recorded_at = null, approved_by = null, approved_at = null,
      approval_override_reason = '' where release_id = release;
    update public.shiplog_releases set status = 'qa_in_progress' where id = release;
  else raise exception 'Invalid readiness transition';
  end if;
  if transition <> 'reopen_qa' then
    if reason <> '' and not public.workspace_is_owner(target.workspace_id) then
      raise exception 'Workspace owner access required for overrides' using errcode = '42501';
    end if;
    if blockers and reason = '' then
      raise exception 'Readiness requirements are incomplete; an owner override reason is required';
    end if;
    update public.shiplog_releases set status = transition where id = release;
    if transition = 'approved' then
      update public.shiplog_readiness set approved_by = auth.uid(), approved_at = now(),
        approval_override_reason = reason where release_id = release;
    end if;
  end if;
  insert into public.shiplog_audit_events(workspace_id, application_id, release_id, event, actor_id, details)
    values(target.workspace_id, target.application_id, release, 'readiness.' || transition, auth.uid(),
      jsonb_build_object('previous_status',target.status,'override_reason',reason,
        'missing_mandatory',missing_items,'qa_status',qa));
end;
$$;

revoke all on function public.shiplog_save_checklist_template(uuid,jsonb,integer),
  public.shiplog_snapshot_checklist(), public.shiplog_get_readiness(uuid),
  public.shiplog_lock_readiness(uuid), public.shiplog_complete_checklist_item(uuid,uuid,boolean),
  public.shiplog_record_manual_qa(uuid,text,text), public.shiplog_transition_readiness(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.shiplog_save_checklist_template(uuid,jsonb,integer),
  public.shiplog_get_readiness(uuid), public.shiplog_complete_checklist_item(uuid,uuid,boolean),
  public.shiplog_record_manual_qa(uuid,text,text), public.shiplog_transition_readiness(uuid,text,text)
  to authenticated;
