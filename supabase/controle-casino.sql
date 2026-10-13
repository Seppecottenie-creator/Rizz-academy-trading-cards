-- =====================================================================
-- RIZZ ACADEMY — controle: hoe doet iedereen het in het casino?
-- Verandert niets, leest enkel. Supabase -> SQL Editor -> plakken -> Run.
--
-- Per speler en per spel:
--   gespeeld    = aantal spelletjes
--   ingezet     = totaal ingezette credits (bij blackjack inclusief verdubbelen/splitsen)
--   terug       = totaal uitbetaald
--   netto       = terug - ingezet (positief = winst)
--   terug_pct   = hoeveel procent van je inzet je terugkreeg
--   verwacht_pct = wat je op lange termijn terugkrijgt (blackjack met perfect spel ~100%, slots/paarden ~90%)
--   geluk_score = hoeveel "standaardafwijkingen" de winst van het verwachte afligt.
--                 Tussen -2 en +2 is normaal geluk/pech. Boven +3 is heel verdacht.
-- =====================================================================
with plays as (
  select p.user_id, coalesce(pr.display_name, '?') as speler, p.game, p.bet, p.payout, p.result,
    -- verwachte terugbetaling (fractie) en spreiding per ingezette credit, per spel en soort inzet
    case p.game
      when 'blackjack' then 1.00
      when 'slots' then 0.90
      when 'roulette' then 0.973
      when 'horses' then case p.result->>'pick' when '1' then 0.918 when '2' then 0.900 when '3' then 0.918 when '4' then 0.910 else 0.918 end
    end as rtp,
    case p.game
      when 'blackjack' then 1.16
      when 'slots' then 1.80
      when 'roulette' then case when p.result->>'kind' = 'number' then 5.84 else 1.00 end
      when 'horses' then case p.result->>'pick' when '1' then 1.28 when '2' then 1.56 when '3' then 1.96 when '4' then 2.26 else 2.92 end
    end as sd
  from public.casino_plays p left join public.profiles pr on pr.id = p.user_id
  where not public._is_admin_user(p.user_id)
)
select speler, game as spel,
  count(*) as gespeeld,
  sum(bet) as ingezet,
  sum(payout) as terug,
  sum(payout) - sum(bet) as netto,
  round(100.0 * sum(payout) / nullif(sum(bet), 0), 1) as terug_pct,
  round(100.0 * sum(rtp * bet) / nullif(sum(bet), 0), 1) as verwacht_pct,
  round((sum(payout) - sum(rtp * bet)) / nullif(sqrt(sum(power(sd * bet, 2))), 0), 2) as geluk_score,
  case when game = 'blackjack' then
    concat_ws(' · ',
      'blackjack ' || count(*) filter (where result->>'outcome' = 'blackjack'),
      'gewonnen ' || (count(*) filter (where result->>'outcome' = 'win') + count(*) filter (where result->>'outcome2' = 'win')),
      'gelijk ' || (count(*) filter (where result->>'outcome' = 'push') + count(*) filter (where result->>'outcome2' = 'push')),
      'verloren ' || (count(*) filter (where result->>'outcome' in ('lose', 'bust')) + count(*) filter (where result->>'outcome2' in ('lose', 'bust'))),
      'gesplitst ' || count(*) filter (where jsonb_typeof(result->'player2') = 'array'))
  end as blackjack_details
from plays
group by speler, game
order by speler, game;
