-- =====================================================================
-- RIZZ ACADEMY — update 35: blackjack-regels en casinostatistieken
--
-- Blackjack (casino):
-- - Verdubbelen kan altijd, niet enkel met je eerste twee kaarten. Je inzet verdubbelt,
--   je krijgt nog precies 1 kaart en daarna stopt die hand.
-- - 6 kaarten zonder over 21 te gaan = gewonnen (2× je inzet), wat de dealer ook heeft.
-- Casino:
-- - casino_stats(): je volledige casinogeschiedenis in cijfers (per spel, beste/slechtste dag, verloop).
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- Voer eerst update-22, 23 en 28 uit (en deze opnieuw als je een van die ooit opnieuw uitvoert).
-- =====================================================================

-- Wat de speler mag zien: verdubbelen kan altijd zolang de hand loopt
create or replace function public._bj_view(h public.casino_bj, p_done boolean) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'bet', h.bet + coalesce(h.bet2, 0), 'bet1', h.bet, 'bet2', h.bet2,
    'player', to_jsonb(h.player), 'player_total', public._bj_value(h.player),
    'player2', to_jsonb(h.hand2), 'player2_total', case when h.hand2 is null then null else public._bj_value(h.hand2) end,
    'active', h.active,
    'dealer', case when p_done then to_jsonb(h.dealer) else to_jsonb(array[h.dealer[1]]) end,
    'dealer_total', case when p_done then public._bj_value(h.dealer) else public._bj_value(array[h.dealer[1]]) end,
    'can_double', not p_done,
    'can_split', not p_done and h.hand2 is null and array_length(h.player, 1) = 2
                 and public._bj_card(h.player[1]) = public._bj_card(h.player[2]),
    'done', p_done);
$$;

-- Uitkomst van één hand: 6 kaarten zonder bust = gewonnen ('charlie')
create or replace function public._bj_outcome(p_cards int[], p_dealer int[], p_split boolean) returns text
language plpgsql immutable as $$
declare pt int := public._bj_value(p_cards); dt int := public._bj_value(p_dealer);
begin
  if pt > 21 then return 'bust'; end if;
  if array_length(p_cards, 1) >= 6 then return 'charlie'; end if;
  if pt = 21 and array_length(p_cards, 1) = 2 and not p_split
     and not (dt = 21 and array_length(p_dealer, 1) = 2) then return 'blackjack'; end if;
  if dt > 21 or pt > dt then return 'win'; end if;
  if pt = dt then return 'push'; end if;
  return 'lose';
end $$;

create or replace function public._bj_payout(p_outcome text, p_bet int) returns int
language sql volatile as $$
  select case p_outcome when 'blackjack' then public._casino_round(p_bet, p_bet * 2.5)
                        when 'win' then p_bet * 2 when 'charlie' then p_bet * 2 when 'push' then p_bet else 0 end;
$$;

create or replace function public.casino_bj_action(p_action text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h public.casino_bj; cur int[];
begin
  select * into h from public.casino_bj where user_id = auth.uid() for update;
  if not found then raise exception 'Er loopt geen hand.'; end if;
  cur := case when h.active = 2 then h.hand2 else h.player end;

  if p_action = 'hit' then
    cur := cur || h.deck[1]; h.deck := h.deck[2:];
    if h.active = 2 then h.hand2 := cur; else h.player := cur; end if;
    update public.casino_bj set player = h.player, hand2 = h.hand2, deck = h.deck where user_id = h.user_id;
    -- over 21, precies 21, of 6 kaarten: deze hand is klaar
    if public._bj_value(cur) >= 21 or array_length(cur, 1) >= 6 then return public._bj_next(h); end if;
    return public._bj_view(h, false);

  elsif p_action = 'stand' then
    return public._bj_next(h);

  elsif p_action = 'double' then
    -- altijd mogelijk: inzet ×2, nog precies 1 kaart, dan stopt de hand
    if h.active = 2 then
      perform public._casino_take(h.bet2); h.bet2 := h.bet2 * 2;
      h.hand2 := h.hand2 || h.deck[1];
    else
      perform public._casino_take(h.bet); h.bet := h.bet * 2;
      h.player := h.player || h.deck[1];
    end if;
    h.deck := h.deck[2:];
    update public.casino_bj set bet = h.bet, bet2 = h.bet2, player = h.player, hand2 = h.hand2, deck = h.deck where user_id = h.user_id;
    return public._bj_next(h);

  elsif p_action = 'split' then
    if h.hand2 is not null or array_length(h.player, 1) <> 2
       or public._bj_card(h.player[1]) <> public._bj_card(h.player[2]) then
      raise exception 'Splitsen kan enkel met twee kaarten van dezelfde waarde.';
    end if;
    perform public._casino_take(h.bet);
    h.bet2 := h.bet;
    h.hand2 := array[h.player[2], h.deck[2]];
    h.player := array[h.player[1], h.deck[1]];
    h.deck := h.deck[3:];
    h.active := 1;
    update public.casino_bj set bet2 = h.bet2, player = h.player, hand2 = h.hand2, deck = h.deck, active = 1 where user_id = h.user_id;
    if public._bj_value(h.player) = 21 then return public._bj_next(h); end if;
    return public._bj_view(h, false);
  end if;
  raise exception 'Onbekende actie.';
end $$;
grant execute on function public.casino_bj_action(text) to authenticated;

-- Je volledige casinogeschiedenis in cijfers
create or replace function public.casino_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  with p as (
    select game, bet, payout, payout - bet as net, (created_at at time zone 'Europe/Brussels')::date as d
    from public.casino_plays where user_id = auth.uid()
  ), g as (
    select game, count(*) as n, sum(bet) as bet, sum(payout) as payout, sum(net) as net,
           count(*) filter (where net > 0) as wins, max(net) as best
    from p group by game
  ), dd as (select d, sum(net) as net, count(*) as n from p group by d)
  select case when auth.uid() is null then null else jsonb_build_object(
    'total', (select jsonb_build_object('n', count(*), 'bet', coalesce(sum(bet), 0), 'payout', coalesce(sum(payout), 0),
                     'net', coalesce(sum(net), 0), 'wins', count(*) filter (where net > 0), 'best', max(net),
                     'first', min(d), 'days', count(distinct d)) from p),
    'games', coalesce((select jsonb_agg(jsonb_build_object('game', game, 'n', n, 'bet', bet, 'payout', payout, 'net', net,
                     'wins', wins, 'best', best) order by n desc) from g), '[]'::jsonb),
    'best_day', (select jsonb_build_object('d', d, 'net', net) from dd order by net desc, d desc limit 1),
    'worst_day', (select jsonb_build_object('d', d, 'net', net) from dd order by net, d desc limit 1),
    'days', coalesce((select jsonb_agg(jsonb_build_object('d', d, 'net', net, 'n', n) order by d) from dd), '[]'::jsonb)
  ) end;
$$;
grant execute on function public.casino_stats() to authenticated;

notify pgrst, 'reload schema';
