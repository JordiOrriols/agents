-- SMART goals for the evaluated person through their self or view link.

create or replace function public.goal_member_for_token(p_token uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select m.id
  from members m
  where m.self_token = p_token or (m.view_token = p_token and m.view_enabled)
  limit 1;
$$;

create or replace function public.token_goals_list(p_token uuid)
returns setof public.smart_goals
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_member_id uuid := public.goal_member_for_token(p_token);
begin
  if v_member_id is null then
    raise exception 'invalid link' using errcode = '28000';
  end if;
  return query
    select * from smart_goals g where g.member_id = v_member_id order by g.created_at;
end;
$$;

create or replace function public.token_goal_create(
  p_token uuid,
  p_title text,
  p_description text,
  p_due_date date,
  p_progress smallint,
  p_comments text
)
returns public.smart_goals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid := public.goal_member_for_token(p_token);
  v_row smart_goals;
begin
  if v_member_id is null then
    raise exception 'invalid link' using errcode = '28000';
  end if;
  insert into smart_goals (member_id, title, description, due_date, progress, comments)
  values (
    v_member_id,
    trim(p_title),
    coalesce(p_description, ''),
    p_due_date,
    p_progress,
    coalesce(p_comments, '')
  )
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.token_goal_update(
  p_token uuid,
  p_id uuid,
  p_title text,
  p_description text,
  p_due_date date,
  p_progress smallint,
  p_comments text
)
returns public.smart_goals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid := public.goal_member_for_token(p_token);
  v_row smart_goals;
begin
  if v_member_id is null then
    raise exception 'invalid link' using errcode = '28000';
  end if;
  update smart_goals
  set title = p_title,
      description = coalesce(p_description, ''),
      due_date = p_due_date,
      progress = p_progress,
      comments = coalesce(p_comments, '')
  where id = p_id and member_id = v_member_id
  returning * into v_row;
  if v_row.id is null then
    raise exception 'invalid link' using errcode = '28000';
  end if;
  return v_row;
end;
$$;

create or replace function public.token_goal_delete(p_token uuid, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid := public.goal_member_for_token(p_token);
begin
  if v_member_id is null then
    raise exception 'invalid link' using errcode = '28000';
  end if;
  delete from smart_goals where id = p_id and member_id = v_member_id;
  if not found then
    raise exception 'invalid link' using errcode = '28000';
  end if;
end;
$$;

revoke execute on function public.goal_member_for_token(uuid) from public, anon, authenticated;

revoke execute on function
  public.token_goals_list(uuid),
  public.token_goal_create(uuid, text, text, date, smallint, text),
  public.token_goal_update(uuid, uuid, text, text, date, smallint, text),
  public.token_goal_delete(uuid, uuid)
from public;

grant execute on function
  public.token_goals_list(uuid),
  public.token_goal_create(uuid, text, text, date, smallint, text),
  public.token_goal_update(uuid, uuid, text, text, date, smallint, text),
  public.token_goal_delete(uuid, uuid)
to anon, authenticated;
