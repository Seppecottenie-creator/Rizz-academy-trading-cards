-- =====================================================================
-- RIZZ ACADEMY — release: de Boss Battle voor iedereen openzetten
--
-- Tot je dit uitvoert, ziet enkel de admin de Boss Battle (tabblad, aftelklok op de campus, gevecht).
-- Zorg eerst dat er een boss gepland staat op zondag 20u (Boss Battle -> Beheer).
-- Terug enkel voor de admin: zet true op false en voer opnieuw uit.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit bestand plakken -> Run ("Run without RLS").
-- =====================================================================
update public.feature_flags set released = true where key = 'boss';

select key, released, note from public.feature_flags order by key;
