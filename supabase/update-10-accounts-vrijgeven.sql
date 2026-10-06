-- =====================================================================
-- RIZZ ACADEMY — update 10: alle accounts die nog wachten op een bevestigingsmail vrijgeven
--
-- Iedereen die zich al registreerde maar de bevestigingsmail nooit kreeg
-- (door "email rate limit exceeded"), kan hierna meteen inloggen.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren (bv. als er later nog iemand vastzit).
-- =====================================================================
update auth.users
set email_confirmed_at = now()
where email_confirmed_at is null;
