-- Sharing and team creation moved to workspaces; nothing calls the per-team versions any more.
drop function if exists public.create_team(text);
drop function if exists public.list_team_shares(uuid);
drop function if exists public.share_team_by_email(uuid, text, text);
drop function if exists public.update_team_share(uuid, uuid, text);
drop function if exists public.remove_team_share(uuid, uuid);
drop function if exists public.planner_create_linked_workspace(text);
