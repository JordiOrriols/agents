-- Pulse: improvement actions of a workspace. Owners and editors (and the facilitator of the
-- retro an action comes from) create, edit and delete them; the action's owner and its
-- collaborators move it through its statuses, add notes and record the outcome. Owners and
-- collaborators are accounts with Pulse access to the workspace. Every change leaves a line in
-- pulse_action_updates, so the team can see what was agreed, changed, completed or cancelled.
-- Retros gain an "actions" stage between discussing and closing.

create table public.pulse_actions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  retro_id uuid references public.pulse_retros(id) on delete set null,
  group_id uuid references public.pulse_retro_groups(id) on delete set null,
  title text not null check (char_length(title) between 1 and 200),
  description text check (char_length(description) between 1 and 2000),
  owner_id uuid references auth.users(id) on delete set null,
  due_on date,
  priority text not null default 'medium' check (priority in ('low', 'medium', 'high')),
  status text not null default 'open' check (status in ('open', 'in_progress', 'done', 'cancelled')),
  success_criteria text check (char_length(success_criteria) between 1 and 1000),
  outcome text check (char_length(outcome) between 1 and 2000),
  helped boolean,
  follow_up text check (char_length(follow_up) between 1 and 2000),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index on public.pulse_actions(workspace_id, status);
create index on public.pulse_actions(retro_id);

create table public.pulse_action_collaborators (
  action_id uuid not null references public.pulse_actions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (action_id, user_id)
);

create table public.pulse_action_updates (
  id uuid primary key default gen_random_uuid(),
  action_id uuid not null references public.pulse_actions(id) on delete cascade,
  author_id uuid references auth.users(id) on delete set null default auth.uid(),
  kind text not null check (kind in ('created', 'edited', 'status', 'note', 'outcome')),
  status text check (status in ('open', 'in_progress', 'done', 'cancelled')),
  note text check (char_length(note) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index on public.pulse_action_updates(action_id, created_at);

alter table public.pulse_actions enable row level security;
alter table public.pulse_action_collaborators enable row level security;
alter table public.pulse_action_updates enable row level security;
revoke all on public.pulse_actions, public.pulse_action_collaborators, public.pulse_action_updates
  from anon, authenticated;

-- The new stage: retros now agree on actions before closing.
alter table public.pulse_retros drop constraint pulse_retros_stage_check;
alter table public.pulse_retros add constraint pulse_retros_stage_check
  check (stage in ('prepare', 'collect', 'group', 'vote', 'discuss', 'actions', 'closed'));

create or replace function public.pulse_retro_stages()
returns text[] language sql immutable set search_path = '' as $$
  select array['prepare', 'collect', 'group', 'vote', 'discuss', 'actions', 'closed'];
$$;

create or replace function public.pulse_retro_board(retro uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  target public.pulse_retros := public.pulse_retro_for(retro);
  collecting boolean := target.stage = 'collect';
  revealed boolean := target.stage in ('discuss', 'actions', 'closed');
begin
  return jsonb_build_object(
    'can_facilitate', public.pulse_can_facilitate(target),
    'topics', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'column', t.board_column, 'title', t.title, 'description', t.description,
        'group_id', t.group_id, 'created_at', t.created_at, 'mine', t.author_id = auth.uid(),
        'author', case when target.anonymous then null else (select u.email from auth.users u where u.id = t.author_id) end
      ) order by t.created_at, t.id)
      from public.pulse_retro_topics t
      where t.retro_id = retro and (not collecting or t.author_id = auth.uid())), '[]'::jsonb),
    'hidden_topics', case when collecting then (
      select count(*) from public.pulse_retro_topics t
      where t.retro_id = retro and t.author_id is distinct from auth.uid()) else 0 end,
    'groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', g.id, 'title', g.title, 'created_at', g.created_at,
        'summary', g.summary, 'impact', g.impact, 'root_causes', g.root_causes,
        'context', g.context, 'decision', g.decision,
        'votes', case when revealed then (select coalesce(sum(v.votes), 0) from public.pulse_retro_votes v where v.group_id = g.id) end,
        'my_votes', (select coalesce(sum(v.votes), 0) from public.pulse_retro_votes v where v.group_id = g.id and v.user_id = auth.uid())
      ) order by g.created_at, g.id)
      from public.pulse_retro_groups g where g.retro_id = retro), '[]'::jsonb),
    'voters', (select count(distinct v.user_id) from public.pulse_retro_votes v
      join public.pulse_retro_groups g on g.id = v.group_id where g.retro_id = retro)
  );
end;
$$;

-- Accounts that can own or collaborate on actions: the workspace owner and its Pulse shares.
create function public.pulse_workspace_people(workspace uuid)
returns table(user_id uuid, email text) language plpgsql stable security definer set search_path = '' as $$
begin
  if public.workspace_access(workspace, 'pulse') is null then raise exception 'Workspace not found'; end if;
  return query
    select u.id, u.email::text from public.workspaces w join auth.users u on u.id = w.owner_id
      where w.id = workspace
    union
    select c.user_id, c.email from public.workspace_collaborators c
      where c.workspace_id = workspace and c.app = 'pulse'
    order by 2, 1;
end;
$$;

create function public.pulse_is_person(workspace uuid, account uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.workspaces w where w.id = workspace and w.owner_id = account)
    or exists(select 1 from public.workspace_collaborators c
      where c.workspace_id = workspace and c.user_id = account and c.app = 'pulse');
$$;

-- The action with the caller's access checked; raises when it is missing or not shared in Pulse.
create function public.pulse_action_for(action uuid)
returns public.pulse_actions language plpgsql security definer set search_path = '' as $$
declare target public.pulse_actions;
begin
  select * into target from public.pulse_actions where id = action for update;
  if target.id is null or public.workspace_access(target.workspace_id, 'pulse') is null
    then raise exception 'Action not found'; end if;
  return target;
end;
$$;

-- Managers, plus the facilitator of the retro the action comes from.
create function public.pulse_can_manage_action(workspace uuid, retro uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.pulse_can_manage(workspace) or exists(
    select 1 from public.pulse_retros r
    where r.id = retro and r.workspace_id = workspace and r.facilitator_id = auth.uid());
$$;

create function public.pulse_can_update_action(target public.pulse_actions)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.pulse_can_manage_action(target.workspace_id, target.retro_id)
    or target.owner_id = auth.uid()
    or exists(select 1 from public.pulse_action_collaborators c
      where c.action_id = target.id and c.user_id = auth.uid());
$$;

-- Checks the fields shared by creating and editing, and replaces the collaborators.
create function public.pulse_set_action_people(target public.pulse_actions, action_owner uuid, collaborators uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare person uuid;
begin
  if action_owner is null or not public.pulse_is_person(target.workspace_id, action_owner)
    then raise exception 'Choose an owner with Pulse access to the workspace'; end if;
  delete from public.pulse_action_collaborators where action_id = target.id;
  foreach person in array coalesce(collaborators, '{}') loop
    if not public.pulse_is_person(target.workspace_id, person)
      then raise exception 'Collaborators need Pulse access to the workspace'; end if;
    if person <> action_owner then
      insert into public.pulse_action_collaborators(action_id, user_id) values (target.id, person)
        on conflict do nothing;
    end if;
  end loop;
end;
$$;

create function public.create_pulse_action(
  workspace uuid, retro uuid, grp uuid, action_title text, action_description text,
  action_owner uuid, collaborators uuid[], due date, action_priority text, criteria text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare created public.pulse_actions;
begin
  if not public.pulse_can_manage_action(workspace, retro) then raise exception 'Pulse edit access required'; end if;
  if retro is not null and not exists(select 1 from public.pulse_retros r where r.id = retro and r.workspace_id = workspace)
    then raise exception 'Retrospective not found'; end if;
  if grp is not null and (retro is null or public.pulse_group_retro(grp) is distinct from retro)
    then raise exception 'Topic group not found'; end if;
  insert into public.pulse_actions(workspace_id, retro_id, group_id, title, description, owner_id,
    due_on, priority, success_criteria)
    values (workspace, retro, grp, trim(action_title), public.pulse_trim(action_description), action_owner,
      due, coalesce(action_priority, 'medium'), public.pulse_trim(criteria))
    returning * into created;
  perform public.pulse_set_action_people(created, action_owner, collaborators);
  insert into public.pulse_action_updates(action_id, kind, status) values (created.id, 'created', 'open');
  return created.id;
end;
$$;

create function public.update_pulse_action(
  action uuid, action_title text, action_description text, action_owner uuid, collaborators uuid[],
  due date, action_priority text, criteria text
) returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_actions := public.pulse_action_for(action);
begin
  if not public.pulse_can_manage_action(target.workspace_id, target.retro_id)
    then raise exception 'Pulse edit access required'; end if;
  update public.pulse_actions set title = trim(action_title), description = public.pulse_trim(action_description),
    owner_id = action_owner, due_on = due, priority = coalesce(action_priority, 'medium'),
    success_criteria = public.pulse_trim(criteria)
    where id = action;
  perform public.pulse_set_action_people(target, action_owner, collaborators);
  insert into public.pulse_action_updates(action_id, kind) values (action, 'edited');
end;
$$;

-- Moves an action to another status with an optional note; finishing stamps the completion date.
create function public.set_pulse_action_status(action uuid, new_status text, status_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_actions := public.pulse_action_for(action);
begin
  if not public.pulse_can_update_action(target) then raise exception 'Only the owner, collaborators or managers can update this action'; end if;
  if new_status is null or new_status not in ('open', 'in_progress', 'done', 'cancelled')
    then raise exception 'Unknown status'; end if;
  if new_status = target.status then raise exception 'The action is already in that status'; end if;
  update public.pulse_actions set status = new_status,
    completed_at = case when new_status = 'done' then now() end
    where id = action;
  insert into public.pulse_action_updates(action_id, kind, status, note)
    values (action, 'status', new_status, public.pulse_trim(status_note));
end;
$$;

create function public.add_pulse_action_note(action uuid, action_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_actions := public.pulse_action_for(action);
begin
  if not public.pulse_can_update_action(target) then raise exception 'Only the owner, collaborators or managers can update this action'; end if;
  if public.pulse_trim(action_note) is null then raise exception 'Write a note first'; end if;
  insert into public.pulse_action_updates(action_id, kind, note) values (action, 'note', public.pulse_trim(action_note));
end;
$$;

create function public.record_pulse_action_outcome(action uuid, action_outcome text, did_help boolean, action_follow_up text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_actions := public.pulse_action_for(action);
begin
  if not public.pulse_can_update_action(target) then raise exception 'Only the owner, collaborators or managers can update this action'; end if;
  if target.status <> 'done' then raise exception 'Record the outcome once the action is done'; end if;
  update public.pulse_actions set outcome = public.pulse_trim(action_outcome), helped = did_help,
    follow_up = public.pulse_trim(action_follow_up)
    where id = action;
  insert into public.pulse_action_updates(action_id, kind) values (action, 'outcome');
end;
$$;

create function public.delete_pulse_action(action uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_actions := public.pulse_action_for(action);
begin
  if not public.pulse_can_manage_action(target.workspace_id, target.retro_id)
    then raise exception 'Pulse edit access required'; end if;
  delete from public.pulse_actions where id = action;
end;
$$;

-- Every action of the workspace, with the names the dashboard and the retros show.
create function public.list_pulse_actions(workspace uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if public.workspace_access(workspace, 'pulse') is null then raise exception 'Workspace not found'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', a.id, 'retro_id', a.retro_id, 'group_id', a.group_id, 'title', a.title,
      'description', a.description, 'owner_id', a.owner_id,
      'owner_email', (select u.email from auth.users u where u.id = a.owner_id),
      'collaborators', coalesce((
        select jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email) order by u.email)
        from public.pulse_action_collaborators c join auth.users u on u.id = c.user_id
        where c.action_id = a.id), '[]'::jsonb),
      'due_on', a.due_on, 'priority', a.priority, 'status', a.status,
      'success_criteria', a.success_criteria, 'outcome', a.outcome, 'helped', a.helped,
      'follow_up', a.follow_up, 'created_at', a.created_at, 'completed_at', a.completed_at,
      'retro_title', r.title, 'retro_held_on', r.held_on,
      'group_title', coalesce(g.title, (select t.title from public.pulse_retro_topics t
        where t.group_id = g.id order by t.created_at, t.id limit 1)),
      'can_manage', public.pulse_can_manage_action(a.workspace_id, a.retro_id),
      'can_update', public.pulse_can_update_action(a)
    ) order by a.created_at, a.id)
    from public.pulse_actions a
    left join public.pulse_retros r on r.id = a.retro_id
    left join public.pulse_retro_groups g on g.id = a.group_id
    where a.workspace_id = workspace), '[]'::jsonb);
end;
$$;

create function public.pulse_action_history(action uuid)
returns table(id uuid, kind text, status text, note text, author_email text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare target public.pulse_actions;
begin
  select * into target from public.pulse_actions a where a.id = action;
  if target.id is null or public.workspace_access(target.workspace_id, 'pulse') is null
    then raise exception 'Action not found'; end if;
  return query select h.id, h.kind, h.status, h.note, u.email::text, h.created_at
    from public.pulse_action_updates h left join auth.users u on u.id = h.author_id
    where h.action_id = action order by h.created_at, h.id;
end;
$$;

revoke all on function public.pulse_is_person(uuid, uuid), public.pulse_action_for(uuid),
  public.pulse_can_manage_action(uuid, uuid), public.pulse_can_update_action(public.pulse_actions),
  public.pulse_set_action_people(public.pulse_actions, uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.pulse_workspace_people(uuid),
  public.create_pulse_action(uuid, uuid, uuid, text, text, uuid, uuid[], date, text, text),
  public.update_pulse_action(uuid, text, text, uuid, uuid[], date, text, text),
  public.set_pulse_action_status(uuid, text, text), public.add_pulse_action_note(uuid, text),
  public.record_pulse_action_outcome(uuid, text, boolean, text), public.delete_pulse_action(uuid),
  public.list_pulse_actions(uuid), public.pulse_action_history(uuid) from public, anon;
grant execute on function public.pulse_workspace_people(uuid),
  public.create_pulse_action(uuid, uuid, uuid, text, text, uuid, uuid[], date, text, text),
  public.update_pulse_action(uuid, text, text, uuid, uuid[], date, text, text),
  public.set_pulse_action_status(uuid, text, text), public.add_pulse_action_note(uuid, text),
  public.record_pulse_action_outcome(uuid, text, boolean, text), public.delete_pulse_action(uuid),
  public.list_pulse_actions(uuid), public.pulse_action_history(uuid) to authenticated;

-- A workspace made for a team is released with its last team, unless Pulse keeps work in it.
create or replace function public.teams_release_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  delete from public.workspaces w
    where w.id = old.workspace_id and w.created_for_team
      and not exists (select 1 from public.teams t where t.workspace_id = w.id)
      and not exists (select 1 from public.projects p where p.workspace_id = w.id)
      and not exists (select 1 from public.pulse_surveys s where s.workspace_id = w.id)
      and not exists (select 1 from public.pulse_retros r where r.workspace_id = w.id)
      and not exists (select 1 from public.pulse_actions a where a.workspace_id = w.id);
  return null;
end;
$$;
