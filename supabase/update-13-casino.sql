-- =====================================================================
-- RIZZ ACADEMY — update 13: het casino
-- LET OP: voer je dit bestand opnieuw uit, voer daarna ook update-14 en update-22 opnieuw uit
-- (anders komt de daglimiet terug en verdwijnt splitsen bij blackjack).
--
-- Vier spelletjes waarin je je credits inzet, telkens per 5 (min. 5, max. 50 per spel):
--   Slotmachine · Roulette · Paardenrace · Blackjack
-- Alle uitkomsten worden HIER op de server getrokken: de website toont enkel het resultaat.
-- Daglimiet: je kan per dag (Belgische tijd) netto max. 100 credits verliezen in het casino.
-- Het huis wint gemiddeld een klein beetje (slots ±90%, roulette ±97%, paarden ±92% terug).
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
-- =====================================================================

-- 1. Tabellen ---------------------------------------------------------------------------------
create table if not exists public.casino_plays (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  game text not null,
  bet int not null,
  payout int not null default 0,
  result jsonb,
  play_date date not null default (now() at time zone 'Europe/Brussels')::date,
  created_at timestamptz not null default now()
);
create index if not exists casino_plays_user_day_idx on public.casino_plays (user_id, play_date);
alter table public.casino_plays enable row level security;
drop policy if exists "eigen casinospelletjes lezen" on public.casino_plays;
create policy "eigen casinospelletjes lezen" on public.casino_plays for select to authenticated using (auth.uid() = user_id);

-- Lopende blackjack-hand (één per speler). Het kaartspel blijft op de server.
create table if not exists public.casino_bj (
  user_id uuid primary key references auth.users(id) on delete cascade,
  bet int not null,
  deck int[] not null,
  player int[] not null,
  dealer int[] not null,
  created_at timestamptz not null default now()
);
alter table public.casino_bj enable row level security; -- geen policies: enkel via de functies

-- 2. Hulpfuncties -----------------------------------------------------------------------------------
create or replace function public._casino_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Brussels')::date $$;

-- Netto verlies vandaag (inclusief de inzet van een lopende blackjack-hand)
create or replace function public._casino_lost_today(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(bet - payout) from public.casino_plays where user_id = p_user and play_date = public._casino_today()), 0)::int
       + coalesce((select bet from public.casino_bj where user_id = p_user), 0);
$$;

-- Inzet controleren en van de wallet halen
create or replace function public._casino_take(p_bet int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet is null or p_bet < 5 or p_bet > 50 or p_bet % 5 <> 0 then raise exception 'Inzet: 5 tot 50 credits, per 5.'; end if;
  if public._casino_lost_today(auth.uid()) + p_bet > 100 then
    raise exception 'Daglimiet bereikt: je kan vandaag niet meer dan 100 credits verliezen in het casino. Morgen weer open.';
  end if;
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid() for update;
  if coalesce(v_coins, 0) < p_bet then raise exception 'Niet genoeg credits.'; end if;
  update public.user_wallet set polycoins = polycoins - p_bet where user_id = auth.uid();
end $$;
revoke all on function public._casino_take(int) from public, anon, authenticated;

-- Uitbetalen en het spel bijhouden; geeft de nieuwe stand terug
create or replace function public._casino_pay(p_game text, p_bet int, p_payout int, p_result jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if p_payout > 0 then update public.user_wallet set polycoins = polycoins + p_payout where user_id = auth.uid(); end if;
  insert into public.casino_plays (user_id, game, bet, payout, result) values (auth.uid(), p_game, p_bet, p_payout, p_result);
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid();
  return p_result || jsonb_build_object('bet', p_bet, 'payout', p_payout, 'wallet', v_coins, 'lost_today', public._casino_lost_today(auth.uid()));
end $$;
revoke all on function public._casino_pay(text, int, int, jsonb) from public, anon, authenticated;

-- 3. Slotmachine -------------------------------------------------------------------------------------
-- Symbolen per rol (gewicht): C kers 30 · L citroen 25 · B bel 18 · D diamant 13 · K kroon 9 · R RIZZ 5
-- 3 gelijk: RIZZ 60× · kroon 25× · diamant 15× · bel 10× · citroen 6× · kers 5×
-- 2 kersen: 2× · 1 kers: 0,4× (afgerond naar beneden)
create or replace function public._casino_reel() returns text
language sql volatile as $$
  select case when r < 30 then 'C' when r < 55 then 'L' when r < 73 then 'B' when r < 86 then 'D' when r < 95 then 'K' else 'R' end
  from (select floor(random() * 100)::int as r) x;
$$;

create or replace function public.casino_slots(p_bet int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a text; b text; c text; n int; mult numeric := 0;
begin
  perform public._casino_take(p_bet);
  a := public._casino_reel(); b := public._casino_reel(); c := public._casino_reel();
  n := (a = 'C')::int + (b = 'C')::int + (c = 'C')::int;
  if a = b and b = c then
    mult := case a when 'R' then 60 when 'K' then 25 when 'D' then 15 when 'B' then 10 when 'L' then 6 else 5 end;
  elsif n = 2 then mult := 2;
  elsif n = 1 then mult := 0.4;
  end if;
  return public._casino_pay('slots', p_bet, floor(p_bet * mult)::int, jsonb_build_object('reels', jsonb_build_array(a, b, c), 'mult', mult));
end $$;
grant execute on function public.casino_slots(int) to authenticated;

-- 4. Roulette (Europees: 0 tot 36) --------------------------------------------------------------------
-- red/black/even/odd/low (1-18)/high (19-36): 2× terug · één getal: 36× terug · 0 = huis wint de rest
create or replace function public.casino_roulette(p_bet int, p_kind text, p_number int default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int; red boolean; win boolean; mult int;
begin
  if p_kind not in ('red', 'black', 'even', 'odd', 'low', 'high', 'number') then raise exception 'Onbekende inzet.'; end if;
  if p_kind = 'number' and (p_number is null or p_number < 0 or p_number > 36) then raise exception 'Kies een getal van 0 tot 36.'; end if;
  perform public._casino_take(p_bet);
  n := floor(random() * 37)::int;
  red := n = any (array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
  win := case p_kind
    when 'red' then n > 0 and red when 'black' then n > 0 and not red
    when 'even' then n > 0 and n % 2 = 0 when 'odd' then n % 2 = 1
    when 'low' then n between 1 and 18 when 'high' then n between 19 and 36
    else n = p_number end;
  mult := case when not win then 0 when p_kind = 'number' then 36 else 2 end;
  return public._casino_pay('roulette', p_bet, p_bet * mult,
    jsonb_build_object('number', n, 'color', case when n = 0 then 'green' when red then 'red' else 'black' end, 'kind', p_kind, 'pick', p_number, 'win', win));
end $$;
grant execute on function public.casino_roulette(int, text, int) to authenticated;

-- 5. Paardenrace --------------------------------------------------------------------------------------
-- 5 paarden met vaste kansen; uitbetaling = inzet × quotering (afgerond naar beneden)
create or replace function public.casino_horses_odds() returns jsonb
language sql immutable as $$
  select '[{"n":1,"name":"Thunder Rizz","p":34,"x":2.7},{"n":2,"name":"Lucky Legend","p":25,"x":3.6},{"n":3,"name":"Midnight Aura","p":18,"x":5.1},{"n":4,"name":"Dean''s Pick","p":14,"x":6.5},{"n":5,"name":"Last Call","p":9,"x":10.2}]'::jsonb;
$$;
grant execute on function public.casino_horses_odds() to authenticated;

create or replace function public.casino_horses(p_bet int, p_horse int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r int; acc int := 0; h jsonb; winner int; mult numeric := 0; others int[];
begin
  if p_horse not between 1 and 5 then raise exception 'Kies een paard van 1 tot 5.'; end if;
  perform public._casino_take(p_bet);
  r := floor(random() * 100)::int;
  for h in select * from jsonb_array_elements(public.casino_horses_odds()) loop
    acc := acc + (h->>'p')::int;
    if winner is null and r < acc then winner := (h->>'n')::int; if winner = p_horse then mult := (h->>'x')::numeric; end if; end if;
  end loop;
  -- Volgorde van de rest willekeurig (voor de animatie)
  select array_agg(x order by random()) into others from generate_series(1, 5) x where x <> winner;
  return public._casino_pay('horses', p_bet, floor(p_bet * mult)::int,
    jsonb_build_object('winner', winner, 'order', to_jsonb(array[winner] || others), 'pick', p_horse, 'mult', mult));
end $$;
grant execute on function public.casino_horses(int, int) to authenticated;

-- 6. Blackjack ----------------------------------------------------------------------------------------
-- Kaarten 0..51: rang = kaart % 13 (0 = aas, 1..9 = 2..10, 10..12 = boer/dame/heer)
-- Dealer pakt tot 17. Winst 2× terug, blackjack 2,5× (naar beneden), gelijk = inzet terug.
create or replace function public._bj_value(p_cards int[]) returns int
language plpgsql immutable as $$
declare t int := 0; aces int := 0; r int; c int;
begin
  foreach c in array p_cards loop
    r := c % 13;
    if r = 0 then aces := aces + 1; t := t + 11;
    elsif r >= 9 then t := t + 10;
    else t := t + r + 1; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end $$;

-- Wat de speler mag zien (de verborgen kaart van de dealer enkel na afloop)
create or replace function public._bj_view(h public.casino_bj, p_done boolean) returns jsonb
language sql immutable as $$
  select jsonb_build_object('bet', h.bet, 'player', to_jsonb(h.player), 'player_total', public._bj_value(h.player),
    'dealer', case when p_done then to_jsonb(h.dealer) else to_jsonb(array[h.dealer[1]]) end,
    'dealer_total', case when p_done then public._bj_value(h.dealer) else public._bj_value(array[h.dealer[1]]) end,
    'can_double', not p_done and array_length(h.player, 1) = 2, 'done', p_done);
$$;

-- Hand afronden: dealer speelt, uitbetalen, hand weg
create or replace function public._bj_finish(h public.casino_bj, p_dealer_plays boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare pt int; dt int; outcome text; pay int;
begin
  pt := public._bj_value(h.player);
  if p_dealer_plays and pt <= 21 then
    while public._bj_value(h.dealer) < 17 loop
      h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:];
    end loop;
  end if;
  dt := public._bj_value(h.dealer);
  if pt > 21 then outcome := 'bust';
  elsif pt = 21 and array_length(h.player, 1) = 2 and not (dt = 21 and array_length(h.dealer, 1) = 2) then outcome := 'blackjack';
  elsif dt > 21 or pt > dt then outcome := 'win';
  elsif pt = dt then outcome := 'push';
  else outcome := 'lose'; end if;
  pay := case outcome when 'blackjack' then floor(h.bet * 2.5)::int when 'win' then h.bet * 2 when 'push' then h.bet else 0 end;
  delete from public.casino_bj where user_id = h.user_id;
  return public._casino_pay('blackjack', h.bet, pay, public._bj_view(h, true) || jsonb_build_object('outcome', outcome));
end $$;
revoke all on function public._bj_finish(public.casino_bj, boolean) from public, anon, authenticated;

create or replace function public.casino_bj_start(p_bet int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h public.casino_bj; deck int[];
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  select * into h from public.casino_bj where user_id = auth.uid();
  if found then return public._bj_view(h, false) || jsonb_build_object('resumed', true); end if; -- verder met de lopende hand
  perform public._casino_take(p_bet);
  select array_agg(x order by random()) into deck from generate_series(0, 51) x;
  insert into public.casino_bj (user_id, bet, deck, player, dealer)
  values (auth.uid(), p_bet, deck[5:], array[deck[1], deck[3]], array[deck[2], deck[4]])
  returning * into h;
  if public._bj_value(h.player) = 21 or public._bj_value(h.dealer) = 21 then return public._bj_finish(h, false); end if;
  return public._bj_view(h, false);
end $$;
grant execute on function public.casino_bj_start(int) to authenticated;

create or replace function public.casino_bj_action(p_action text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h public.casino_bj;
begin
  select * into h from public.casino_bj where user_id = auth.uid() for update;
  if not found then raise exception 'Er loopt geen hand.'; end if;
  if p_action = 'hit' then
    h.player := h.player || h.deck[1]; h.deck := h.deck[2:];
    update public.casino_bj set player = h.player, deck = h.deck where user_id = h.user_id;
    if public._bj_value(h.player) >= 21 then return public._bj_finish(h, true); end if;
    return public._bj_view(h, false);
  elsif p_action = 'stand' then
    return public._bj_finish(h, true);
  elsif p_action = 'double' then
    if array_length(h.player, 1) <> 2 then raise exception 'Verdubbelen kan enkel met je eerste twee kaarten.'; end if;
    -- extra inzet: zelfde controle als een nieuwe inzet (de lopende inzet telt al mee in de daglimiet)
    perform public._casino_take(h.bet);
    h.bet := h.bet * 2;
    h.player := h.player || h.deck[1]; h.deck := h.deck[2:];
    update public.casino_bj set bet = h.bet, player = h.player, deck = h.deck where user_id = h.user_id;
    return public._bj_finish(h, true);
  end if;
  raise exception 'Onbekende actie.';
end $$;
grant execute on function public.casino_bj_action(text) to authenticated;

-- 7. Stand van zaken voor de casinopagina ---------------------------------------------------------------
create or replace function public.casino_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'wallet', (select polycoins from public.user_wallet where user_id = auth.uid()),
    'lost_today', public._casino_lost_today(auth.uid()),
    'limit', 100,
    'bj', (select public._bj_view(h, false) from public.casino_bj h where h.user_id = auth.uid()),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('game', game, 'bet', bet, 'payout', payout) order by id desc)
                        from (select * from public.casino_plays where user_id = auth.uid() order by id desc limit 8) r), '[]'::jsonb)
  ) end;
$$;
grant execute on function public.casino_status() to authenticated;
