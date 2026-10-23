-- =====================================================================
-- RIZZ ACADEMY — update 32: Boss Battle-gevechten duren 30 seconden (in plaats van 60)
--
-- - Elk gevecht duurt nu 30 seconden; je speelt er nog altijd 3 per avond.
-- - De HP van de boss gaat mee omlaag: 11.000 per actieve speler (minstens 33.000), nagerekend met een simulatie,
--   zodat het even moeilijk blijft (ongeveer 2 op 3 spelers moeten hun 3 gevechten spelen).
--
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-33-boss-hp-team.sql opnieuw uit.
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- =====================================================================

create or replace function public._boss_hp(p_event bigint) returns int
language plpgsql volatile security definer set search_path = public as $$
declare e public.boss_events; n int;
begin
  select * into e from public.boss_events where id = p_event for update;
  if e.hp_max is not null then return e.hp_max; end if;
  -- spelers die de afgelopen 7 dagen de app open hadden (zonder admin)
  select count(*) into n from public.profiles where last_active > now() - interval '7 days' and not public._is_admin_user(id);
  update public.boss_events set hp_max = coalesce(hp_override, greatest(33000, 11000 * coalesce(n, 0))) where id = p_event
  returning hp_max into n;
  return n;
end $$;
revoke all on function public._boss_hp(bigint) from public, anon, authenticated;

create or replace function public.boss_fight_start(p_cards int[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); e public.boss_events; fid bigint; hp int; team jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if not public._feature_on('boss') then raise exception 'De Boss Battle is nog niet open.'; end if;
  e := public._boss_current();
  if e.id is null or now() < e.starts_at or now() >= e.ends_at then raise exception 'Er is nu geen Boss Battle bezig.'; end if;
  if e.defeated_at is not null then raise exception 'De boss is al verslagen!'; end if;
  if (select count(*) from public.boss_fights where event_id = e.id and user_id = me) >= 3 then
    raise exception 'Je hebt je 3 gevechten van vanavond al gespeeld.';
  end if;
  if p_cards is null or array_length(p_cards, 1) <> 3 or (select count(distinct c) from unnest(p_cards) c) <> 3 then
    raise exception 'Kies 3 verschillende kaarten.';
  end if;
  if not public._is_admin_user(me) and exists (select 1 from unnest(p_cards) c
       where not exists (select 1 from public.user_cards uc where uc.user_id = me and uc.card_id = c)) then
    raise exception 'Je kan enkel kaarten gebruiken die je hebt.';
  end if;
  if exists (select 1 from public.boss_fights f where f.event_id = e.id and f.user_id = me
             and not (f.cards @> p_cards and p_cards @> f.cards)) then
    raise exception 'Je team ligt vast voor vanavond: vecht met dezelfde 3 kaarten.';
  end if;
  update public.boss_fights set ended = true where event_id = e.id and user_id = me and not ended;
  hp := public._boss_hp(e.id);
  insert into public.boss_fights (event_id, user_id, cards) values (e.id, me, p_cards) returning id into fid;
  select jsonb_agg(public._boss_card_power(e, c) order by array_position(p_cards, c.id)) into team
  from public.cards c where c.id = any (p_cards);
  return jsonb_build_object('fight', fid, 'team', team, 'hp_max', hp, 'seconds', 30,
    'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id));
end $$;
grant execute on function public.boss_fight_start(int[]) to authenticated;

create or replace function public.boss_hit(p_fight bigint, p_hits jsonb, p_final boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); f public.boss_fights; e public.boss_events; k text; t int; s int; pw jsonb;
        dmg int := 0; v_taps int := 0; v_sups int := 0; secs numeric; tot int; hp int; killed boolean := false;
begin
  select * into f from public.boss_fights where id = p_fight and user_id = me for update;
  if not found then raise exception 'Gevecht niet gevonden.'; end if;
  select * into e from public.boss_events where id = f.event_id for update;
  if f.ended or e.defeated_at is not null or now() > e.ends_at + interval '1 minute' then
    update public.boss_fights set ended = true where id = f.id;
    return jsonb_build_object('damage', 0, 'total', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id),
      'hp_max', e.hp_max, 'defeated', e.defeated_at is not null, 'ended', true);
  end if;
  for k, t, s in select key, coalesce((value->>0)::int, 0), coalesce((value->>1)::int, 0) from jsonb_each(coalesce(p_hits, '{}'::jsonb)) loop
    if not (k::int = any (f.cards)) or t < 0 or s < 0 then raise exception 'Ongeldige aanval.'; end if;
    select public._boss_card_power(e, c) into pw from public.cards c where c.id = k::int;
    v_taps := v_taps + t; v_sups := v_sups + s;
    dmg := dmg + t * (pw->>'tap')::int + s * (pw->>'super')::int;
  end loop;
  -- niet sneller dan een mens: max. 8 tikken per seconde, één superaanval per 10 tikken, 30 seconden
  secs := least(35, extract(epoch from now() - f.started_at));
  if f.taps + v_taps > secs * 8 + 10 or f.supers + v_sups > floor((f.taps + v_taps) / 10.0) + 1 then
    raise exception 'Te snel getikt.';
  end if;
  update public.boss_fights set taps = taps + v_taps, supers = supers + v_sups, damage = damage + dmg,
    ended = p_final or secs >= 34 where id = f.id;
  if dmg > 0 then insert into public.boss_hits (event_id, user_id, damage, super) values (e.id, me, dmg, v_sups > 0); end if;
  hp := coalesce(e.hp_max, public._boss_hp(e.id));
  select coalesce(sum(damage), 0) into tot from public.boss_fights where event_id = e.id;
  if tot >= hp then
    update public.boss_events set defeated_at = now(), last_hit = me where id = e.id;
    update public.boss_fights set ended = true where event_id = e.id;
    perform public._boss_pay(e.id);
    killed := true;
  end if;
  return jsonb_build_object('damage', dmg, 'total', tot, 'hp_max', hp, 'defeated', killed, 'last_hit', killed,
    'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me),
    'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;
grant execute on function public.boss_hit(bigint, jsonb, boolean) to authenticated;

-- Bosses die nog niet gestart zijn: HP opnieuw laten berekenen bij het eerste gevecht
update public.boss_events b set hp_max = null
where b.starts_at > now() and not exists (select 1 from public.boss_fights f where f.event_id = b.id);

notify pgrst, 'reload schema';
