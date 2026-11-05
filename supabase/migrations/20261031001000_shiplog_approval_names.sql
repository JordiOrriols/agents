drop function public.shiplog_list_release_decisions(uuid);
create function public.shiplog_list_release_decisions(release uuid)
returns table(user_id uuid,name text,account_name text,email text,approved boolean,decided_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare workspace uuid; application_team uuid;
begin
  select r.workspace_id,a.team_id into workspace,application_team
    from public.shiplog_releases r join public.shiplog_applications a on a.id = r.application_id
    where r.id = release;
  if public.workspace_access(workspace,'shiplog') is null then
    raise exception 'Shiplog access required' using errcode = '42501';
  end if;
  return query select u.id,coalesce(member.name,''),
    coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''),
      nullif(btrim(u.raw_user_meta_data->>'name'),'')),
    u.email::text,d.approved,d.decided_at
    from auth.users u
    left join public.shiplog_release_decisions d on d.user_id = u.id and d.release_id = release
    left join lateral (
      select m.name from public.members m join public.teams t on t.id = m.team_id
        where m.user_id = u.id and t.workspace_id = workspace and btrim(m.name) <> ''
        order by (m.team_id = application_team) desc nulls last,m.id limit 1
    ) member on true
    where u.id = (select w.owner_id from public.workspaces w where w.id = workspace)
      or exists(select 1 from public.workspace_collaborators c
        where c.workspace_id = workspace and c.app = 'shiplog' and c.user_id = u.id)
    order by u.email,u.id;
end;
$$;
revoke all on function public.shiplog_list_release_decisions(uuid) from public,anon;
grant execute on function public.shiplog_list_release_decisions(uuid) to authenticated;
