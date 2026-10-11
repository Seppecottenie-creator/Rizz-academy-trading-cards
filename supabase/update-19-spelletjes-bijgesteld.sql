-- =====================================================================
-- RIZZ ACADEMY — update 19: nieuwe cijfergrenzen na het testen
--
-- Basketbal, Cannon Shot en Beer Pong werken nu met tikken (makkelijker), Math is iets
-- makkelijker en History iets moeilijker. Doel: een gemiddelde poging = C, een goede = A.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
-- =====================================================================

-- Grenzen per spel: [laagste score, hoogste score, minimum aantal seconden, A, B, C, D]
create or replace function public._exam_rules(p_game text) returns int[]
language sql immutable as $$
  select case p_game
    when 'math'      then array[0, 80, 55, 20, 15, 11, 7]      -- juiste sommen in 60 seconden
    when 'hoops'     then array[0, 10, 8, 8, 6, 4, 2]          -- raak uit 10 worpen
    when 'history'   then array[0, 10, 12, 9, 8, 6, 4]         -- juist uit 10 vragen
    when 'launch'    then array[0, 8, 8, 7, 5, 4, 2]           -- raak uit 8 schoten
    when 'darts'     then array[0, 360, 6, 190, 150, 110, 70]  -- (niet meer op het rooster)
    when 'blackjack' then array[0, 400, 6, 160, 125, 100, 70]  -- chips na 10 handen (start 100)
    when 'pong'      then array[0, 6, 6, 6, 5, 4, 2]           -- bekers met 10 ballen
    when 'pour'      then array[0, 500, 8, 440, 380, 300, 200]
  end;
$$;
