-- =====================================================================
-- RIZZ ACADEMY — jouw testscores per spel (verandert niets, leest enkel)
-- Supabase -> SQL Editor -> plakken -> Run. Stuur een screenshot van het resultaat.
-- =====================================================================
select game as spel,
       count(*) as keer,
       string_agg(score::text || ' (' || grade || ')', ', ' order by created_at) as scores,
       round(avg(score), 1) as gemiddeld,
       round(avg(seconds)) as seconden
from public.admin_play_log
group by game
order by game;
