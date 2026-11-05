alter table public.smart_goals enable row level security;

drop function public.token_goal_create(uuid, text, text, date, smallint, text);
drop function public.token_goal_update(uuid, uuid, text, text, date, smallint, text);
drop function public.token_goal_delete(uuid, uuid);

alter table public.smart_goals alter column comments drop default;
alter table public.smart_goals alter column comments type jsonb using (
  case when trim(comments) = '' then '[]'::jsonb
  else jsonb_build_array(jsonb_build_object(
    'id', gen_random_uuid(), 'text', comments,
    'createdAt', updated_at, 'authorKind', 'legacy'
  )) end
);
alter table public.smart_goals alter column comments set default '[]'::jsonb;
alter table public.smart_goals add constraint smart_goals_comments_array
  check (jsonb_typeof(comments) = 'array');

revoke insert, update on public.smart_goals from authenticated;
grant insert (member_id, title, description, due_date, progress) on public.smart_goals to authenticated;
grant update (title, description, due_date, progress) on public.smart_goals to authenticated;

create or replace function public.smart_goals_before_update()
returns trigger language plpgsql as $$
begin
  if new.id is distinct from old.id or new.member_id is distinct from old.member_id
    or new.created_at is distinct from old.created_at then
    raise exception 'goal identity is immutable';
  end if;
  if new.comments is distinct from old.comments and (
    jsonb_array_length(new.comments) <> jsonb_array_length(old.comments) + 1
    or (new.comments - (jsonb_array_length(new.comments) - 1)) <> old.comments
  ) then
    raise exception 'saved comments are immutable';
  end if;
  new.title := trim(new.title);
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.goal_member_for_token(p_token uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from members where view_token = p_token and view_enabled;
$$;

create function public.view_goal_progress(p_token uuid, p_id uuid, p_progress integer)
returns public.smart_goals language plpgsql security definer set search_path = public as $$
declare
  v_member_id uuid := public.goal_member_for_token(p_token);
  v_row smart_goals;
begin
  if v_member_id is null then
    raise exception 'invalid view link' using errcode = '28000';
  end if;
  if p_progress is null or p_progress not between 0 and 100 then
    raise exception 'progress must be between 0 and 100' using errcode = '22023';
  end if;
  update smart_goals set progress = p_progress
    where id = p_id and member_id = v_member_id returning * into v_row;
  if not found then raise exception 'invalid goal' using errcode = '28000'; end if;
  return v_row;
end;
$$;

create function public.append_goal_comment(p_id uuid, p_text text, p_token uuid default null)
returns public.smart_goals language plpgsql security definer set search_path = public as $$
declare
  v_member_id uuid;
  v_author text;
  v_row smart_goals;
begin
  if p_text is null or char_length(trim(p_text)) not between 1 and 10000 then
    raise exception 'comment must contain 1 to 10000 characters' using errcode = '22023';
  end if;
  if p_token is not null then
    v_member_id := public.goal_member_for_token(p_token);
    v_author := 'member';
    if v_member_id is null then raise exception 'invalid view link' using errcode = '28000'; end if;
  else
    select member_id into v_member_id from smart_goals where id = p_id;
    v_author := 'manager';
    if auth.uid() is null or not public.can_edit_member(v_member_id) then
      raise exception 'comment access denied' using errcode = '42501';
    end if;
  end if;
  update smart_goals set comments = comments || jsonb_build_array(jsonb_build_object(
    'id', gen_random_uuid(), 'text', trim(p_text), 'createdAt', now(), 'authorKind', v_author
  )) where id = p_id and member_id = v_member_id returning * into v_row;
  if not found then raise exception 'invalid goal' using errcode = '28000'; end if;
  return v_row;
end;
$$;

revoke execute on function public.view_goal_progress(uuid, uuid, integer),
  public.append_goal_comment(uuid, text, uuid) from public;
grant execute on function public.view_goal_progress(uuid, uuid, integer),
  public.append_goal_comment(uuid, text, uuid) to anon, authenticated;