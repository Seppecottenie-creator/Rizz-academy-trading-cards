-- =====================================================================
-- RIZZ ACADEMY — update 21: zat worden is een verrassing
--
-- Na een willekeurig aantal pintjes (1 tot 5) ben je 1 minuut sterrezat. Je ziet niet hoeveel
-- pintjes het nog duurt.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-20-pintje.sql uit.
-- =====================================================================
alter table public.beer_state add column if not exists limit_n int;

-- De teller niet meer zelf kunnen lezen (anders weet je wanneer je zat wordt)
drop policy if exists "eigen pintjes lezen" on public.beer_state;

create or replace function public.buy_beer() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_coins int; b public.beer_state;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select polycoins into v_coins from public.user_wallet where user_id = me for update;
  if coalesce(v_coins, 0) < 1 then raise exception 'Niet genoeg credits voor een pintje.'; end if;
  insert into public.beer_state (user_id) values (me) on conflict do nothing;
  select * into b from public.beer_state where user_id = me for update;
  if b.drunk_until > now() then raise exception 'Je bent al sterrezat. Even wachten met het volgende pintje.'; end if;
  update public.user_wallet set polycoins = polycoins - 1 where user_id = me returning polycoins into v_coins;
  if b.limit_n is null then b.limit_n := 1 + floor(random() * 5)::int; end if;
  b.pints := b.pints + 1; b.total := b.total + 1;
  if b.pints >= b.limit_n then
    b.pints := 0; b.limit_n := 1 + floor(random() * 5)::int; b.drunk_until := now() + interval '1 minute';
  end if;
  update public.beer_state set pints = b.pints, total = b.total, limit_n = b.limit_n, drunk_until = b.drunk_until where user_id = me;
  return jsonb_build_object('total', b.total,
    'drunk_ms', greatest(0, extract(epoch from (b.drunk_until - now())) * 1000)::int, 'wallet', v_coins);
end $$;
grant execute on function public.buy_beer() to authenticated;
notify pgrst, 'reload schema';
