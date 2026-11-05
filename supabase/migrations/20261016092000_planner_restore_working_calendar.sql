-- Working Day removes vacation overrides; normal weekends and holidays remain non-working.
create or replace function public.planner_set_team_availability(member uuid, start_date date, end_date date, working boolean)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not public.can_edit_member(member) then raise exception 'Team edit access required'; end if;
  if start_date is null or end_date is null or end_date < start_date or end_date - start_date > 365
    or start_date < date '2026-01-01' or end_date > date '2027-12-31'
    or working is null then raise exception 'Choose a verified date range of at most 366 days'; end if;
  if working then
    delete from public.planner_team_availability a
      where a.member_id = member and a.date between start_date and end_date and not a.is_working;
  else
    insert into public.planner_team_availability(member_id, date, is_working)
      select member, day::date, false
      from pg_catalog.generate_series(start_date::timestamp, end_date::timestamp, interval '1 day') day
      on conflict(member_id, date) do update set is_working = false;
  end if;
end;
$$;

create or replace function public.planner_vacation_save(token uuid, start_date date, end_date date, working boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare member uuid;
begin
  select m.id into member from public.members m where m.vacation_token = token;
  if member is null then raise exception 'Invalid vacation link'; end if;
  if start_date is null or end_date is null or end_date < start_date or end_date - start_date > 365
    or start_date < date '2026-01-01' or end_date > date '2027-12-31'
    or working is null then raise exception 'Choose a verified date range of at most 366 days'; end if;
  if working then
    delete from public.planner_team_availability a
      where a.member_id = member and a.date between start_date and end_date and not a.is_working;
  else
    insert into public.planner_team_availability(member_id, date, is_working)
      select member, day::date, false
      from pg_catalog.generate_series(start_date::timestamp, end_date::timestamp, interval '1 day') day
      on conflict(member_id, date) do update set is_working = false;
  end if;
end;
$$;
