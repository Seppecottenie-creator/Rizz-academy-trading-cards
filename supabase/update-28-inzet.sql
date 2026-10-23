-- =====================================================================
-- RIZZ ACADEMY — update 28: in het casino kan je ook 1 of 2 credits inzetten
--
-- Toegelaten inzet: 1, 2, 5, 10, 15, ... tot 50 credits per spel (en in het Sportsbook).
-- Eerlijke afronding bij 1 of 2 credits: 0,4× op 1 credit wordt in 40% van de keren 1 credit (anders 0),
-- 2,7× op 1 credit wordt in 70% van de keren 3 (anders 2). Gemiddeld krijg je dus exact de quotering.
-- Vanaf 5 credits blijft alles zoals het was (naar beneden afgerond).
-- TESTFASE: 1 en 2 credits kan eerst enkel de admin (release-16-oktober.sql zet het open).
--
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-35-blackjack-casino-stats.sql opnieuw uit.
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-14-casino-zonder-limiet.sql en update-25-foodtruck.sql uit.
-- =====================================================================

create or replace function public._casino_take(p_bet int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet is null or p_bet < 1 or p_bet > 50 or (p_bet > 2 and p_bet % 5 <> 0)
     or (p_bet < 5 and not public._feature_on('smallbets')) then
    raise exception '%', case when public._feature_on('smallbets') then 'Inzet: 1, 2, of 5 tot 50 credits per 5.' else 'Inzet: 5 tot 50 credits, per 5.' end;
  end if;
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid() for update;
  if coalesce(v_coins, 0) < p_bet then raise exception 'Niet genoeg credits.'; end if;
  update public.user_wallet set polycoins = polycoins - p_bet where user_id = auth.uid();
end $$;
revoke all on function public._casino_take(int) from public, anon, authenticated;

-- Uitbetaling afronden: vanaf 5 credits naar beneden, bij 1 of 2 credits eerlijk (kans = het stukje na de komma)
create or replace function public._casino_round(p_bet int, p_amount numeric) returns int
language sql volatile as $$
  select case when p_bet >= 5 then floor(p_amount)::int else floor(p_amount + random())::int end;
$$;
revoke all on function public._casino_round(int, numeric) from public, anon, authenticated;

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
  return public._casino_pay('slots', p_bet, public._casino_round(p_bet, p_bet * mult), jsonb_build_object('reels', jsonb_build_array(a, b, c), 'mult', mult));
end $$;
grant execute on function public.casino_slots(int) to authenticated;

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
  select array_agg(x order by random()) into others from generate_series(1, 5) x where x <> winner;
  return public._casino_pay('horses', p_bet, public._casino_round(p_bet, p_bet * mult),
    jsonb_build_object('winner', winner, 'order', to_jsonb(array[winner] || others), 'pick', p_horse, 'mult', mult));
end $$;
grant execute on function public.casino_horses(int, int) to authenticated;

-- Blackjack: 3 tegen 2 (2,5× terug) bij 1 credit = 2 of 3, eerlijk afgerond
create or replace function public._bj_payout(p_outcome text, p_bet int) returns int
language sql volatile as $$
  select case p_outcome when 'blackjack' then public._casino_round(p_bet, p_bet * 2.5) when 'win' then p_bet * 2 when 'push' then p_bet else 0 end;
$$;

notify pgrst, 'reload schema';
