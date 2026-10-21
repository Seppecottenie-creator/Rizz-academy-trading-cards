-- =====================================================================
-- RIZZ ACADEMY — update 30: de admin mag kaartfoto's vervangen (verkleinen)
--
-- Nodig voor de knop "Kaartfoto's verkleinen" in je account (enkel admin).
-- Die maakt alle foto's in de opslag kleiner (max. 900 px, JPEG), zodat er veel minder
-- verkeer ("Cached Egress") naar Supabase gaat. Spelers kunnen nog altijd enkel kijken.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- =====================================================================

drop policy if exists "kaartfoto's uploaden (admin)" on storage.objects;
create policy "kaartfoto's uploaden (admin)" on storage.objects
  for insert to authenticated with check (bucket_id = 'card-photos' and public.is_admin());

drop policy if exists "kaartfoto's vervangen (admin)" on storage.objects;
create policy "kaartfoto's vervangen (admin)" on storage.objects
  for update to authenticated using (bucket_id = 'card-photos' and public.is_admin())
  with check (bucket_id = 'card-photos' and public.is_admin());
