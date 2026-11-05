-- Agents: a workspace task list that a local runner (OpenCode + Ollama) works through,
-- one task at a time. The web app and the runner both sign in as workspace accounts, so
-- the same owner/editor/viewer sharing as every other app decides who can do what.

alter table public.workspace_collaborators drop constraint workspace_collaborators_app_check;
alter table public.workspace_collaborators add constraint workspace_collaborators_app_check
  check (app in ('ladders', 'planner', 'pulse', 'shiplog', 'agents'));

create or replace function public.list_workspaces(app_name text)
returns table(id uuid, name text, owner_id uuid, access_level text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if app_name is null or app_name not in ('ladders', 'planner', 'pulse', 'shiplog', 'agents') then
    raise exception 'Invalid app';
  end if;
  return query select w.id, w.name, w.owner_id, public.workspace_access(w.id, app_name)
    from public.workspaces w where public.workspace_access(w.id, app_name) is not null
    order by lower(w.name), w.id;
end;
$$;

create or replace function public.share_workspace(workspace uuid, account_email text, app_name text, access text)
returns void language plpgsql security definer set search_path = '' as $$
declare account uuid; normalized_email text := lower(trim(account_email));
begin
  if not public.workspace_is_owner(workspace) then raise exception 'Workspace owner access required'; end if;
  if app_name is null or app_name not in ('ladders', 'planner', 'pulse', 'shiplog', 'agents') then
    raise exception 'Invalid app';
  end if;
  if access is null or access not in ('viewer', 'editor') then raise exception 'Invalid access level'; end if;
  select u.id into account from auth.users u where lower(u.email) = normalized_email;
  if account is null or account = auth.uid() then raise exception 'User not found or cannot share workspace'; end if;
  insert into public.workspace_collaborators(workspace_id, user_id, email, app, access_level)
    values (workspace, account, normalized_email, app_name, access)
    on conflict (workspace_id, user_id, app)
    do update set email = excluded.email, access_level = excluded.access_level;
end;
$$;

create or replace function public.list_workspace_app_shares(workspace uuid, app_name text)
returns table(user_id uuid, email text, app text, access_level text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if app_name is null or app_name not in ('planner', 'shiplog', 'agents') then
    raise exception 'Invalid app' using errcode = '22023';
  end if;
  if not public.workspace_is_owner(workspace) and not exists (
    select 1 from public.workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid() and c.app = app_name
      and c.access_level in ('viewer', 'editor')
  ) then
    raise exception 'Workspace sharing access required' using errcode = '42501';
  end if;
  return query select c.user_id, c.email, c.app, c.access_level
    from public.workspace_collaborators c
    where c.workspace_id = workspace and c.app = app_name
    order by c.email, c.user_id;
end;
$$;

create function public.agents_can_edit(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.workspace_access(workspace, 'agents') in ('owner', 'editor'), false);
$$;

create table public.agent_tasks (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 200),
  instructions text not null check (length(btrim(instructions)) between 1 and 20000),
  status text not null default 'pending'
    check (status in ('pending', 'running', 'completed', 'failed')),
  plan text not null default '' check (length(plan) <= 100000),
  outcome text not null default '' check (length(outcome) <= 200000),
  error text not null default '' check (length(error) <= 20000),
  -- Totals across every run of the task, reruns and chat replies included.
  seconds_spent integer not null default 0 check (seconds_spent >= 0),
  tokens_generated bigint not null default 0 check (tokens_generated >= 0),
  tokens_total bigint not null default 0 check (tokens_total >= 0),
  largest_context integer not null default 0 check (largest_context >= 0),
  attempts integer not null default 0 check (attempts >= 0),
  model text not null default '' check (length(model) <= 200),
  -- The OpenCode session, so chat messages continue the same conversation.
  session_id text check (length(session_id) <= 200),
  runner text check (length(runner) <= 120),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  -- Queue order: reruns and chat messages send a task to the back of the queue.
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);
create index on public.agent_tasks(workspace_id, status, queued_at);

create table public.agent_task_messages (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.agent_tasks(id) on delete cascade,
  role text not null check (role in ('user', 'agent')),
  body text not null check (length(btrim(body)) between 1 and 200000),
  author_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default clock_timestamp()
);
create index on public.agent_task_messages(task_id, created_at);

-- Runners are the local scripts of an account, seen through the workspaces they can edit.
create table public.agent_runners (
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  poll_seconds integer not null check (poll_seconds between 10 and 86400),
  last_seen timestamptz not null default now(),
  primary key (user_id, name)
);

alter table public.agent_tasks enable row level security;
alter table public.agent_task_messages enable row level security;
alter table public.agent_runners enable row level security;
revoke all on public.agent_tasks, public.agent_task_messages, public.agent_runners from anon, authenticated;
grant select on public.agent_tasks, public.agent_task_messages to authenticated;

create policy agent_tasks_read on public.agent_tasks for select to authenticated
  using (public.workspace_access(workspace_id, 'agents') is not null);
create policy agent_task_messages_read on public.agent_task_messages for select to authenticated
  using (exists (
    select 1 from public.agent_tasks t
    where t.id = task_id and public.workspace_access(t.workspace_id, 'agents') is not null
  ));

-- Locks an editable task, or explains why it cannot be changed.
create function public.agents_lock_task(task uuid) returns public.agent_tasks
language plpgsql security definer set search_path = '' as $$
declare found_task public.agent_tasks;
begin
  select * into found_task from public.agent_tasks t where t.id = task for update;
  if found_task.id is null or public.workspace_access(found_task.workspace_id, 'agents') is null then
    raise exception 'Task not found' using errcode = 'P0002';
  end if;
  if not public.agents_can_edit(found_task.workspace_id) then
    raise exception 'Agents editor access required' using errcode = '42501';
  end if;
  return found_task;
end;
$$;

create function public.agents_create_task(workspace uuid, task_title text, task_instructions text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare created uuid;
begin
  if not public.agents_can_edit(workspace) then
    raise exception 'Agents editor access required' using errcode = '42501';
  end if;
  insert into public.agent_tasks(workspace_id, title, instructions)
    values (workspace, btrim(task_title), btrim(task_instructions))
    returning id into created;
  return created;
end;
$$;

-- A finished task goes back to the queue from scratch, in a new OpenCode session.
create function public.agents_rerun_task(task uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare found_task public.agent_tasks := public.agents_lock_task(task);
begin
  if found_task.status not in ('completed', 'failed') then
    raise exception 'Only finished tasks can run again' using errcode = '55000';
  end if;
  update public.agent_tasks set status = 'pending', plan = '', outcome = '', error = '',
      session_id = null, queued_at = now(), started_at = null, finished_at = null
    where id = task;
end;
$$;

create function public.agents_delete_task(task uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare found_task public.agent_tasks := public.agents_lock_task(task);
begin
  if found_task.status = 'running' then
    raise exception 'A running task cannot be deleted' using errcode = '55000';
  end if;
  delete from public.agent_tasks where id = task;
end;
$$;

-- A chat message queues the task again so the runner answers it in the same session.
create function public.agents_send_message(task uuid, message text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare found_task public.agent_tasks := public.agents_lock_task(task); created uuid;
begin
  if found_task.status = 'running' then
    raise exception 'Wait until the agent finishes this task' using errcode = '55000';
  end if;
  if message is null or length(btrim(message)) not between 1 and 20000 then
    raise exception 'Invalid message' using errcode = '22023';
  end if;
  insert into public.agent_task_messages(task_id, role, body, author_id)
    values (task, 'user', btrim(message), auth.uid()) returning id into created;
  if found_task.status <> 'pending' then
    update public.agent_tasks set status = 'pending', error = '', queued_at = now(), finished_at = null
      where id = task;
  end if;
  return created;
end;
$$;

-- The runner takes the oldest pending task of the workspaces its account can edit. Tasks it
-- left running belong to a run that died, so they fail first instead of staying stuck.
create function public.agents_claim_task(runner_name text, poll_seconds integer default 300,
  only_workspace uuid default null)
returns setof public.agent_tasks language plpgsql security definer set search_path = '' as $$
declare next_task uuid;
begin
  if auth.uid() is null then raise exception 'Sign in required' using errcode = '42501'; end if;
  if runner_name is null or length(btrim(runner_name)) not between 1 and 120 then
    raise exception 'Invalid runner name' using errcode = '22023';
  end if;
  insert into public.agent_runners(user_id, name, poll_seconds, last_seen)
    values (auth.uid(), btrim(runner_name), poll_seconds, now())
    on conflict (user_id, name)
    do update set poll_seconds = excluded.poll_seconds, last_seen = excluded.last_seen;
  update public.agent_tasks t set status = 'failed', runner = null, finished_at = now(),
      error = 'The runner stopped before finishing this task.'
    where t.status = 'running' and t.runner = btrim(runner_name)
      and public.agents_can_edit(t.workspace_id);
  select t.id into next_task from public.agent_tasks t
    where t.status = 'pending' and public.agents_can_edit(t.workspace_id)
      and (only_workspace is null or t.workspace_id = only_workspace)
    order by t.queued_at, t.created_at, t.id
    limit 1 for update skip locked;
  if next_task is null then return; end if;
  return query update public.agent_tasks t set status = 'running', runner = btrim(runner_name),
      attempts = t.attempts + 1, error = '', started_at = now(), finished_at = null
    where t.id = next_task returning t.*;
end;
$$;

-- Records a run. Plan and outcome are only replaced when given; a chat reply becomes a message.
create function public.agents_finish_task(task uuid, runner_name text, succeeded boolean,
  run_seconds integer, run_tokens_generated bigint, run_tokens_total bigint, run_context integer,
  run_model text, run_session text default null, run_plan text default null,
  run_outcome text default null, reply text default null, failure text default '')
returns void language plpgsql security definer set search_path = '' as $$
declare found_task public.agent_tasks := public.agents_lock_task(task);
begin
  if found_task.status <> 'running' or found_task.runner is distinct from btrim(runner_name) then
    raise exception 'Task is not running on this runner' using errcode = '55000';
  end if;
  update public.agent_tasks t set
      status = case when succeeded then 'completed' else 'failed' end,
      runner = null,
      finished_at = now(),
      seconds_spent = t.seconds_spent + greatest(coalesce(run_seconds, 0), 0),
      tokens_generated = t.tokens_generated + greatest(coalesce(run_tokens_generated, 0), 0),
      tokens_total = t.tokens_total + greatest(coalesce(run_tokens_total, 0), 0),
      largest_context = greatest(t.largest_context, coalesce(run_context, 0)),
      model = coalesce(left(run_model, 200), t.model),
      session_id = coalesce(run_session, t.session_id),
      plan = coalesce(left(run_plan, 100000), t.plan),
      outcome = coalesce(left(run_outcome, 200000), t.outcome),
      error = case when succeeded then '' else left(coalesce(nullif(failure, ''), 'The agent failed.'), 20000) end
    where t.id = task;
  if reply is not null and length(btrim(reply)) > 0 then
    insert into public.agent_task_messages(task_id, role, body)
      values (task, 'agent', left(reply, 200000));
  end if;
end;
$$;

-- Runners of the accounts that can edit the workspace, most recently seen first.
create function public.agents_runner_status(workspace uuid)
returns table(name text, poll_seconds integer, last_seen timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.workspace_access(workspace, 'agents') is null then
    raise exception 'Workspace access required' using errcode = '42501';
  end if;
  return query select r.name, r.poll_seconds, r.last_seen
    from public.agent_runners r
    join public.workspaces w on w.id = workspace
    where r.user_id = w.owner_id or exists (
      select 1 from public.workspace_collaborators c
      where c.workspace_id = workspace and c.user_id = r.user_id
        and c.app = 'agents' and c.access_level = 'editor'
    )
    order by r.last_seen desc, r.name;
end;
$$;

revoke all on function public.agents_can_edit(uuid), public.agents_lock_task(uuid),
  public.agents_create_task(uuid, text, text), public.agents_rerun_task(uuid),
  public.agents_delete_task(uuid), public.agents_send_message(uuid, text),
  public.agents_claim_task(text, integer, uuid),
  public.agents_finish_task(uuid, text, boolean, integer, bigint, bigint, integer, text, text, text, text, text, text),
  public.agents_runner_status(uuid) from public, anon;
grant execute on function public.agents_can_edit(uuid),
  public.agents_create_task(uuid, text, text), public.agents_rerun_task(uuid),
  public.agents_delete_task(uuid), public.agents_send_message(uuid, text),
  public.agents_claim_task(text, integer, uuid),
  public.agents_finish_task(uuid, text, boolean, integer, bigint, bigint, integer, text, text, text, text, text, text),
  public.agents_runner_status(uuid) to authenticated;
