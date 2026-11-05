-- SMART goals attached to team members.

create table public.smart_goals (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members (id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 160),
  description text not null default '',
  due_date date,
  progress smallint not null default 0 check (progress between 0 and 100),
  comments text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index smart_goals_member_idx on public.smart_goals (member_id, created_at);

grant select, insert, update, delete on public.smart_goals to authenticated;

create or replace function public.smart_goals_before_update()
returns trigger
language plpgsql
as $$
begin
  new.title := trim(new.title);
  new.updated_at := now();
  return new;
end;
$$;

create trigger smart_goals_before_update
before update on public.smart_goals
for each row execute function public.smart_goals_before_update();

create policy smart_goals_select on public.smart_goals
  for select to authenticated
  using (public.can_view_member(member_id));

create policy smart_goals_insert on public.smart_goals
  for insert to authenticated
  with check (public.can_edit_member(member_id));

create policy smart_goals_update on public.smart_goals
  for update to authenticated
  using (public.can_edit_member(member_id))
  with check (public.can_edit_member(member_id));

create policy smart_goals_delete on public.smart_goals
  for delete to authenticated
  using (public.can_edit_member(member_id));
