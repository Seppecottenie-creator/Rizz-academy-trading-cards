-- =====================================================================
-- RIZZ ACADEMY — update 22: splitsen bij blackjack (casino)
--
-- Heb je twee kaarten met dezelfde waarde (bv. 8 + 8, of heer + 10)? Dan kan je splitsen:
-- je zet nog eens dezelfde inzet in en speelt twee aparte handen tegen de dealer.
-- - Je speelt eerst hand 1, daarna hand 2 (hit, stand of double per hand).
-- - (Azen: zie update 23 — ook daar mag je na een split gewoon verder hitten.)
-- - 21 na een split telt als gewone winst (2×), niet als blackjack.
-- - Eén keer splitsen per hand.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-14-casino-zonder-limiet.sql uit.
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-28-inzet.sql opnieuw uit.
-- =====================================================================

-- Tweede hand bij een split
alter table public.casino_bj add column if not exists hand2 int[];
alter table public.casino_bj add column if not exists bet2 int;
alter table public.casino_bj add column if not exists active int not null default 1;

-- Waarde van één kaart (aas = 11, boer/dame/heer = 10)
create or replace function public._bj_card(p_card int) returns int
language sql immutable as $$
  select case when p_card % 13 = 0 then 11 when p_card % 13 >= 9 then 10 else p_card % 13 + 1 end;
$$;

-- Wat de speler mag zien (de verborgen kaart van de dealer enkel na afloop)
create or replace function public._bj_view(h public.casino_bj, p_done boolean) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'bet', h.bet + coalesce(h.bet2, 0), 'bet1', h.bet, 'bet2', h.bet2,
    'player', to_jsonb(h.player), 'player_total', public._bj_value(h.player),
    'player2', to_jsonb(h.hand2), 'player2_total', case when h.hand2 is null then null else public._bj_value(h.hand2) end,
    'active', h.active,
    'dealer', case when p_done then to_jsonb(h.dealer) else to_jsonb(array[h.dealer[1]]) end,
    'dealer_total', case when p_done then public._bj_value(h.dealer) else public._bj_value(array[h.dealer[1]]) end,
    'can_double', not p_done and array_length(case when h.active = 2 then h.hand2 else h.player end, 1) = 2,
    'can_split', not p_done and h.hand2 is null and array_length(h.player, 1) = 2
                 and public._bj_card(h.player[1]) = public._bj_card(h.player[2]),
    'done', p_done);
$$;

-- Uitkomst van één hand
create or replace function public._bj_outcome(p_cards int[], p_dealer int[], p_split boolean) returns text
language plpgsql immutable as $$
declare pt int := public._bj_value(p_cards); dt int := public._bj_value(p_dealer);
begin
  if pt > 21 then return 'bust'; end if;
  if pt = 21 and array_length(p_cards, 1) = 2 and not p_split
     and not (dt = 21 and array_length(p_dealer, 1) = 2) then return 'blackjack'; end if;
  if dt > 21 or pt > dt then return 'win'; end if;
  if pt = dt then return 'push'; end if;
  return 'lose';
end $$;

create or replace function public._bj_payout(p_outcome text, p_bet int) returns int
language sql immutable as $$
  select case p_outcome when 'blackjack' then floor(p_bet * 2.5)::int when 'win' then p_bet * 2 when 'push' then p_bet else 0 end;
$$;

-- Hand afronden: dealer speelt, uitbetalen, hand weg
create or replace function public._bj_finish(h public.casino_bj, p_dealer_plays boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare o1 text; o2 text; pay int; split boolean := h.hand2 is not null;
begin
  if p_dealer_plays and (public._bj_value(h.player) <= 21 or (split and public._bj_value(h.hand2) <= 21)) then
    while public._bj_value(h.dealer) < 17 loop
      h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:];
    end loop;
  end if;
  o1 := public._bj_outcome(h.player, h.dealer, split);
  pay := public._bj_payout(o1, h.bet);
  if split then
    o2 := public._bj_outcome(h.hand2, h.dealer, true);
    pay := pay + public._bj_payout(o2, h.bet2);
  end if;
  delete from public.casino_bj where user_id = h.user_id;
  return public._casino_pay('blackjack', h.bet + coalesce(h.bet2, 0), pay,
    public._bj_view(h, true) || jsonb_build_object('outcome', o1, 'outcome2', o2));
end $$;
revoke all on function public._bj_finish(public.casino_bj, boolean) from public, anon, authenticated;

-- Naar de volgende hand, of de dealer laten spelen
create or replace function public._bj_next(h public.casino_bj) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if h.active = 1 and h.hand2 is not null then
    h.active := 2;
    update public.casino_bj set active = 2 where user_id = h.user_id;
    if public._bj_value(h.hand2) >= 21 then return public._bj_finish(h, true); end if;
    return public._bj_view(h, false);
  end if;
  return public._bj_finish(h, true);
end $$;
revoke all on function public._bj_next(public.casino_bj) from public, anon, authenticated;

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
    if public._bj_value(cur) >= 21 then return public._bj_next(h); end if;
    return public._bj_view(h, false);

  elsif p_action = 'stand' then
    return public._bj_next(h);

  elsif p_action = 'double' then
    if array_length(cur, 1) <> 2 then raise exception 'Verdubbelen kan enkel met je eerste twee kaarten.'; end if;
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

notify pgrst, 'reload schema';
