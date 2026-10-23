-- =====================================================================
-- RIZZ ACADEMY — update 31: de boss blijft geheim tot zondag 20u
--
-- - Vanaf woensdag staat de boss als volledig zwart silhouet op het plein van de campus.
-- - Tot de start krijgt iedereen (ook de admin, op de Boss-pagina) enkel het silhouet te zien:
--   een apart zwart bestand dat de site bij het uploaden maakt. De echte foto is tot zondag 20u
--   niet op te vragen, ook niet via de opslag. Enkel de admin kan hem zien in Beheer.
-- - Bosses die al geüpload waren, krijgen hun silhouet vanzelf zodra de admin de Boss-pagina opent.
--
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-33-boss-hp-team.sql opnieuw uit.
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-34-boss-test.sql opnieuw uit.
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- Voer eerst update-29-boss.sql uit (en voer deze update opnieuw uit als je 29 ooit opnieuw uitvoert).
-- =====================================================================

alter table public.boss_events add column if not exists sil_path text;

-- Welke boss-bestanden mag een speler zien? Silhouetten altijd, de echte foto pas vanaf de start.
create or replace function public._boss_img_visible(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.boss_events
    where sil_path = p_name or (image_path = p_name and starts_at <= now()));
$$;
grant execute on function public._boss_img_visible(text) to authenticated;

drop policy if exists "boss-foto's lezen" on storage.objects;
create policy "boss-foto's lezen" on storage.objects for select to authenticated
  using (bucket_id = 'boss-images' and public._boss_img_visible(name));

-- Silhouet koppelen (de site maakt het bestand bij het uploaden)
create or replace function public.boss_admin_set_sil(p_id bigint, p_path text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  update public.boss_events set sil_path = p_path where id = p_id;
end $$;
grant execute on function public.boss_admin_set_sil(bigint, text) to authenticated;

create or replace function public.boss_admin_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public._is_admin_user(auth.uid()) then coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'starts_at', starts_at, 'ends_at', ends_at, 'name', name, 'title', title, 'image_path', image_path, 'sil_path', sil_path,
    'weakness_kind', weakness_kind, 'weakness_value', weakness_value, 'hp_override', hp_override, 'hp_max', hp_max,
    'defeated_at', defeated_at, 'damage', (select coalesce(sum(damage), 0) from public.boss_fights f where f.event_id = b.id))
    order by starts_at desc) from public.boss_events b where ends_at > now() - interval '30 days'), '[]'::jsonb) end;
$$;
grant execute on function public.boss_admin_list() to authenticated;

-- Status: voor de start geen naam en geen echte foto (ook niet voor de admin), wel het silhouet.
-- teaser_from = woensdag 00u van die week: vanaf dan staat de boss op het plein.
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
    'id', e.id, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'phase', phase, 'defeated_at', e.defeated_at,
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
      'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me))));
end $$;
grant execute on function public.boss_status() to authenticated;

notify pgrst, 'reload schema';
