-- =====================================================================
-- RIZZ ACADEMY — update 12: foto's van de kaarten van je tegenstander in een gevecht
--
-- Tot nu toe kon je enkel de foto's zien van kaarten die je zelf hebt. Nu zie je ook de foto's
-- van de kaarten in een gevecht waarin je zelf meespeelt (tegen de computer of een vriend).
-- Al de rest blijft afgeschermd.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
-- =====================================================================

-- Hulpfunctie: zit deze kaart in een gevecht van de ingelogde speler?
create or replace function public._card_in_my_battle(p_card int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.tbattles b
    where (b.player_a = auth.uid() or b.player_b = auth.uid())
      and b.status in ('active', 'done')
      and (coalesce(b.state->'A'->'cards', '[]'::jsonb) @> to_jsonb(p_card)
        or coalesce(b.state->'B'->'cards', '[]'::jsonb) @> to_jsonb(p_card))
  );
$$;
grant execute on function public._card_in_my_battle(int) to authenticated;

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
      or exists (
        select 1 from public.cards c
        where c.image_url = 'cards/' || storage.objects.name
          and public._card_in_my_battle(c.id)
      )
    )
  );
