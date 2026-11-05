alter table public.planner_projects
  add constraint planner_projects_whole_estimates check (
    backend_devs = trunc(backend_devs) and backend_weeks = trunc(backend_weeks)
    and frontend_devs = trunc(frontend_devs) and frontend_weeks = trunc(frontend_weeks)
    and design_devs = trunc(design_devs) and design_weeks = trunc(design_weeks)
    and qa_devs = trunc(qa_devs) and qa_weeks = trunc(qa_weeks)
  ) not valid;
