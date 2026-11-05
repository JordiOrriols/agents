-- Draft content is editable in place; published content remains immutable unless first returned to draft.

create or replace function public.evaluations_before_update()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id
    or new.member_id is distinct from old.member_id
    or new.kind is distinct from old.kind
    or new.author_name is distinct from old.author_name
    or new.created_at is distinct from old.created_at then
    raise exception 'evaluation identity is immutable';
  end if;

  if old.status <> 'draft' and (
    new.current_levels is distinct from old.current_levels
    or new.goal_levels is distinct from old.goal_levels
    or new.comments is distinct from old.comments
  ) then
    raise exception 'published evaluation content is immutable';
  end if;

  if new.kind in ('manager', 'self')
    and new.status = 'draft'
    and old.status <> 'draft'
    and exists (
      select 1
      from public.evaluations e
      where e.id <> new.id
        and e.member_id = new.member_id
        and e.kind = new.kind
        and e.status = 'draft'
    ) then
    raise exception 'a draft already exists' using errcode = '23505';
  end if;
  return new;
end;
$$;

create or replace function public.evaluations_before_insert()
returns trigger
language plpgsql
as $$
begin
  if new.kind in ('manager', 'self') and new.status = 'draft' and exists (
    select 1
    from public.evaluations e
    where e.member_id = new.member_id
      and e.kind = new.kind
      and e.status = 'draft'
  ) then
    raise exception 'a draft already exists' using errcode = '23505';
  end if;
  return new;
end;
$$;

drop trigger if exists evaluations_before_insert on public.evaluations;
create trigger evaluations_before_insert
before insert on public.evaluations
for each row execute function public.evaluations_before_insert();

create or replace function public.self_update_draft(
  p_token uuid,
  p_id uuid,
  p_status text,
  p_current jsonb,
  p_goal jsonb,
  p_comments jsonb
)
returns public.evaluations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row evaluations;
begin
  update evaluations e
  set status = p_status,
      current_levels = p_current,
      goal_levels = p_goal,
      comments = p_comments
  from members m
  where e.id = p_id
    and e.kind = 'self'
    and e.status = 'draft'
    and m.id = e.member_id
    and m.self_token = p_token
  returning e.* into v_row;

  if v_row is null then
    raise exception 'draft not found' using errcode = '22023';
  end if;
  return v_row;
end;
$$;

revoke execute on function public.self_update_draft(uuid, uuid, text, jsonb, jsonb, jsonb)
from public;
grant execute on function public.self_update_draft(uuid, uuid, text, jsonb, jsonb, jsonb)
to anon, authenticated;