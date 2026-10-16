-- =====================================================================
-- RIZZ ACADEMY — update 14: casino zonder daglimiet
--
-- Je kan nu zoveel inzetten (en verliezen) als je credits hebt.
-- De inzet blijft per 5, van 5 tot 50 per spel.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-13-casino.sql uit.
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-28-inzet.sql opnieuw uit.
-- =====================================================================

-- Inzet controleren en van de wallet halen (geen daglimiet meer)
create or replace function public._casino_take(p_bet int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet is null or p_bet < 5 or p_bet > 50 or p_bet % 5 <> 0 then raise exception 'Inzet: 5 tot 50 credits, per 5.'; end if;
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid() for update;
  if coalesce(v_coins, 0) < p_bet then raise exception 'Niet genoeg credits.'; end if;
  update public.user_wallet set polycoins = polycoins - p_bet where user_id = auth.uid();
end $$;
revoke all on function public._casino_take(int) from public, anon, authenticated;

-- Stand van zaken: geen limiet meer
create or replace function public.casino_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'wallet', (select polycoins from public.user_wallet where user_id = auth.uid()),
    'lost_today', public._casino_lost_today(auth.uid()),
    'limit', null,
    'bj', (select public._bj_view(h, false) from public.casino_bj h where h.user_id = auth.uid()),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('game', game, 'bet', bet, 'payout', payout) order by id desc)
                        from (select * from public.casino_plays where user_id = auth.uid() order by id desc limit 8) r), '[]'::jsonb)
  ) end;
$$;
grant execute on function public.casino_status() to authenticated;
