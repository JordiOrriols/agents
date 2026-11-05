create function public.planner_vacation_team_members(token uuid)
returns table(id uuid, name text, role text)
language plpgsql stable security definer set search_path = '' as $$
declare member_team uuid;
begin
  select m.team_id into member_team from public.members m where m.vacation_token = token;
  if member_team is null then raise exception 'Invalid vacation link'; end if;
  return query select m.id, m.name, m.planning_role
    from public.members m where m.team_id = member_team order by m.name, m.id;
end;
$$;

create function public.planner_vacation_team_list(token uuid)
returns table(member_id uuid, date date, is_working boolean)
language plpgsql stable security definer set search_path = '' as $$
declare token_member uuid; member_team uuid;
begin
  select m.id, m.team_id into token_member, member_team
    from public.members m where m.vacation_token = token;
  if token_member is null then raise exception 'Invalid vacation link'; end if;
  return query select a.member_id, a.date, a.is_working
    from public.planner_team_availability a
    join public.members m on m.id = a.member_id
    where m.team_id = member_team and (m.id = token_member or not a.is_working)
    order by a.date, a.member_id;
end;
$$;

revoke all on function public.planner_vacation_team_members(uuid),
  public.planner_vacation_team_list(uuid) from public, anon, authenticated;
grant execute on function public.planner_vacation_team_members(uuid),
  public.planner_vacation_team_list(uuid) to anon, authenticated;
