-- Creddy: complete, repeatable Supabase setup for the current web app.
-- Run the whole file in the SQL Editor of the same Supabase project configured in index.html.
-- It creates/updates application objects and access policies; it does not delete application data.

begin;

create extension if not exists pgcrypto;
grant usage on schema public to authenticated;

create table if not exists public.app_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) between 2 and 120),
  national_id text not null check (length(trim(national_id)) between 3 and 24),
  phone text not null check (length(trim(phone)) between 7 and 20),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.credit_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_profiles(id) on delete cascade,
  amount_usd numeric(12,2) not null default 10 check (amount_usd = 10),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  bcv_rate numeric(14,4),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.app_profiles(id)
);

create table if not exists public.credit_accounts (
  user_id uuid primary key references public.app_profiles(id) on delete cascade,
  approved_limit_bs numeric(14,2) not null default 0 check (approved_limit_bs >= 0),
  available_bs numeric(14,2) not null default 0 check (available_bs >= 0),
  debt_bs numeric(14,2) not null default 0 check (debt_bs >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.recharge_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_profiles(id) on delete cascade,
  operator text not null check (operator in ('Movistar','Digitel','Movilnet')),
  phone text not null check (phone ~ '^04[0-9]{9}$'),
  amount_bs numeric(14,2) not null check (amount_bs > 0),
  fee_bs numeric(14,2) not null check (fee_bs >= 0),
  total_bs numeric(14,2) not null check (total_bs = amount_bs + fee_bs),
  status text not null default 'pending' check (status in ('pending','completed','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.app_profiles(id)
);

create table if not exists public.payment_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_profiles(id) on delete cascade,
  amount_bs numeric(14,2) not null check (amount_bs > 0),
  reference text not null check (length(trim(reference)) between 1 and 100),
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.app_profiles(id)
);

create index if not exists credit_requests_owner_created_idx on public.credit_requests(user_id, created_at desc);
create index if not exists recharge_orders_owner_created_idx on public.recharge_orders(user_id, created_at desc);
create index if not exists payment_reports_owner_created_idx on public.payment_reports(user_id, created_at desc);
create index if not exists credit_requests_pending_idx on public.credit_requests(status, created_at);
create index if not exists recharge_orders_pending_idx on public.recharge_orders(status, created_at);
create index if not exists payment_reports_pending_idx on public.payment_reports(status, created_at);

-- Safe admin check for use by RLS policies (avoids recursive profile policies).
create or replace function public.is_creddy_admin()
returns boolean language sql stable security definer
set search_path = '' set row_security = off
as $$
  select exists (
    select 1 from public.app_profiles p
    where p.id = (select auth.uid()) and p.is_admin = true
  );
$$;

-- Create profile rows automatically on registration, preserving signup metadata.
create or replace function public.handle_creddy_signup()
returns trigger language plpgsql security definer
set search_path = '' set row_security = off
as $$
begin
  insert into public.app_profiles (id, full_name, national_id, phone, is_admin)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), 'Usuario'), 120),
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'national_id'), ''), 'PENDIENTE'), 24),
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'phone'), ''), 'PENDIENTE'), 20),
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_creddy_auth_user_created on auth.users;
create trigger on_creddy_auth_user_created
after insert on auth.users for each row execute function public.handle_creddy_signup();

-- This RPC is called by the current frontend after login; it only initializes the caller's own profile.
create or replace function public.ensure_creddy_profile()
returns void language plpgsql security definer
set search_path = '' set row_security = off
as $$
declare
  current_id uuid := (select auth.uid());
  meta jsonb := coalesce((select auth.jwt()) -> 'user_metadata', '{}'::jsonb);
begin
  if current_id is null then raise exception 'Debes iniciar sesión'; end if;
  insert into public.app_profiles(id, full_name, national_id, phone, is_admin)
  values (
    current_id,
    left(coalesce(nullif(trim(meta ->> 'full_name'), ''), 'Usuario'), 120),
    left(coalesce(nullif(trim(meta ->> 'national_id'), ''), 'PENDIENTE'), 24),
    left(coalesce(nullif(trim(meta ->> 'phone'), ''), 'PENDIENTE'), 20),
    false
  ) on conflict (id) do nothing;
end;
$$;

create or replace function public.request_credit()
returns uuid language plpgsql security definer
set search_path = '' set row_security = off
as $$
declare new_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'Debes iniciar sesión'; end if;
  if exists (
    select 1 from public.credit_requests r
    where r.user_id = (select auth.uid()) and r.status = 'pending'
  ) then raise exception 'Ya tienes una solicitud de crédito pendiente'; end if;
  insert into public.credit_requests(user_id) values ((select auth.uid())) returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.admin_review_credit(p_request_id uuid, p_approved boolean, p_bcv_rate numeric default null)
returns void language plpgsql security definer
set search_path = '' set row_security = off
as $$
declare req public.credit_requests%rowtype; grant_bs numeric(14,2);
begin
  if not public.is_creddy_admin() then raise exception 'No autorizado'; end if;
  select * into req from public.credit_requests where id = p_request_id for update;
  if not found or req.status <> 'pending' then raise exception 'La solicitud no existe o ya fue revisada'; end if;
  if p_approved then
    if p_bcv_rate is null or p_bcv_rate <= 0 then raise exception 'La tasa BCV debe ser mayor que cero'; end if;
    grant_bs := round(req.amount_usd * p_bcv_rate, 2);
    update public.credit_requests set status='approved', bcv_rate=p_bcv_rate, reviewed_at=now(), reviewed_by=(select auth.uid()) where id=p_request_id;
    insert into public.credit_accounts(user_id, approved_limit_bs, available_bs)
    values(req.user_id, grant_bs, grant_bs)
    on conflict(user_id) do update set approved_limit_bs=public.credit_accounts.approved_limit_bs+excluded.approved_limit_bs,
      available_bs=public.credit_accounts.available_bs+excluded.available_bs, updated_at=now();
  else
    update public.credit_requests set status='rejected', reviewed_at=now(), reviewed_by=(select auth.uid()) where id=p_request_id;
  end if;
end;
$$;

-- Enforce operator minimums in the database, not just in the browser.
create or replace function public.request_recharge(p_operator text, p_phone text, p_amount_bs numeric)
returns uuid language plpgsql security definer
set search_path = '' set row_security = off
as $$
declare
  acct public.credit_accounts%rowtype; new_id uuid;
  charge numeric(14,2); fee numeric(14,2); minimum_amount numeric(14,2);
begin
  if (select auth.uid()) is null then raise exception 'Debes iniciar sesión'; end if;
  if p_operator not in ('Movistar','Digitel','Movilnet') then raise exception 'Operadora no válida'; end if;
  if p_phone !~ '^04[0-9]{9}$' then raise exception 'El teléfono debe tener 11 dígitos y comenzar con 04'; end if;
  minimum_amount := case when p_operator = 'Movilnet' then 400 else 500 end;
  if p_amount_bs is null or p_amount_bs < minimum_amount or p_amount_bs > 100000 then
    raise exception 'El monto mínimo para % es Bs. %; máximo Bs. 100000', p_operator, minimum_amount;
  end if;
  fee := round(p_amount_bs * 0.10, 2); charge := p_amount_bs + fee;
  select * into acct from public.credit_accounts where user_id=(select auth.uid()) for update;
  if not found or acct.available_bs < p_amount_bs then raise exception 'Crédito disponible insuficiente'; end if;
  update public.credit_accounts set available_bs=available_bs-p_amount_bs, debt_bs=debt_bs+charge, updated_at=now() where user_id=(select auth.uid());
  insert into public.recharge_orders(user_id,operator,phone,amount_bs,fee_bs,total_bs)
  values((select auth.uid()),p_operator,p_phone,p_amount_bs,fee,charge) returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.admin_set_recharge_status(p_recharge_id uuid, p_status text)
returns void language plpgsql security definer
set search_path = '' set row_security = off
as $$
declare rec public.recharge_orders%rowtype;
begin
  if not public.is_creddy_admin() then raise exception 'No autorizado'; end if;
  if p_status not in ('completed','rejected') then raise exception 'Estado no válido'; end if;
  select * into rec from public.recharge_orders where id=p_recharge_id for update;
  if not found or rec.status <> 'pending' then raise exception 'La recarga no existe o ya fue revisada'; end if;
  update public.recharge_orders set status=p_status, reviewed_at=now(), reviewed_by=(select auth.uid()) where id=p_recharge_id;
  if p_status='rejected' then
    update public.credit_accounts set available_bs=available_bs+rec.amount_bs,
      debt_bs=greatest(0,debt_bs-rec.total_bs), updated_at=now() where user_id=rec.user_id;
  end if;
end;
$$;

create or replace function public.submit_payment_report(p_amount_bs numeric, p_reference text)
returns uuid language plpgsql security definer
set search_path = '' set row_security = off
as $$
declare acct public.credit_accounts%rowtype; new_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'Debes iniciar sesión'; end if;
  if p_amount_bs is null or p_amount_bs <= 0 then raise exception 'Monto no válido'; end if;
  if p_reference is null or length(trim(p_reference)) not between 1 and 100 then raise exception 'Referencia no válida'; end if;
  select * into acct from public.credit_accounts where user_id=(select auth.uid());
  if not found or p_amount_bs > acct.debt_bs then raise exception 'El monto supera la deuda registrada'; end if;
  insert into public.payment_reports(user_id,amount_bs,reference) values((select auth.uid()),p_amount_bs,trim(p_reference)) returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.admin_review_payment(p_payment_id uuid, p_approved boolean)
returns void language plpgsql security definer
set search_path = '' set row_security = off
as $$
declare pay public.payment_reports%rowtype; acct public.credit_accounts%rowtype;
begin
  if not public.is_creddy_admin() then raise exception 'No autorizado'; end if;
  select * into pay from public.payment_reports where id=p_payment_id for update;
  if not found or pay.status <> 'pending' then raise exception 'El pago no existe o ya fue revisado'; end if;
  if p_approved then
    select * into acct from public.credit_accounts where user_id=pay.user_id for update;
    if not found or pay.amount_bs > acct.debt_bs then raise exception 'El pago supera la deuda actual'; end if;
    update public.credit_accounts set debt_bs=debt_bs-pay.amount_bs,
      available_bs=least(approved_limit_bs,available_bs+pay.amount_bs), updated_at=now() where user_id=pay.user_id;
    update public.payment_reports set status='confirmed',reviewed_at=now(),reviewed_by=(select auth.uid()) where id=p_payment_id;
  else
    update public.payment_reports set status='rejected',reviewed_at=now(),reviewed_by=(select auth.uid()) where id=p_payment_id;
  end if;
end;
$$;

-- Reset policies only for Creddy app tables, then apply owner/admin access rules.
do $$
declare p record;
begin
  for p in select schemaname, tablename, policyname from pg_policies
           where schemaname='public' and tablename in ('app_profiles','credit_requests','credit_accounts','recharge_orders','payment_reports')
  loop
    execute format('drop policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end;
$$;

alter table public.app_profiles enable row level security;
alter table public.credit_requests enable row level security;
alter table public.credit_accounts enable row level security;
alter table public.recharge_orders enable row level security;
alter table public.payment_reports enable row level security;

create policy app_profiles_read_self_or_admin on public.app_profiles for select to authenticated
using (id=(select auth.uid()) or public.is_creddy_admin());
create policy app_profiles_update_self on public.app_profiles for update to authenticated
using (id=(select auth.uid())) with check (id=(select auth.uid()));
create policy credit_requests_read_owner_admin on public.credit_requests for select to authenticated
using (user_id=(select auth.uid()) or public.is_creddy_admin());
create policy credit_accounts_read_owner_admin on public.credit_accounts for select to authenticated
using (user_id=(select auth.uid()) or public.is_creddy_admin());
create policy recharge_orders_read_owner_admin on public.recharge_orders for select to authenticated
using (user_id=(select auth.uid()) or public.is_creddy_admin());
create policy payment_reports_read_owner_admin on public.payment_reports for select to authenticated
using (user_id=(select auth.uid()) or public.is_creddy_admin());

revoke all on public.app_profiles, public.credit_requests, public.credit_accounts, public.recharge_orders, public.payment_reports from anon, authenticated;
grant select on public.app_profiles, public.credit_requests, public.credit_accounts, public.recharge_orders, public.payment_reports to authenticated;
grant update (full_name,national_id,phone) on public.app_profiles to authenticated;

revoke all on function public.is_creddy_admin() from public, anon;
revoke all on function public.ensure_creddy_profile() from public, anon;
revoke all on function public.request_credit() from public, anon;
revoke all on function public.admin_review_credit(uuid,boolean,numeric) from public, anon;
revoke all on function public.request_recharge(text,text,numeric) from public, anon;
revoke all on function public.admin_set_recharge_status(uuid,text) from public, anon;
revoke all on function public.submit_payment_report(numeric,text) from public, anon;
revoke all on function public.admin_review_payment(uuid,boolean) from public, anon;
grant execute on function public.is_creddy_admin() to authenticated;
grant execute on function public.ensure_creddy_profile() to authenticated;
grant execute on function public.request_credit() to authenticated;
grant execute on function public.admin_review_credit(uuid,boolean,numeric) to authenticated;
grant execute on function public.request_recharge(text,text,numeric) to authenticated;
grant execute on function public.admin_set_recharge_status(uuid,text) to authenticated;
grant execute on function public.submit_payment_report(numeric,text) to authenticated;
grant execute on function public.admin_review_payment(uuid,boolean) to authenticated;

commit;
notify pgrst, 'reload schema';
