-- =====================================================================
-- RIZZ ACADEMY — update 02: afgeschermde kaartfoto's
-- De foto's staan NIET op GitHub, maar in een privé opslagmap in Supabase.
-- Een speler kan enkel de foto's zien van kaarten die hij zelf bezit;
-- admins zien alles. Niet ingelogd = niets.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
--
-- Daarna: Storage -> map "card-photos" -> alle foto's uploaden (bv. seppe-1.jpg),
-- rechtstreeks in de map, niet in een submap.
-- =====================================================================

-- 1. Privé opslagmap (public = false: geen openbare links)
insert into storage.buckets (id, name, public)
values ('card-photos', 'card-photos', false)
on conflict (id) do update set public = false;

-- 2. Lezen: enkel de foto van een kaart die je bezit (of als admin)
--    De bestandsnaam in de map moet overeenkomen met cards.image_url zonder "cards/".
drop policy if exists "kaartfoto's van eigen kaarten" on storage.objects;
create policy "kaartfoto's van eigen kaarten" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'card-photos'
    and (
      public.is_admin()
      or exists (
        select 1
        from public.user_cards uc
        join public.cards c on c.id = uc.card_id
        where uc.user_id = auth.uid()
          and c.image_url = 'cards/' || storage.objects.name
      )
    )
  );
-- Uploaden/wijzigen/verwijderen kan enkel via het Supabase-dashboard (geen policies = niemand anders).
