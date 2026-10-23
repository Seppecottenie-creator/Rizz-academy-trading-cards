-- =====================================================================
-- RIZZ ACADEMY — update 23: na een split mag je altijd verder hitten
--
-- Ook als je twee azen splitst, speel je elke hand gewoon verder: hit, stand of double
-- zo vaak als je wil (vroeger kreeg elke aas maar één kaart).
--
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-35-blackjack-casino-stats.sql opnieuw uit.
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-22-blackjack-split.sql uit.
-- =====================================================================
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
