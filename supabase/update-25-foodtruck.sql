-- =====================================================================
-- RIZZ ACADEMY — update 25: de Food Truck heeft een volledige kaart
--
--   Pintje        1 credit   +1 richting sterrezat
--   Shotje        2 credits  +2 richting sterrezat
--   Red Bull      2 credits  30 seconden hyper (geen alcohol)
--   Kapsalon      4 credits  je bent meteen nuchter en de teller begint opnieuw
--   Rizz-poeder   8 credits  1 minuut trippen; 1 kans op 8 op een gratis kaart (max. 3 per dag)
--
-- Alles wat je koopt, komt in food_log (voor de geheime trofeeën, zie update 27).
-- Zolang je sterrezat bent, krijg je geen alcohol (pintje of shotje).
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-21-pintje-random.sql uit.
-- =====================================================================

create table if not exists public.food_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  item text not null,            -- pintje, shotje, redbull, kapsalon, poeder, of 'zat' (werd sterrezat)
  card_id int references public.cards(id) on delete set null,   -- gevonden kaart (Rizz-poeder)
  created_at timestamptz not null default now()
);
create index if not exists food_log_user_idx on public.food_log (user_id, created_at);
alter table public.food_log enable row level security;
drop policy if exists "eigen food log lezen" on public.food_log;
create policy "eigen food log lezen" on public.food_log for select to authenticated using (auth.uid() = user_id);

create or replace function public.buy_food(p_item text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid(); v_coins int; b public.beer_state;
  price int; points int := 0; v_find int; v_rarity text; r float8;
  became_drunk boolean := false; sober boolean := false;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  price := case p_item when 'pintje' then 1 when 'shotje' then 2 when 'redbull' then 2 when 'kapsalon' then 4 when 'poeder' then 8 end;
  if price is null then raise exception 'Dat staat niet op de kaart.'; end if;

  select polycoins into v_coins from public.user_wallet where user_id = me for update;
  if coalesce(v_coins, 0) < price then raise exception 'Niet genoeg credits.'; end if;
  insert into public.beer_state (user_id) values (me) on conflict do nothing;
  select * into b from public.beer_state where user_id = me for update;

  if p_item in ('pintje', 'shotje') and b.drunk_until > now() then
    raise exception 'Je bent al sterrezat. Even wachten, of eet een kapsalon.';
  end if;
  if p_item = 'poeder' and (select count(*) from public.food_log where user_id = me and item = 'poeder'
        and (created_at at time zone 'Europe/Brussels')::date = (now() at time zone 'Europe/Brussels')::date) >= 3 then
    raise exception 'Genoeg Rizz-poeder voor vandaag. Morgen terug.';
  end if;

  update public.user_wallet set polycoins = polycoins - price where user_id = me returning polycoins into v_coins;

  if p_item in ('pintje', 'shotje') then
    points := case p_item when 'shotje' then 2 else 1 end;
    if b.limit_n is null then b.limit_n := 1 + floor(random() * 5)::int; end if;
    b.pints := b.pints + points;
    if p_item = 'pintje' then b.total := b.total + 1; end if;
    if b.pints >= b.limit_n then
      b.pints := 0; b.limit_n := 1 + floor(random() * 5)::int; b.drunk_until := now() + interval '1 minute';
      became_drunk := true;
    end if;
  elsif p_item = 'kapsalon' then
    sober := b.drunk_until > now() or b.pints > 0;
    b.pints := 0; b.drunk_until := null; b.limit_n := 1 + floor(random() * 5)::int;
  elsif p_item = 'poeder' and random() < 0.125 then
    r := random();
    v_rarity := case when r < 0.05 then 'legendary' when r < 0.30 then 'epic' else 'common' end;
    select id into v_find from public.cards where rarity = v_rarity order by random() limit 1;
    if v_find is not null then insert into public.user_cards (user_id, card_id) values (me, v_find); end if;
  end if;

  update public.beer_state set pints = b.pints, total = b.total, limit_n = b.limit_n, drunk_until = b.drunk_until where user_id = me;
  insert into public.food_log (user_id, item, card_id) values (me, p_item, v_find);
  if became_drunk then insert into public.food_log (user_id, item) values (me, 'zat'); end if;

  return jsonb_build_object('item', p_item, 'wallet', v_coins, 'total', b.total, 'sober', sober,
    'drunk_ms', case when b.drunk_until > now() then (extract(epoch from (b.drunk_until - now())) * 1000)::int else 0 end,
    'find', v_find);
end $$;
grant execute on function public.buy_food(text) to authenticated;

-- Het oude pintje gaat voortaan via dezelfde kaart
create or replace function public.buy_beer() returns jsonb
language sql volatile security definer set search_path = public as $$ select public.buy_food('pintje') $$;
grant execute on function public.buy_beer() to authenticated;

notify pgrst, 'reload schema';
