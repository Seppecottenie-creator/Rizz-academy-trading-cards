-- =====================================================================
-- RIZZ ACADEMY — update 34: "Test nu" is een test die enkel de admin ziet
--
-- - "Test nu" maakt een tijdelijke kopie van de boss (20 minuten, enkel zichtbaar voor de admin).
--   De echte boss blijft gewoon op zijn zondag staan en blijft voor iedereen een silhouet.
-- - Eenmalige opkuis: bosses die door een vroegere test naar een ander moment verschoven zijn,
--   gaan terug naar de eerstvolgende vrije zondag 20u, en de testschade van de admin wordt gewist.
--
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-36-boss-fix.sql opnieuw uit.
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- Voer eerst update-33-boss-hp-team.sql uit.
-- =====================================================================

alter table public.boss_events add column if not exists is_test boolean not null default false;

-- Huidige boss: spelers zien nooit een test; de admin ziet zijn lopende test
create or replace function public._boss_current() returns public.boss_events
language sql stable security definer set search_path = public as $$
  select * from public.boss_events
  where ends_at > now() - interval '12 hours'
    and (not is_test or (public._is_admin_user(auth.uid()) and ends_at > now()))
  order by (is_test and now() >= starts_at) desc, starts_at
  limit 1;
$$;
revoke all on function public._boss_current() from public, anon, authenticated;

-- De echte foto pas zichtbaar vanaf de echte start (een test telt niet)
create or replace function public._boss_img_visible(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.boss_events
    where sil_path = p_name or (image_path = p_name and starts_at <= now() and not is_test));
$$;
grant execute on function public._boss_img_visible(text) to authenticated;

-- Volgende vrije zondag 20u (tests tellen niet mee)
create or replace function public._boss_next_sunday() returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare d date := (now() at time zone 'Europe/Brussels')::date; t timestamptz;
begin
  d := d + ((7 - extract(dow from d)::int) % 7);
  loop
    t := (d + time '20:00') at time zone 'Europe/Brussels';
    if t > now() and not exists (select 1 from public.boss_events where not is_test
                                 and abs(extract(epoch from starts_at - t)) < 86400) then return t; end if;
    d := d + 7;
  end loop;
end $$;
revoke all on function public._boss_next_sunday() from public, anon, authenticated;

-- Test nu: kopie van 20 minuten, enkel voor de admin
create or replace function public.boss_admin_test(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare b public.boss_events;
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  select * into b from public.boss_events where id = p_id;
  if not found then raise exception 'Boss niet gevonden.'; end if;
  delete from public.boss_events where is_test;   -- oude tests weg (met hun gevechten)
  insert into public.boss_events (starts_at, ends_at, name, title, image_path, sil_path, weakness_kind, weakness_value, hp_override, is_test)
  values (now(), now() + interval '20 minutes', b.name, b.title, b.image_path, b.sil_path, b.weakness_kind, b.weakness_value, b.hp_override, true);
end $$;
grant execute on function public.boss_admin_test(bigint) to authenticated;

-- Lijst in Beheer: zonder tests
create or replace function public.boss_admin_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public._is_admin_user(auth.uid()) then coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'starts_at', starts_at, 'ends_at', ends_at, 'name', name, 'title', title, 'image_path', image_path, 'sil_path', sil_path,
    'weakness_kind', weakness_kind, 'weakness_value', weakness_value, 'hp_override', hp_override, 'hp_max', hp_max,
    'defeated_at', defeated_at, 'damage', (select coalesce(sum(damage), 0) from public.boss_fights f where f.event_id = b.id))
    order by starts_at desc) from public.boss_events b where not is_test and ends_at > now() - interval '30 days'), '[]'::jsonb) end;
$$;
grant execute on function public.boss_admin_list() to authenticated;

-- Status: met 'is_test' (de site toont dan een TEST-label voor de admin)
create or replace function public.boss_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e public.boss_events; me uuid := auth.uid(); adm boolean; phase text; dmg int; hp int; reveal boolean;
begin
  if me is null or not public._feature_on('boss') then return null; end if;
  adm := public._is_admin_user(me);
  e := public._boss_current();
  if e.id is null then return jsonb_build_object('now', now(), 'is_admin', adm, 'event', null); end if;
  phase := case when e.defeated_at is not null then 'defeated' when now() < e.starts_at then 'upcoming'
                when now() < e.ends_at then 'live' else 'ended' end;
  reveal := phase <> 'upcoming';
  select coalesce(sum(damage), 0) into dmg from public.boss_fights where event_id = e.id;
  hp := coalesce(e.hp_max, e.hp_override);
  return jsonb_build_object('now', now(), 'is_admin', adm, 'event', jsonb_build_object(
    'id', e.id, 'is_test', e.is_test, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'phase', phase, 'defeated_at', e.defeated_at,
    'teaser_from', ((e.starts_at at time zone 'Europe/Brussels')::date - 4)::timestamp at time zone 'Europe/Brussels',
    'name', case when reveal then e.name end, 'title', case when reveal then e.title end,
    'image_path', case when reveal then e.image_path end, 'sil_path', e.sil_path,
    'weakness_kind', e.weakness_kind, 'weakness_value', e.weakness_value,
    'hp_max', hp, 'damage', dmg,
    'players', (select count(distinct user_id) from public.boss_fights f where f.event_id = e.id),
    'last_hit', (select display_name from public.profiles where id = e.last_hit),
    'top', coalesce((select jsonb_agg(x order by x.dmg desc) from (
       select coalesce(p.display_name, '?') as name, sum(f.damage)::int as dmg, f.user_id = me as me from public.boss_fights f
       left join public.profiles p on p.id = f.user_id
       where f.event_id = e.id and (adm or not public._is_admin_user(f.user_id)) group by f.user_id, p.display_name
       having sum(f.damage) > 0 order by sum(f.damage) desc limit 5) x), '[]'::jsonb),
    'my', jsonb_build_object(
      'fights', (select count(*) from public.boss_fights where event_id = e.id and user_id = me),
      'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id and user_id = me),
      'used', coalesce((select jsonb_agg(distinct c) from public.boss_fights f, unnest(f.cards) c where f.event_id = e.id and f.user_id = me), '[]'::jsonb),
      'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me),
      'team_hp', (select card_hp from public.boss_fights where event_id = e.id and user_id = me and card_hp is not null order by id desc limit 1))));
end $$;
grant execute on function public.boss_status() to authenticated;

-- Eenmalige opkuis: verschoven bosses (niet op zondag 20u) waar enkel de admin tegen vocht -> terug naar een vrije zondag
do $$
declare r record; t timestamptz;
begin
  for r in select id from public.boss_events
           where not is_test and (
             extract(dow from starts_at at time zone 'Europe/Brussels') <> 0
             or (starts_at at time zone 'Europe/Brussels')::time <> time '20:00')
             and not exists (select 1 from public.boss_fights f where f.event_id = boss_events.id and not public._is_admin_user(f.user_id))
           order by id loop
    update public.boss_events set starts_at = now() + interval '100 years', ends_at = now() + interval '100 years 1 hour' where id = r.id;
    t := public._boss_next_sunday();
    delete from public.boss_fights where event_id = r.id;
    delete from public.boss_hits where event_id = r.id;
    delete from public.boss_rewards where event_id = r.id;
    update public.boss_events set starts_at = t, ends_at = t + interval '1 hour', hp_max = null, defeated_at = null, last_hit = null, paid = false
    where id = r.id;
  end loop;
end $$;

-- Overzicht na de opkuis
select to_char(starts_at at time zone 'Europe/Brussels', 'Dy DD/MM HH24:MI') as wanneer, name, image_path is not null as foto, sil_path is not null as silhouet
from public.boss_events where not is_test order by starts_at;

notify pgrst, 'reload schema';
