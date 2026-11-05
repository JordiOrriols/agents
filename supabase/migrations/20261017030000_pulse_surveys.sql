-- Pulse: Team Pulse surveys of a workspace. Everyone with Pulse access answers; owners and
-- editors run the surveys. Answers are anonymous: a response keeps no account and no time, and
-- the only trace of who answered is a separate participation marker per survey.

create table public.pulse_surveys (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  asks_comment boolean not null default true,
  min_responses smallint not null default 3 check (min_responses between 1 and 50),
  status text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index on public.pulse_surveys(workspace_id, created_at);

-- A default question has a key and is worded by the app in the reader's language; a custom one
-- carries its own prompt and optional scale labels.
create table public.pulse_questions (
  id uuid primary key default gen_random_uuid(),
  survey_id uuid not null references public.pulse_surveys(id) on delete cascade,
  position smallint not null,
  key text check (key in ('health', 'delivery', 'autonomy', 'clarity', 'workload', 'collaboration')),
  prompt text check (char_length(prompt) between 1 and 200),
  low_label text check (char_length(low_label) between 1 and 40),
  high_label text check (char_length(high_label) between 1 and 40),
  check ((key is null) <> (prompt is null)),
  unique (survey_id, position)
);

create table public.pulse_participations (
  survey_id uuid not null references public.pulse_surveys(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (survey_id, user_id)
);

create table public.pulse_responses (
  id uuid primary key default gen_random_uuid(),
  survey_id uuid not null references public.pulse_surveys(id) on delete cascade
);
create index on public.pulse_responses(survey_id);

create table public.pulse_answers (
  response_id uuid not null references public.pulse_responses(id) on delete cascade,
  question_id uuid not null references public.pulse_questions(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  primary key (response_id, question_id)
);

-- Free text is kept apart from the ratings so a comment cannot be matched to a response.
create table public.pulse_comments (
  id uuid primary key default gen_random_uuid(),
  survey_id uuid not null references public.pulse_surveys(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000)
);
create index on public.pulse_comments(survey_id);

alter table public.pulse_surveys enable row level security;
alter table public.pulse_questions enable row level security;
alter table public.pulse_participations enable row level security;
alter table public.pulse_responses enable row level security;
alter table public.pulse_answers enable row level security;
alter table public.pulse_comments enable row level security;
revoke all on public.pulse_surveys, public.pulse_questions, public.pulse_participations,
  public.pulse_responses, public.pulse_answers, public.pulse_comments from anon, authenticated;
grant select on public.pulse_surveys, public.pulse_questions, public.pulse_participations to authenticated;

create function public.pulse_can_manage(workspace uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(public.workspace_access(workspace, 'pulse') in ('owner', 'editor'), false);
$$;

create function public.pulse_survey_workspace(survey uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select workspace_id from public.pulse_surveys where id = survey;
$$;

create policy pulse_surveys_read on public.pulse_surveys for select to authenticated
  using (public.workspace_access(workspace_id, 'pulse') is not null);
create policy pulse_questions_read on public.pulse_questions for select to authenticated
  using (public.workspace_access(public.pulse_survey_workspace(survey_id), 'pulse') is not null);
create policy pulse_participations_read_own on public.pulse_participations for select to authenticated
  using (user_id = auth.uid());

create function public.create_pulse_survey(
  workspace uuid, survey_title text, questions jsonb, with_comment boolean, minimum integer
) returns uuid language plpgsql security definer set search_path = '' as $$
declare survey uuid; item jsonb; ordinal integer := 0;
begin
  if not public.pulse_can_manage(workspace) then raise exception 'Pulse edit access required'; end if;
  if survey_title is null or length(trim(survey_title)) not between 1 and 120
    then raise exception 'Survey titles need between 1 and 120 characters'; end if;
  if jsonb_typeof(questions) <> 'array' or jsonb_array_length(questions) not between 1 and 12
    then raise exception 'Surveys need between 1 and 12 questions'; end if;
  insert into public.pulse_surveys(workspace_id, title, asks_comment, min_responses)
    values (workspace, trim(survey_title), coalesce(with_comment, true), coalesce(minimum, 3))
    returning id into survey;
  for item in select value from jsonb_array_elements(questions) loop
    ordinal := ordinal + 1;
    insert into public.pulse_questions(survey_id, position, key, prompt, low_label, high_label)
      values (survey, ordinal, item->>'key', nullif(trim(item->>'prompt'), ''),
        nullif(trim(item->>'low_label'), ''), nullif(trim(item->>'high_label'), ''));
  end loop;
  return survey;
end;
$$;

create function public.submit_pulse_response(survey uuid, ratings jsonb, comment text)
returns void language plpgsql security definer set search_path = '' as $$
declare target public.pulse_surveys; response uuid;
begin
  select * into target from public.pulse_surveys where id = survey for update;
  if target.id is null or public.workspace_access(target.workspace_id, 'pulse') is null
    then raise exception 'Survey not found'; end if;
  if target.status <> 'open' then raise exception 'This survey is closed'; end if;
  if jsonb_typeof(ratings) <> 'object'
    or exists (select 1 from jsonb_each(ratings) r
      where not exists (select 1 from public.pulse_questions q where q.survey_id = survey and q.id::text = r.key)
        or jsonb_typeof(r.value) <> 'number' or (r.value)::text not in ('1', '2', '3', '4', '5'))
    or exists (select 1 from public.pulse_questions q where q.survey_id = survey and not ratings ? q.id::text)
    then raise exception 'Rate every question from 1 to 5'; end if;
  insert into public.pulse_participations(survey_id, user_id) values (survey, auth.uid())
    on conflict do nothing;
  if not found then raise exception 'You already answered this survey'; end if;
  insert into public.pulse_responses(survey_id) values (survey) returning id into response;
  insert into public.pulse_answers(response_id, question_id, rating)
    select response, r.key::uuid, (r.value)::text::smallint from jsonb_each(ratings) r;
  if target.asks_comment and length(trim(coalesce(comment, ''))) > 0 then
    insert into public.pulse_comments(survey_id, body) values (survey, left(trim(comment), 2000));
  end if;
end;
$$;

create function public.set_pulse_survey_status(survey uuid, new_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.pulse_can_manage(public.pulse_survey_workspace(survey))
    then raise exception 'Pulse edit access required'; end if;
  if new_status is null or new_status not in ('open', 'closed') then raise exception 'Invalid status'; end if;
  update public.pulse_surveys set status = new_status,
    closed_at = case when new_status = 'closed' then now() end
    where id = survey;
end;
$$;

create function public.delete_pulse_survey(survey uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.pulse_can_manage(public.pulse_survey_workspace(survey))
    then raise exception 'Pulse edit access required'; end if;
  delete from public.pulse_surveys where id = survey;
end;
$$;

-- Aggregates for every survey of the workspace. Ratings and comments are only returned once a
-- survey is closed and reached its minimum number of responses; until then only the counts.
create function public.pulse_survey_results(workspace uuid)
returns table(survey_id uuid, responses integer, participants integer, visible boolean,
  distribution jsonb, comments jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare members integer;
begin
  if public.workspace_access(workspace, 'pulse') is null then raise exception 'Pulse access required'; end if;
  select 1 + count(distinct c.user_id) into members from public.workspace_collaborators c
    where c.workspace_id = workspace and c.app = 'pulse';
  return query
    select s.id, counted.total, members, shown.ok,
      case when shown.ok then coalesce((
        select jsonb_object_agg(q.id::text, (
          select jsonb_build_array(
            count(*) filter (where a.rating = 1), count(*) filter (where a.rating = 2),
            count(*) filter (where a.rating = 3), count(*) filter (where a.rating = 4),
            count(*) filter (where a.rating = 5))
          from public.pulse_answers a where a.question_id = q.id))
        from public.pulse_questions q where q.survey_id = s.id), '{}'::jsonb)
      else '{}'::jsonb end,
      case when shown.ok then coalesce((
        select jsonb_agg(c.body order by c.body) from public.pulse_comments c where c.survey_id = s.id),
        '[]'::jsonb)
      else '[]'::jsonb end
    from public.pulse_surveys s
    cross join lateral (select count(*)::integer as total from public.pulse_responses r where r.survey_id = s.id) counted
    cross join lateral (select s.status = 'closed' and counted.total >= s.min_responses as ok) shown
    where s.workspace_id = workspace
    order by s.created_at, s.id;
end;
$$;

revoke all on function public.pulse_can_manage(uuid), public.pulse_survey_workspace(uuid),
  public.create_pulse_survey(uuid, text, jsonb, boolean, integer),
  public.submit_pulse_response(uuid, jsonb, text), public.set_pulse_survey_status(uuid, text),
  public.delete_pulse_survey(uuid), public.pulse_survey_results(uuid) from public, anon;
grant execute on function public.pulse_can_manage(uuid), public.pulse_survey_workspace(uuid),
  public.create_pulse_survey(uuid, text, jsonb, boolean, integer),
  public.submit_pulse_response(uuid, jsonb, text), public.set_pulse_survey_status(uuid, text),
  public.delete_pulse_survey(uuid), public.pulse_survey_results(uuid) to authenticated;

-- A workspace made for a team is released with its last team, unless Pulse keeps surveys in it.
create or replace function public.teams_release_workspace() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  delete from public.workspaces w
    where w.id = old.workspace_id and w.created_for_team
      and not exists (select 1 from public.teams t where t.workspace_id = w.id)
      and not exists (select 1 from public.projects p where p.workspace_id = w.id)
      and not exists (select 1 from public.pulse_surveys s where s.workspace_id = w.id);
  return null;
end;
$$;
