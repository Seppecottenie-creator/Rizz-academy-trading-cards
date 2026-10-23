-- =====================================================================
-- RIZZ ACADEMY — controle: blackjack en roulette per speler (simpel overzicht)
-- Verandert niets, leest enkel. Supabase -> SQL Editor -> plakken -> Run.
--
--   bj_ / roul_ gespeeld = aantal spelletjes
--   bj_ / roul_ netto    = gewonnen min ingezet (positief = winst)
--   bj_ / roul_ terug    = hoeveel procent van je inzet je terugkreeg
--                          (normaal op lange termijn: blackjack ±100%, roulette ±97%)
--   totaal_netto         = blackjack + roulette samen
-- =====================================================================
select
  coalesce(pr.display_name, '?') as speler,
  count(*) filter (where p.game = 'blackjack') as bj_gespeeld,
  coalesce(sum(p.payout - p.bet) filter (where p.game = 'blackjack'), 0) as bj_netto,
  round(100.0 * sum(p.payout) filter (where p.game = 'blackjack') / nullif(sum(p.bet) filter (where p.game = 'blackjack'), 0)) || '%' as bj_terug,
  count(*) filter (where p.game = 'roulette') as roul_gespeeld,
  coalesce(sum(p.payout - p.bet) filter (where p.game = 'roulette'), 0) as roul_netto,
  round(100.0 * sum(p.payout) filter (where p.game = 'roulette') / nullif(sum(p.bet) filter (where p.game = 'roulette'), 0)) || '%' as roul_terug,
  sum(p.payout - p.bet) as totaal_netto
from public.casino_plays p
left join public.profiles pr on pr.id = p.user_id
where p.game in ('blackjack', 'roulette') and not public._is_admin_user(p.user_id)
group by pr.display_name
order by totaal_netto desc;
