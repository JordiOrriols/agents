alter table public.planner_workspaces
  add column plan_start_date date not null default current_date;
