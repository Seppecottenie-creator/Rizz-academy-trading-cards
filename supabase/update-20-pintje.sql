-- =====================================================================
-- RIZZ ACADEMY — update 20: een pintje in The Vault
--
-- Een pintje kost 1 credit. Na 5 pintjes ben je 1 minuut zat (wazig scherm), daarna begint
-- de teller opnieuw.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
-- =====================================================================
create table if not exists public.beer_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pints int not null default 0,
  total int not null default 0,
  drunk_until timestamptz
);
alter table public.beer_state enable row level security;
drop policy if exists "eigen pintjes lezen" on public.beer_state;
create policy "eigen pintjes lezen" on public.beer_state for select to authenticated using (auth.uid() = user_id);

create or replace function public.buy_beer() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_coins int; b public.beer_state;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select polycoins into v_coins from public.user_wallet where user_id = me for update;
  if coalesce(v_coins, 0) < 1 then raise exception 'Niet genoeg credits voor een pintje.'; end if;
  insert into public.beer_state (user_id) values (me) on conflict do nothing;
  select * into b from public.beer_state where user_id = me for update;
  if b.drunk_until > now() then raise exception 'Je bent al zat. Even wachten met het volgende pintje.'; end if;
  update public.user_wallet set polycoins = polycoins - 1 where user_id = me returning polycoins into v_coins;
  b.pints := b.pints + 1; b.total := b.total + 1;
  if b.pints >= 5 then b.pints := 0; b.drunk_until := now() + interval '1 minute'; end if;
  update public.beer_state set pints = b.pints, total = b.total, drunk_until = b.drunk_until where user_id = me;
  return jsonb_build_object('pints', b.pints, 'total', b.total, 'drunk_until', b.drunk_until,
    'drunk_ms', greatest(0, extract(epoch from (b.drunk_until - now())) * 1000)::int, 'wallet', v_coins);
end $$;
grant execute on function public.buy_beer() to authenticated;
notify pgrst, 'reload schema';
