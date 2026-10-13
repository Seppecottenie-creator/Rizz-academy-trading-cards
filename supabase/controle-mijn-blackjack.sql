-- =====================================================================
-- RIZZ ACADEMY — controle: alle blackjack-handen van het admin-account
-- Verandert niets, leest enkel. Supabase -> SQL Editor -> plakken -> Run.
-- Daarna rechtsboven het resultaat downloaden als CSV ("Export" / "Download CSV")
-- en dat bestand doorsturen.
-- =====================================================================
with kaart(c, txt) as (
  select c, (array['A','2','3','4','5','6','7','8','9','10','J','Q','K'])[c % 13 + 1] || (array['♠','♥','♦','♣'])[c / 13 + 1]
  from generate_series(0, 51) c
),
handen as (
  select p.id, p.created_at, p.bet, p.payout, p.result r
  from public.casino_plays p
  where p.game = 'blackjack' and public._is_admin_user(p.user_id)
)
select
  h.id as nr,
  to_char(h.created_at at time zone 'Europe/Brussels', 'DD/MM HH24:MI:SS') as tijd,
  h.bet as inzet,
  h.payout as terug,
  h.payout - h.bet as netto,
  (select string_agg(k.txt, ' ' order by o) from jsonb_array_elements_text(h.r->'player') with ordinality x(v, o) join kaart k on k.c = x.v::int) as jij,
  (h.r->>'player_total')::int as jij_tot,
  case when jsonb_typeof(h.r->'player2') = 'array' then
    (select string_agg(k.txt, ' ' order by o) from jsonb_array_elements_text(h.r->'player2') with ordinality x(v, o) join kaart k on k.c = x.v::int) end as hand2,
  (h.r->>'player2_total')::int as hand2_tot,
  (select string_agg(k.txt, ' ' order by o) from jsonb_array_elements_text(h.r->'dealer') with ordinality x(v, o) join kaart k on k.c = x.v::int) as dealer,
  (h.r->>'dealer_total')::int as dealer_tot,
  h.r->>'outcome' as uitkomst,
  h.r->>'outcome2' as uitkomst2,
  h.r->>'bet1' as inzet1,
  h.r->>'bet2' as inzet2
from handen h
order by h.id;
