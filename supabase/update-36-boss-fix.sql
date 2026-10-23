-- =====================================================================
-- RIZZ ACADEMY — update 36: boss terug zichtbaar (opkuis na testen)
--
-- - Een boss die door een vroegere test op een ander moment dan zondag 20u staat, gaat terug naar
--   de eerstvolgende vrije zondag 20u (ook als er toen al iemand meevocht; die gevechten worden gewist).
-- - Een voorbije boss blokkeert de volgende niet meer, tenzij er echt spelers tegen vochten
--   (dan zie je nog 12 uur de uitslag, zoals zondagavond na 21u).
-- - Onderaan: een overzicht van al je bosses.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- =====================================================================

create or replace function public._boss_current() returns public.boss_events
language sql stable security definer set search_path = public as $$
  select * from public.boss_events b
  where (not b.is_test or (public._is_admin_user(auth.uid()) and b.ends_at > now()))
    and (b.ends_at > now()
         or (b.ends_at > now() - interval '12 hours' and not b.is_test
             and exists (select 1 from public.boss_fights f where f.event_id = b.id and not public._is_admin_user(f.user_id))))
  order by (b.is_test and now() >= b.starts_at) desc, b.starts_at
  limit 1;
$$;
revoke all on function public._boss_current() from public, anon, authenticated;

-- Opkuis: oude tests weg, verdwaalde bosses terug naar een vrije zondag 20u
delete from public.boss_events where is_test and ends_at < now();
do $$
declare r record; t timestamptz;
begin
  for r in select id from public.boss_events
           where not is_test and (
             extract(dow from starts_at at time zone 'Europe/Brussels') <> 0
             or (starts_at at time zone 'Europe/Brussels')::time <> time '20:00')
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

-- Overzicht
select to_char(starts_at at time zone 'Europe/Brussels', 'Dy DD/MM HH24:MI') as wanneer, name,
       image_path is not null as foto, sil_path is not null as silhouet,
       case when now() < starts_at then 'komt nog' when now() < ends_at then 'BEZIG' else 'voorbij' end as status,
       (select released from public.feature_flags where key = 'boss') as open_voor_iedereen
from public.boss_events where not is_test order by starts_at;

notify pgrst, 'reload schema';
