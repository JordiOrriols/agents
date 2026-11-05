create function public.view_sharing_links(p_token uuid)
returns table (self_token uuid, peer_token uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query select m.self_token, m.peer_token
    from members m where m.view_token = p_token and m.view_enabled;
  if not found then
    raise exception 'invalid view link' using errcode = '28000';
  end if;
end;
$$;

revoke execute on function public.view_sharing_links(uuid) from public;
grant execute on function public.view_sharing_links(uuid) to anon, authenticated;