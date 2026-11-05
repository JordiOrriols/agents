-- Pulse: guided retrospectives of a workspace. Owners and editors create them; the facilitator
-- (the creator) or any owner or editor moves them through the stages, and everyone with Pulse
-- access takes part. Topics, groups and votes are only readable through pulse_retro_board, which
-- hides authors of anonymous retros, other people's topics while collecting and vote totals
-- until voting closes. The actions stage comes with the action tracking step.

create table public.pulse_retros (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  held_on date not null default current_date,
  period text check (char_length(period) between 1 and 80),
  goal text check (char_length(goal) between 1 and 500),
  template text not null check (template in ('well_improve', 'start_stop_continue', 'mad_sad_glad', 'open')),
  anonymous boolean not null default true,
  votes_per_person smallint not null default 3 check (votes_per_person between 1 and 10),
  stage text not null default 'prepare'
    check (stage in ('prepare', 'collect', 'group', 'vote', 'discuss', 'closed')),
  facilitator_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index on public.pulse_retros(workspace_id, held_on);

create table public.pulse_retro_groups (
  id uuid primary key default gen_random_uuid(),
  retro_id uuid not null references public.pulse_retros(id) on delete cascade,
  title text check (char_length(title) between 1 and 120),
  summary text check (char_length(summary) <= 2000),
  impact text check (char_length(impact) <= 2000),
  root_causes text check (char_length(root_causes) <= 2000),
  context text check (char_length(context) <= 2000),
  decision text check (decision in ('action', 'monitor', 'accept')),
  created_at timestamptz not null default now()
);
create index on public.pulse_retro_groups(retro_id);

create table public.pulse_retro_topics (
  id uuid primary key default gen_random_uuid(),
  retro_id uuid not null references public.pulse_retros(id) on delete cascade,
  author_id uuid references auth.users(id) on delete set null default auth.uid(),
  board_column text not null,
  title text not null check (char_length(title) between 1 and 200),
  description text check (char_length(description) between 1 and 1000),
  group_id uuid references public.pulse_retro_groups(id) on delete set null,
  created_at timestamptz not null default now()
);
create index on public.pulse_retro_topics(retro_id);
create index on public.pulse_retro_topics(group_id);

create table public.pulse_retro_votes (
  group_id uuid not null references public.pulse_retro_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  votes smallint not null check (votes > 0),
  primary key (group_id, user_id)
);

alter table public.pulse_retros enable row level security;
alter table public.pulse_retro_groups enable row level security;
alter table public.pulse_retro_topics enable row level security;
alter table public.pulse_retro_votes enable row level security;
revoke all on public.pulse_retros, public.pulse_retro_groups, public.pulse_retro_topics,
  public.pulse_retro_votes from anon, authenticated;
grant select on public.pulse_retros to authenticated;
create policy pulse_retros_read on public.pulse_retros for select to authenticated
  using (public.workspace_access(workspace_id, 'pulse') is not null);

-- Board columns of each template; adding a template only needs a new branch here and its copy.
create function public.pulse_retro_columns(template text)
returns text[] language sql immutable set search_path = '' as $$
  select case template
    when 'well_improve' then array['went_well', 'to_improve', 'ideas']
    when 'start_stop_continue' then array['start', 'stop', 'continue']
    when 'mad_sad_glad' then array['mad', 'sad', 'glad']
    when 'open' then array['topics']
  end;
$$;

create function public.pulse_retro_stages()
returns text[] language sql immutable set search_path = '' as $$
  select array['prepare', 'collect', 'group', 'vote', 'discuss', 'closed'];
$$;

-- The retro with the caller's access checked; raises when it is missing or not shared in Pulse.
create function public.pulse_retro_for(retro uuid, lock boolean default false)
returns public.pulse_retros language plpgsql security definer set search_path = '' as $$
declare target public.pulse_retros;
begin
  if lock then select * into target from public.pulse_retros where id = retro for update;
  else select * into target from public.pulse_retros where id = retro; end if;
  if target.id is null or public.workspace_access(target.workspace_id, 'pulse') is null
    then raise exception 'Retrospective not found'; end if;
  return target;
end;
$$;

create function public.pulse_can_facilitate(target public.pulse_retros)
returns boolean language sql stable security definer set search_path = '' as $$
  select target.facilitator_id = auth.uid() or public.pulse_can_manage(target.workspace_id);
$$;

create function public.pulse_require_stage(target public.pulse_retros, expected text)
returns void language plpgsql set search_path = '' as $$
begin
  if target.stage <> expected then raise exception 'This retrospective is not in the % stage', expected; end if;
end;
$$;

create function public.pulse_group_retro(grp uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select retro_id from public.pulse_retro_groups where id = grp;
$$;

create function public.pulse_trim(value text)
returns text language sql immutable set search_path = '' as $$
  select nullif(trim(value), '');
$$;

create function public.create_pulse_retro(
  workspace uuid, retro_title text, held date, retro_period text, retro_goal text,
  retro_template text, is_anonymous boolean, votes integer
) returns uuid language plpgsql security definer set search_path = '' as $$
declare retro uuid;
begin
  if not public.pulse_can_manage(workspace) then raise exception 'Pulse edit access required'; end if;
  if public.pulse_retro_columns(retro_template) is null then raise exception 'Unknown template'; end if;
  insert into public.pulse_retros(workspace_id, title, held_on, period, goal, template, anonymous, votes_per_person)
    values (workspace, trim(retro_title), coalesce(held, current_date), public.pulse_trim(retro_period),
      public.pulse_trim(retro_goal), retro_template, coalesce(is_anonymous, true), coalesce(votes, 3))
    returning id into retro;
  return retro;
end;
$$;

create function public.delete_pulse_retro(retro uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_retros := public.pulse_retro_for(retro);
begin
  if not public.pulse_can_manage(target.workspace_id) then raise exception 'Pulse edit access required'; end if;
  delete from public.pulse_retros where id = retro;
end;
$$;

-- Moves one stage forward or back. Starting the vote turns every loose topic into a group of
-- its own, so votes and the discussion always point at a group.
create function public.set_pulse_retro_stage(retro uuid, new_stage text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  target public.pulse_retros := public.pulse_retro_for(retro, true);
  stages text[] := public.pulse_retro_stages();
  loose record;
  grp uuid;
begin
  if not public.pulse_can_facilitate(target) then raise exception 'Only the facilitator can change the stage'; end if;
  if new_stage is null or abs(coalesce(array_position(stages, new_stage), 0) - array_position(stages, target.stage)) <> 1
    or array_position(stages, new_stage) is null
    then raise exception 'Move one stage at a time'; end if;
  if new_stage = 'vote' then
    for loose in select id from public.pulse_retro_topics where retro_id = retro and group_id is null loop
      insert into public.pulse_retro_groups(retro_id) values (retro) returning id into grp;
      update public.pulse_retro_topics set group_id = grp where id = loose.id;
    end loop;
  end if;
  update public.pulse_retros set stage = new_stage,
    closed_at = case when new_stage = 'closed' then now() end
    where id = retro;
end;
$$;

create function public.add_pulse_topic(retro uuid, topic_column text, topic_title text, topic_description text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare target public.pulse_retros := public.pulse_retro_for(retro); topic uuid;
begin
  perform public.pulse_require_stage(target, 'collect');
  if not topic_column = any(public.pulse_retro_columns(target.template)) then raise exception 'Unknown column'; end if;
  insert into public.pulse_retro_topics(retro_id, board_column, title, description)
    values (retro, topic_column, trim(topic_title), public.pulse_trim(topic_description))
    returning id into topic;
  return topic;
end;
$$;

create function public.update_pulse_topic(topic uuid, topic_column text, topic_title text, topic_description text)
returns void language plpgsql security definer set search_path = '' as $$
declare item public.pulse_retro_topics; target public.pulse_retros;
begin
  select * into item from public.pulse_retro_topics where id = topic;
  target := public.pulse_retro_for(item.retro_id);
  perform public.pulse_require_stage(target, 'collect');
  if item.author_id is distinct from auth.uid() then raise exception 'Only the author can edit a topic'; end if;
  if not topic_column = any(public.pulse_retro_columns(target.template)) then raise exception 'Unknown column'; end if;
  update public.pulse_retro_topics
    set board_column = topic_column, title = trim(topic_title), description = public.pulse_trim(topic_description)
    where id = topic;
end;
$$;

create function public.delete_pulse_topic(topic uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare item public.pulse_retro_topics; target public.pulse_retros;
begin
  select * into item from public.pulse_retro_topics where id = topic;
  target := public.pulse_retro_for(item.retro_id);
  perform public.pulse_require_stage(target, 'collect');
  if item.author_id is distinct from auth.uid() then raise exception 'Only the author can delete a topic'; end if;
  delete from public.pulse_retro_topics where id = topic;
end;
$$;

-- Grouping: anyone taking part can create, rename, merge and undo groups while grouping.
create function public.pulse_drop_empty_groups(retro uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.pulse_retro_groups g where g.retro_id = retro
    and not exists (select 1 from public.pulse_retro_topics t where t.group_id = g.id);
$$;

create function public.create_pulse_group(retro uuid, topics uuid[], group_title text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare target public.pulse_retros := public.pulse_retro_for(retro, true); grp uuid;
begin
  perform public.pulse_require_stage(target, 'group');
  if coalesce(array_length(topics, 1), 0) = 0
    or exists (select 1 from unnest(topics) t(id)
      where not exists (select 1 from public.pulse_retro_topics p where p.id = t.id and p.retro_id = retro))
    then raise exception 'Pick topics of this retrospective'; end if;
  insert into public.pulse_retro_groups(retro_id, title) values (retro, public.pulse_trim(group_title))
    returning id into grp;
  update public.pulse_retro_topics set group_id = grp where id = any(topics);
  perform public.pulse_drop_empty_groups(retro);
  return grp;
end;
$$;

create function public.rename_pulse_group(grp uuid, group_title text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_retros := public.pulse_retro_for(public.pulse_group_retro(grp));
begin
  if target.stage not in ('group', 'vote', 'discuss') then raise exception 'Groups can no longer be renamed'; end if;
  if target.stage <> 'group' and not public.pulse_can_facilitate(target)
    then raise exception 'Only the facilitator can rename groups now'; end if;
  update public.pulse_retro_groups set title = public.pulse_trim(group_title) where id = grp;
end;
$$;

-- Puts a topic in a group, or takes it out of its group when grp is null.
create function public.move_pulse_topic(topic uuid, grp uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare retro uuid := (select retro_id from public.pulse_retro_topics where id = topic);
declare target public.pulse_retros := public.pulse_retro_for(retro, true);
begin
  perform public.pulse_require_stage(target, 'group');
  if grp is not null and public.pulse_group_retro(grp) is distinct from retro then raise exception 'Group not found'; end if;
  update public.pulse_retro_topics set group_id = grp where id = topic;
  perform public.pulse_drop_empty_groups(retro);
end;
$$;

create function public.merge_pulse_groups(source uuid, destination uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare retro uuid := public.pulse_group_retro(source);
declare target public.pulse_retros := public.pulse_retro_for(retro, true);
begin
  perform public.pulse_require_stage(target, 'group');
  if source = destination or public.pulse_group_retro(destination) is distinct from retro
    then raise exception 'Group not found'; end if;
  update public.pulse_retro_topics set group_id = destination where group_id = source;
  insert into public.pulse_retro_votes(group_id, user_id, votes)
    select destination, user_id, votes from public.pulse_retro_votes where group_id = source
    on conflict (group_id, user_id) do update set votes = public.pulse_retro_votes.votes + excluded.votes;
  delete from public.pulse_retro_groups where id = source;
end;
$$;

create function public.ungroup_pulse_group(grp uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare retro uuid := public.pulse_group_retro(grp);
declare target public.pulse_retros := public.pulse_retro_for(retro, true);
begin
  perform public.pulse_require_stage(target, 'group');
  update public.pulse_retro_topics set group_id = null where group_id = grp;
  delete from public.pulse_retro_groups where id = grp;
end;
$$;

-- Sets how many of the caller's votes go to a group; several may go to the same group.
create function public.set_pulse_vote(grp uuid, votes integer)
returns void language plpgsql security definer set search_path = '' as $$
declare retro uuid := public.pulse_group_retro(grp);
declare target public.pulse_retros := public.pulse_retro_for(retro, true);
declare used integer;
begin
  perform public.pulse_require_stage(target, 'vote');
  if votes is null or votes < 0 then raise exception 'Votes cannot be negative'; end if;
  select coalesce(sum(v.votes), 0) into used from public.pulse_retro_votes v
    join public.pulse_retro_groups g on g.id = v.group_id
    where g.retro_id = retro and v.user_id = auth.uid() and v.group_id <> grp;
  if used + votes > target.votes_per_person
    then raise exception 'You only have % votes', target.votes_per_person; end if;
  if votes = 0 then
    delete from public.pulse_retro_votes v where v.group_id = grp and v.user_id = auth.uid();
  else
    insert into public.pulse_retro_votes(group_id, user_id, votes) values (grp, auth.uid(), votes)
      on conflict (group_id, user_id) do update set votes = excluded.votes;
  end if;
end;
$$;

create function public.update_pulse_discussion(
  grp uuid, group_summary text, group_impact text, group_root_causes text, group_context text, group_decision text
) returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_retros := public.pulse_retro_for(public.pulse_group_retro(grp));
begin
  perform public.pulse_require_stage(target, 'discuss');
  if not public.pulse_can_facilitate(target) then raise exception 'Only the facilitator can take notes'; end if;
  update public.pulse_retro_groups set summary = public.pulse_trim(group_summary),
    impact = public.pulse_trim(group_impact), root_causes = public.pulse_trim(group_root_causes),
    context = public.pulse_trim(group_context), decision = group_decision
    where id = grp;
end;
$$;

-- Everything a participant may see of one retro, shaped for the board.
create function public.pulse_retro_board(retro uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  target public.pulse_retros := public.pulse_retro_for(retro);
  collecting boolean := target.stage = 'collect';
  revealed boolean := target.stage in ('discuss', 'closed');
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

revoke all on function public.pulse_retro_columns(text), public.pulse_retro_stages(),
  public.pulse_retro_for(uuid, boolean), public.pulse_can_facilitate(public.pulse_retros),
  public.pulse_require_stage(public.pulse_retros, text), public.pulse_group_retro(uuid),
  public.pulse_trim(text), public.pulse_drop_empty_groups(uuid) from public, anon, authenticated;
revoke all on function
  public.create_pulse_retro(uuid, text, date, text, text, text, boolean, integer),
  public.delete_pulse_retro(uuid), public.set_pulse_retro_stage(uuid, text),
  public.add_pulse_topic(uuid, text, text, text), public.update_pulse_topic(uuid, text, text, text),
  public.delete_pulse_topic(uuid), public.create_pulse_group(uuid, uuid[], text),
  public.rename_pulse_group(uuid, text), public.move_pulse_topic(uuid, uuid),
  public.merge_pulse_groups(uuid, uuid), public.ungroup_pulse_group(uuid),
  public.set_pulse_vote(uuid, integer),
  public.update_pulse_discussion(uuid, text, text, text, text, text),
  public.pulse_retro_board(uuid) from public, anon;
grant execute on function
  public.create_pulse_retro(uuid, text, date, text, text, text, boolean, integer),
  public.delete_pulse_retro(uuid), public.set_pulse_retro_stage(uuid, text),
  public.add_pulse_topic(uuid, text, text, text), public.update_pulse_topic(uuid, text, text, text),
  public.delete_pulse_topic(uuid), public.create_pulse_group(uuid, uuid[], text),
  public.rename_pulse_group(uuid, text), public.move_pulse_topic(uuid, uuid),
  public.merge_pulse_groups(uuid, uuid), public.ungroup_pulse_group(uuid),
  public.set_pulse_vote(uuid, integer),
  public.update_pulse_discussion(uuid, text, text, text, text, text),
  public.pulse_retro_board(uuid) to authenticated;

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
      and not exists (select 1 from public.pulse_retros r where r.workspace_id = w.id);
  return null;
end;
$$;
