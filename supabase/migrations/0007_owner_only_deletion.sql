revoke execute on function public.self_delete(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.token_goal_delete(uuid, uuid) from public, anon, authenticated;

drop policy smart_goals_delete on public.smart_goals;
create policy smart_goals_delete on public.smart_goals
  for delete to authenticated
  using (public.is_member_team_owner(member_id));