-- Creddy: repair app_profiles permissions and safely create a missing profile.
-- Run this once in the SQL Editor of the Supabase project used by the app.
-- It does not delete or alter existing profile data.

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

-- Only create a profile for the currently authenticated user. This prevents
-- users from choosing another user's id or granting themselves admin access.
create or replace function public.ensure_creddy_profile()
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  current_id uuid := (select auth.uid());
  meta jsonb := coalesce((select auth.jwt()) -> 'user_metadata', '{}'::jsonb);
begin
  if current_id is null then
    raise exception 'Debes iniciar sesión';
  end if;

  insert into public.app_profiles (id, full_name, national_id, phone, is_admin)
  values (
    current_id,
    left(coalesce(nullif(trim(meta ->> 'full_name'), ''), 'Usuario'), 120),
    left(coalesce(nullif(trim(meta ->> 'national_id'), ''), 'PENDIENTE'), 24),
    left(coalesce(nullif(trim(meta ->> 'phone'), ''), 'PENDIENTE'), 20),
    false
  )
  on conflict (id) do nothing;
end;
$$;

revoke all on function public.ensure_creddy_profile() from public, anon;
grant execute on function public.ensure_creddy_profile() to authenticated;

alter table public.app_profiles enable row level security;

-- Replace policies on this table to remove any recursive/overly broad rules.
do $$
declare policy_row record;
begin
  for policy_row in
    select policyname
    from pg_policies
    where schemaname = 'public' and tablename = 'app_profiles'
  loop
    execute format('drop policy %I on public.app_profiles', policy_row.policyname);
  end loop;
end;
$$;

create policy app_profiles_read_self_or_admin
on public.app_profiles for select to authenticated
using (id = (select auth.uid()) or public.is_creddy_admin());

create policy app_profiles_update_self
on public.app_profiles for update to authenticated
using (id = (select auth.uid()))
with check (id = (select auth.uid()));

revoke all on public.app_profiles from anon, authenticated;
grant select on public.app_profiles to authenticated;
grant update (full_name, national_id, phone) on public.app_profiles to authenticated;

commit;
