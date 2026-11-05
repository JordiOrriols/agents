alter table public.planner_workspaces
  add column sprint_start_date date not null default current_date,
  add column sprint_history jsonb not null default '[]'::jsonb;

create function public.planner_validate_sprint_calibration()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  entry jsonb;
  sprint_date date;
  seen_dates date[] := '{}';
begin
  if new.sprint_start_date < date '2026-01-01'
     or new.sprint_start_date + 13 > date '2027-12-31' then
    raise exception 'Sprint start must be within the verified 2026-2027 calendar';
  end if;
  if jsonb_typeof(new.sprint_history) <> 'array' then
    raise exception 'Sprint history must be an array';
  end if;
  for entry in select value from jsonb_array_elements(new.sprint_history)
  loop
    if jsonb_typeof(entry) <> 'object'
       or not (entry ? 'start_date' and entry ? 'story_points')
       or jsonb_typeof(entry->'start_date') <> 'string'
       or jsonb_typeof(entry->'story_points') <> 'number'
       or (entry->>'story_points')::numeric < 0 then
      raise exception 'Each sprint requires a start date and non-negative story points';
    end if;
    if entry->>'start_date' !~ '^\d{4}-\d{2}-\d{2}$' then
      raise exception 'Invalid sprint date';
    end if;
    sprint_date := (entry->>'start_date')::date;
    if sprint_date < date '2026-01-01' or sprint_date + 13 > date '2027-12-31'
       or (sprint_date - new.sprint_start_date) % 14 <> 0 then
      raise exception 'Sprint dates must follow the two-week cadence within the verified calendar';
    end if;
    if sprint_date = any(seen_dates) then
      raise exception 'Sprint dates must be unique';
    end if;
    seen_dates := array_append(seen_dates, sprint_date);
  end loop;
  return new;
end;
$$;

create trigger planner_sprint_calibration_valid
before insert or update of sprint_start_date, sprint_history on public.planner_workspaces
for each row execute function public.planner_validate_sprint_calibration();
