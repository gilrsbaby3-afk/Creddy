-- Repair the app_profiles RLS recursion without changing any app data.
-- Run once in Supabase SQL Editor for the Creddy project.
-- The helper is SECURITY DEFINER and disables row security inside its own lookup,
-- so policies on app_profiles can safely ask whether the current user is an admin.

begin;

create or replace function public.is_creddy_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1
    from public.app_profiles as p
    where p.id = (select auth.uid())
      and p.is_admin = true
  );
$$;

revoke all on function public.is_creddy_admin() from public, anon;
grant execute on function public.is_creddy_admin() to authenticated;

alter table public.app_profiles enable row level security;

-- Remove older/duplicate policies on this table that may reference app_profiles
-- recursively. This removes policies only; it does not delete or alter table data.
do $$
declare
  policy_row record;
begin
  for policy_row in
    select policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = 'app_profiles'
  loop
    execute format('drop policy %I on public.app_profiles', policy_row.policyname);
  end loop;
end;
$$;

create policy app_profiles_read_self_or_admin
on public.app_profiles
for select
to authenticated
using (id = (select auth.uid()) or public.is_creddy_admin());

create policy app_profiles_update_self
on public.app_profiles
for update
to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

-- Keep client updates limited to profile fields; clients cannot change is_admin.
revoke all on public.app_profiles from anon, authenticated;
grant select on public.app_profiles to authenticated;
grant update (full_name, national_id, phone) on public.app_profiles to authenticated;

commit;
