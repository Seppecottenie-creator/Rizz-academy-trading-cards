-- =====================================================================
-- RIZZ ACADEMY — update 27: geheime trofeeën
--
-- 14 trofeeën die je pas ziet als je ze haalt. Tot dan staat er enkel "???" in je lijst.
-- Elke geheime trofee geeft ook credits (ophalen in Stats, zoals de gewone trofeeën).
-- TESTFASE: enkel de admin ziet (en haalt) ze tot release-16-oktober.sql uitgevoerd is.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-25-foodtruck.sql en update-26-voetbal.sql uit.
-- =====================================================================

create or replace function public._trophies(p_user uuid)
returns table (key text, done boolean, reward int)
language sql stable security definer set search_path = public as $$
  with plays as (select distinct exam_date, grade from public.exam_results where user_id = p_user and status = 'done'),
  days as (select distinct exam_date from plays),
  isl as (select exam_date - (row_number() over (order by exam_date))::int as grp from days),
  best as (select coalesce(max(c), 0) as s from (select count(*) as c from isl group by grp) x),
  owned as (select distinct c.id, c.person, c.rarity from public.user_cards uc join public.cards c on c.id = uc.card_id
            where uc.user_id = p_user and c.rarity <> 'cat'),
  fullset as (select exists (select 1 from public.cards c where c.rarity <> 'cat' group by c.person
              having count(*) = count(*) filter (where c.id in (select id from owned))) as ok),
  bat as (select
      count(*) filter (where status = 'done' and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'))) as wins,
      count(*) filter (where status = 'done' and mode = 'pvp' and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'))) as pvp_wins,
      count(*) filter (where status = 'done' and mode = 'pve' and difficulty = 'hard' and player_a = p_user and winner = 'A') as hard_wins
    from public.tbattles where player_a = p_user or player_b = p_user)
  select k, d and (k not like 'x\_%' or public._feature_on('secrets', p_user)), r from best, fullset, bat, lateral (values
    ('freshman',      (select count(*) from days) > 0,                          20),
    ('on_fire',       best.s >= 3,                                              50),
    ('iron_streak',   best.s >= 7,                                             150),
    ('straight_a',    exists (select 1 from plays where grade = 'A'),           50),
    ('legend_hunter', exists (select 1 from owned where rarity = 'legendary'), 100),
    ('collector',     (select count(*) from owned) >= 50,                      150),
    ('full_set',      fullset.ok,                                              200),
    ('rookie',        bat.wins >= 1,                                            25),
    ('gladiator',     bat.wins >= 10,                                          100),
    ('champion',      bat.hard_wins >= 1,                                      100),
    ('rival',         bat.pvp_wins >= 1,                                        50),
    ('flunked',       exists (select 1 from plays where grade = 'F'),           10),
    -- geheime trofeeën (namen en uitleg in _secret_trophies, pas zichtbaar als je ze haalt)
    ('x_nachtuil',    exists (select 1 from public.exam_results e where e.user_id = p_user and e.status = 'done'
                        and extract(hour from e.finished_at at time zone 'Europe/Brussels') between 2 and 4), 30),
    ('x_bust3',       exists (select 1 from (select result->>'outcome' = 'bust' as b,
                        row_number() over (order by id) - row_number() over (partition by result->>'outcome' = 'bust' order by id) as grp
                        from public.casino_plays where user_id = p_user and game = 'blackjack') x
                        where b group by grp having count(*) >= 3),                                     25),
    ('x_jackpot',     exists (select 1 from public.casino_plays where user_id = p_user and game = 'slots'
                        and result->'reels' = '["R","R","R"]'::jsonb),                                  100),
    ('x_groen',       exists (select 1 from public.casino_plays where user_id = p_user and game = 'roulette'
                        and result->>'number' = '0'),                                                   25),
    ('x_underdog',    exists (select 1 from public.casino_plays where user_id = p_user and game = 'horses'
                        and result->>'winner' = '5' and payout > 0),                                    50),
    ('x_highroller',  exists (select 1 from public.casino_plays where user_id = p_user
                        group by play_date having sum(payout - bet) >= 300),                            75),
    ('x_vodka',       exists (select 1 from public.food_log a join public.food_log b on b.user_id = a.user_id
                        where a.user_id = p_user and a.item = 'shotje' and b.item = 'redbull'
                        and abs(extract(epoch from a.created_at - b.created_at)) <= 600),               30),
    ('x_belgisch',    exists (select 1 from public.food_log k where k.user_id = p_user and k.item = 'kapsalon'
                        and (select count(*) from public.food_log p where p.user_id = p_user and p.item = 'pintje'
                             and p.created_at < k.created_at and p.created_at > k.created_at - interval '12 hours') >= 3), 30),
    ('x_proever',     exists (select 1 from public.food_log where user_id = p_user and item <> 'zat'
                        group by (created_at at time zone 'Europe/Brussels')::date having count(distinct item) >= 5), 50),
    ('x_zatlap',      exists (select 1 from public.food_log where user_id = p_user and item = 'zat'
                        group by (created_at at time zone 'Europe/Brussels')::date having count(*) >= 3), 40),
    ('x_vondst',      exists (select 1 from public.food_log where user_id = p_user and card_id is not null), 40),
    ('x_profeet',     (select count(*) from public.fb_bets where user_id = p_user and status = 'won') >= 3,  50),
    ('x_witte_vlag',  (select count(*) from public.tbattles where forfeit and status = 'done'
                        and ((player_a = p_user and winner = 'B') or (player_b = p_user and winner = 'A'))) >= 3, 15),
    ('x_herexamen',   (select count(*) from plays where grade = 'F') >= 3,                                 15)
  ) t(k, d, r);
$$;

-- Naam, uitleg en icoon van de geheime trofeeën (enkel getoond als je ze gehaald hebt)
create or replace function public._secret_trophies()
returns table (key text, name text, how text, icon text)
language sql immutable as $$
  values
    ('x_nachtuil',   'Nachtuil',        'Een examen afgerond tussen 2u en 5u ''s nachts', 'clock'),
    ('x_bust3',      'Bust Machine',    'Drie keer na elkaar bust bij blackjack',         'flame'),
    ('x_jackpot',    'Jackpot',         'Drie keer RIZZ op de slotmachine',               'crown'),
    ('x_groen',      'Groene Nul',      'De roulettebal viel op 0',                       'target'),
    ('x_underdog',   'Underdog',        'Gewonnen op Last Call in de paardenrace',        'star'),
    ('x_highroller', 'High Roller',     '300 credits winst in het casino op één dag',     'cup'),
    ('x_vodka',      'Vodka-Red Bull',  'Een shotje en een Red Bull binnen 10 minuten',   'flame'),
    ('x_belgisch',   'Belgische Avond', 'Een kapsalon na minstens 3 pintjes',             'star'),
    ('x_proever',    'Proever',         'Alles van de Food Truck op één dag',             'stack'),
    ('x_zatlap',     'Zatlap',          'Drie keer sterrezat op één dag',                 'flame'),
    ('x_vondst',     'Gouden Neus',     'Een kaart gevonden in het Rizz-poeder',          'star'),
    ('x_profeet',    'Profeet',         'Drie voetbalinzetten gewonnen',                  'target'),
    ('x_witte_vlag', 'Witte Vlag',      'Drie keer opgegeven in The Arena',               'swords'),
    ('x_herexamen',  'Herexamen',       'Drie F''s gehaald',                              'clock');
$$;

-- Status voor de site: geheime trofeeën die je nog niet hebt, krijgen geen naam (enkel "???")
create or replace function public.trophy_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(
    case when s.key is null then
      jsonb_build_object('key', t.key, 'done', t.done, 'reward', t.reward,
        'claimed', exists (select 1 from public.trophy_claims c where c.user_id = auth.uid() and c.key = t.key))
    when t.done then
      jsonb_build_object('key', t.key, 'done', true, 'reward', t.reward, 'secret', true, 'name', s.name, 'how', s.how, 'icon', s.icon,
        'claimed', exists (select 1 from public.trophy_claims c where c.user_id = auth.uid() and c.key = t.key))
    else jsonb_build_object('key', 'secret', 'done', false, 'secret', true)
    end order by s.key is not null, t.done desc), '[]'::jsonb)
  from public._trophies(auth.uid()) t left join public._secret_trophies() s on s.key = t.key
  where auth.uid() is not null and (s.key is null or public._feature_on('secrets'));
$$;
grant execute on function public.trophy_status() to authenticated;

notify pgrst, 'reload schema';
