-- Create teams through a controlled authenticated RPC.
-- This avoids depending on PostgREST to apply auth.uid() as an insert default.

create or replace function public.create_team(p_name text)
returns public.teams
language plpgsql
security definer
set search_path = public
as $$
declare
  created_team public.teams;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  insert into public.teams (owner_id, name)
  values (auth.uid(), trim(p_name))
  returning * into created_team;

  return created_team;
end;
$$;

revoke execute on function public.create_team(text) from public, anon;
grant execute on function public.create_team(text) to authenticated;
