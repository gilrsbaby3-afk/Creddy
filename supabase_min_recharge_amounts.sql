-- Enforce operator-specific minimum recharge amounts in Supabase as well as in the UI.
-- Run once in Supabase SQL Editor after the app update.
-- Digitel/Movistar minimum: Bs. 500. Movilnet minimum: Bs. 400.

create or replace function public.request_recharge(p_operator text, p_phone text, p_amount_bs numeric)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  acct public.credit_accounts%rowtype;
  new_id uuid;
  charge numeric(14,2);
  fee numeric(14,2);
  minimum_amount numeric(14,2);
begin
  if (select auth.uid()) is null then
    raise exception 'Debes iniciar sesión';
  end if;

  if p_operator not in ('Movistar','Digitel','Movilnet') then
    raise exception 'Operadora no válida';
  end if;

  if p_phone !~ '^04[0-9]{9}$' then
    raise exception 'El teléfono debe tener 11 dígitos y comenzar con 04';
  end if;

  minimum_amount := case when p_operator = 'Movilnet' then 400 else 500 end;
  if p_amount_bs is null or p_amount_bs < minimum_amount or p_amount_bs > 100000 then
    raise exception 'El monto mínimo para % es Bs. %; máximo Bs. 100000', p_operator, minimum_amount;
  end if;

  fee := round(p_amount_bs * 0.10, 2);
  charge := p_amount_bs + fee;

  select * into acct
  from public.credit_accounts
  where user_id = (select auth.uid())
  for update;

  if not found or acct.available_bs < p_amount_bs then
    raise exception 'Crédito disponible insuficiente';
  end if;

  update public.credit_accounts
  set available_bs = available_bs - p_amount_bs,
      debt_bs = debt_bs + charge,
      updated_at = now()
  where user_id = (select auth.uid());

  insert into public.recharge_orders(user_id, operator, phone, amount_bs, fee_bs, total_bs)
  values ((select auth.uid()), p_operator, p_phone, p_amount_bs, fee, charge)
  returning id into new_id;

  return new_id;
end;
$$;

revoke all on function public.request_recharge(text, text, numeric) from public, anon;
grant execute on function public.request_recharge(text, text, numeric) to authenticated;
notify pgrst, 'reload schema';
