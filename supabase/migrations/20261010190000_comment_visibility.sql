create function public.valid_comment_visibility(value jsonb)
returns boolean language sql immutable set search_path = '' as $$
  select jsonb_typeof(value) = 'object' and not exists (
    select 1 from jsonb_each(value) entry
    where entry.key not in ('Technology','System','People','Process','Influence')
      or jsonb_typeof(entry.value) <> 'boolean'
  );
$$;

alter table public.evaluations add column comment_visibility jsonb not null default '{}'
  check (public.valid_comment_visibility(comment_visibility));

create function public.set_evaluation_comment_visibility(
  p_id uuid, p_category text, p_visible boolean
)
returns public.evaluations language plpgsql security definer set search_path = '' as $$
declare evaluation public.evaluations;
begin
  select * into evaluation from public.evaluations where id = p_id for update;
  if not found or not public.can_edit_member(evaluation.member_id) then
    raise exception 'Team edit access required' using errcode = '42501';
  end if;
  if p_category is null or p_category not in ('Technology','System','People','Process','Influence')
    or p_visible is null or coalesce(trim(evaluation.comments ->> p_category), '') = '' then
    raise exception 'Choose an existing competency comment';
  end if;
  update public.evaluations set comment_visibility =
    jsonb_set(comment_visibility, array[p_category], to_jsonb(p_visible))
    where id = p_id returning * into evaluation;
  return evaluation;
end;
$$;

-- Redact on the server: anonymous clients never receive hidden comment text.
-- Peer comments (including historical ones) require explicit manager approval.
create or replace function public.public_view(p_token uuid)
returns setof public.evaluations language sql stable security definer set search_path = '' as $$
  select e.id, e.member_id, e.kind, e.status, e.author_name, e.current_levels,
    e.goal_levels, coalesce((
      select jsonb_object_agg(comment.key, comment.value)
      from jsonb_each(e.comments) comment
      where coalesce((e.comment_visibility ->> comment.key)::boolean, e.kind <> 'peer')
    ), '{}'::jsonb), e.created_at, '{}'::jsonb
  from public.evaluations e join public.members m on m.id = e.member_id
  where m.view_token = p_token and m.view_enabled
    and (e.kind = 'self' or e.status = 'published')
  order by e.created_at desc;
$$;

revoke all on function public.set_evaluation_comment_visibility(uuid,text,boolean) from public, anon;
grant execute on function public.set_evaluation_comment_visibility(uuid,text,boolean) to authenticated;
