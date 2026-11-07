create extension if not exists pgcrypto;

create table if not exists public.users (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  phone text,
  email text unique,
  role text not null default 'client',
  created_at timestamptz not null default now()
);

create table if not exists public.credit_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id) on delete cascade,
  amount_usd numeric(10,2) not null default 10.00,
  bcv_rate numeric(12,2),
  status text not null default 'pending',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.users(id)
);

create table if not exists public.credits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id) on delete cascade,
  amount_usd numeric(10,2) not null default 10.00,
  bcv_rate numeric(12,2) not null default 0,
  credit_available_bs numeric(12,2) not null default 0,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  approved_at timestamptz
);

create table if not exists public.recharges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id) on delete cascade,
  operator text not null,
  phone text not null,
  amount_bs numeric(12,2) not null default 0,
  fee_bs numeric(12,2) not null default 0,
  total_bs numeric(12,2) not null default 0,
  status text not null default 'pending',
  due_date timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.users(id) on delete cascade,
  amount_bs numeric(12,2) not null,
  status text not null default 'pending',
  reference text,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz
);

create table if not exists public.settings (
  id uuid primary key default gen_random_uuid(),
  key text unique not null,
  value text,
  updated_at timestamptz not null default now()
);

insert into public.settings (key, value)
values
  ('default_credit_usd', '10'),
  ('default_credit_rate', '50'),
  ('payment_bank', '0104'),
  ('payment_phone', '04126707872'),
  ('payment_cedula', '31.540.415')
on conflict (key) do nothing;
