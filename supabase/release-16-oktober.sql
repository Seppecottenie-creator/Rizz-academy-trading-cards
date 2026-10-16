-- =====================================================================
-- RIZZ ACADEMY — release: de nieuwe dingen van 16 oktober voor iedereen openzetten
--
-- Tot je dit uitvoert, ziet enkel de admin: de Food Truck-kaart, het Sportsbook, de geheime trofeeën,
-- de muziek en inzetten van 1 of 2 credits. Wil je één ding apart openzetten? Verwijder dan de andere uit de lijst hieronder.
-- Terug enkel voor de admin: zet true op false en voer opnieuw uit.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit bestand plakken -> Run ("Run without RLS").
-- =====================================================================
update public.feature_flags set released = true
where key in ('foodmenu', 'sportsbook', 'secrets', 'sound', 'smallbets');

select key, released, note from public.feature_flags order by key;
