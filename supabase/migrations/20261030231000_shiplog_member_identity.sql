-- Supabase auth.users.email is varchar; RETURN QUERY requires an exact text result.
create or replace function public.shiplog_list_release_decisions(release uuid)
returns table(user_id uuid,name text,approved boolean,decided_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare workspace uuid;
begin
  select workspace_id into workspace from public.shiplog_releases where id = release;
  if public.workspace_access(workspace,'shiplog') is null then raise exception 'Shiplog access required' using errcode = '42501'; end if;
  return query select u.id,u.email::text,d.approved,d.decided_at
    from auth.users u left join public.shiplog_release_decisions d on d.user_id = u.id and d.release_id = release
    where u.id = (select w.owner_id from public.workspaces w where w.id = workspace)
      or exists(select 1 from public.workspace_collaborators c where c.workspace_id = workspace and c.app = 'shiplog' and c.user_id = u.id)
    order by u.email,u.id;
end;
$$;
