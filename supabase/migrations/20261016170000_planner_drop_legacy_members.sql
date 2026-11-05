-- planner_members / planner_availability predate linking workspaces to Ladders teams.
-- The app reads people from public.members (planner_workspace_roster) and leave from
-- planner_team_availability, and shares workspaces through planner_workspace_collaborators.
-- The only production row was a workspace owner, who keeps access through ownership.

create or replace function public.planner_has_access(workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.planner_is_owner(workspace) or exists (
    select 1 from public.planner_workspace_collaborators c
    where c.workspace_id = workspace and c.user_id = auth.uid()
  ) or exists (
    select 1 from public.planner_workspace_teams wt
    where wt.workspace_id = workspace and public.can_view_team(wt.team_id)
  );
$$;

drop function public.planner_create_workspace(text, text, text);
drop function public.planner_invite_member(uuid, text, text, text);
drop function public.planner_list_invitations();
drop function public.planner_accept_invitation(uuid);
drop function public.planner_update_member(uuid, text, text);
drop function public.planner_set_availability(uuid, date, date, boolean);

drop table public.planner_availability;
drop function public.planner_can_edit_availability(uuid);
drop table public.planner_members;
