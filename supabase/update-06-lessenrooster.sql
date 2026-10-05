-- =====================================================================
-- RIZZ ACADEMY — update 06: lessenrooster met minigames, cijfers A-F
--
-- 1. Elke dag een ander vak met een eigen minigame (Belgische tijd):
--    ma English (Wordle) · di Math · wo Phys. Ed. (basketbal) · do History
--    vr Physics (darts) · za Party (beer pong) · zo Party (pour the pint)
-- 2. Je score wordt een cijfer: A, B, C, D of F. Hoe beter het cijfer, hoe groter
--    de kans op een epic of legendary. Een F = gebuisd: geen kaart. Iedereen kan
--    zien hoeveel F's iemand heeft.
-- 3. De Detention-kaarten verdwijnen (ook uit ieders collectie).
-- 4. Eén poging per dag: wie een spel start en niet afmaakt, krijgt een F.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-05-frathouse.sql uit.
-- =====================================================================

-- 1. Detention-kaarten verwijderen -----------------------------------------------------
update public.trade_requests set status = 'cancelled', updated_at = now()
where status = 'pending' and exists (
  select 1 from public.cards c where c.rarity = 'cat'
    and (c.id = any(proposer_cards) or c.id = any(recipient_cards)));
update public.tbattles b set status = 'cancelled', updated_at = now()
where status in ('pending', 'active') and exists (
  select 1 from jsonb_array_elements_text(coalesce(b.state->'A'->'cards', '[]') || coalesce(b.state->'B'->'cards', '[]')) x
  join public.cards c on c.id = x::int where c.rarity = 'cat'
  union all
  select 1 from public.tbattle_hidden h join public.cards c on c.id = any(h.cards) where h.battle_id = b.id and c.rarity = 'cat');
update public.wordle_games set card_id = null where card_id in (select id from public.cards where rarity = 'cat');
update public.daily_plays set card_id = null where card_id in (select id from public.cards where rarity = 'cat');
delete from public.user_cards where card_id in (select id from public.cards where rarity = 'cat');
delete from public.cards where rarity = 'cat';

-- 2. Resultaten per dag ----------------------------------------------------------------
create table if not exists public.exam_results (
  user_id uuid not null references auth.users(id) on delete cascade,
  exam_date date not null,
  game text not null,
  status text not null default 'playing' check (status in ('playing', 'done')),
  score int,
  grade text check (grade in ('A', 'B', 'C', 'D', 'F')),
  card_id int references public.cards(id) on delete set null,
  is_duplicate boolean,
  coins_earned int not null default 0,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  primary key (user_id, exam_date)
);
alter table public.exam_results enable row level security;
drop policy if exists "eigen resultaten lezen" on public.exam_results;
create policy "eigen resultaten lezen" on public.exam_results for select to authenticated using (auth.uid() = user_id);
revoke insert, update, delete on public.exam_results from anon, authenticated;

-- Cijfer uit het aantal Wordle-pogingen
create or replace function public._wordle_grade(p_attempts int) returns text
language sql immutable as $$
  select case when p_attempts is null then 'F' when p_attempts <= 2 then 'A' when p_attempts = 3 then 'B'
              when p_attempts = 4 then 'C' else 'D' end;
$$;

-- Bestaande Wordles worden ook resultaten
insert into public.exam_results (user_id, exam_date, game, status, score, grade, card_id, is_duplicate, coins_earned, started_at, finished_at)
select g.user_id, g.round_date, 'wordle', 'done', g.attempts, public._wordle_grade(case when g.status = 'won' then g.attempts end),
       g.card_id, g.is_duplicate, g.coins_earned, g.created_at, coalesce(g.finished_at, g.created_at)
from public.wordle_games g where g.status <> 'playing'
on conflict do nothing;
insert into public.exam_results (user_id, exam_date, game, status, score, grade, card_id, started_at, finished_at)
select p.user_id, p.play_date, 'wordle', 'done', p.attempts, public._wordle_grade(case when p.solved then p.attempts end), p.card_id, now(), now()
from public.daily_plays p
on conflict do nothing;

-- 3. Het lessenrooster -------------------------------------------------------------------
create or replace function public._exam_game(p_date date) returns text
language sql immutable as $$
  select (array['wordle', 'math', 'hoops', 'history', 'darts', 'pong', 'pour'])[extract(isodow from p_date)::int];
$$;

-- Kaart trekken volgens het cijfer (F = geen kaart)
create or replace function public._grade_draw(p_user uuid, p_grade text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r float8 := random() * 100; leg float8; ep float8; v_rarity text;
  v_card public.cards; v_dup boolean; v_coins int := 0;
begin
  if p_grade = 'F' then return jsonb_build_object('card', null, 'dup', false, 'coins', 0); end if;
  leg := case p_grade when 'A' then 30 when 'B' then 10 when 'C' then 3 else 0.5 end;
  ep  := case p_grade when 'A' then 50 when 'B' then 35 when 'C' then 22 else 8 end;
  v_rarity := case when r < leg then 'legendary' when r < leg + ep then 'epic' else 'common' end;
  select * into v_card from public.cards where rarity = v_rarity order by random() limit 1;
  if not found then raise exception 'Geen kaarten gevonden voor zeldzaamheid %.', v_rarity; end if;
  v_dup := exists (select 1 from public.user_cards where user_id = p_user and card_id = v_card.id);
  insert into public.user_cards (user_id, card_id) values (p_user, v_card.id);
  if v_dup then
    v_coins := case v_rarity when 'common' then 10 when 'epic' then 25 else 60 end;
    insert into public.user_wallet (user_id, polycoins) values (p_user, v_coins)
      on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
  end if;
  return jsonb_build_object('card', to_jsonb(v_card), 'dup', v_dup, 'coins', v_coins);
end $$;
revoke all on function public._grade_draw(uuid, text) from public, anon, authenticated;

-- Grenzen per spel: [laagste score, hoogste score, minimum aantal seconden, A, B, C, D]
create or replace function public._exam_rules(p_game text) returns int[]
language sql immutable as $$
  select case p_game
    when 'math'    then array[0, 80, 55, 24, 18, 12, 7]     -- juiste sommen in 60 seconden
    when 'hoops'   then array[0, 10, 8, 8, 6, 4, 2]         -- raak uit 10 worpen
    when 'history' then array[0, 10, 12, 9, 7, 5, 3]        -- juist uit 10 vragen
    when 'darts'   then array[0, 300, 6, 170, 125, 85, 45]  -- punten met 6 pijlen
    when 'pong'    then array[0, 6, 6, 6, 5, 4, 2]          -- bekers geraakt met 10 ballen
    when 'pour'    then array[0, 500, 8, 440, 380, 300, 200] -- precisie van 5 pintjes (max 100 elk)
  end;
$$;

-- Wat staat er vandaag op het rooster, en heb ik al gespeeld?
create or replace function public.exam_today() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  d date := (now() at time zone 'Europe/Brussels')::date;
  r public.exam_results;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into r from public.exam_results where user_id = me and exam_date = d;
  -- Gestart en niet afgemaakt (langer dan 20 minuten geleden): gebuisd
  if found and r.status = 'playing' and r.game <> 'wordle' and r.started_at < now() - interval '20 minutes' then
    update public.exam_results set status = 'done', score = 0, grade = 'F', finished_at = now()
      where user_id = me and exam_date = d returning * into r;
  end if;
  return jsonb_build_object(
    'date', d, 'game', public._exam_game(d), 'dow', extract(isodow from d)::int,
    'status', coalesce(r.status, 'new'), 'score', r.score, 'grade', r.grade,
    'card', (select to_jsonb(c) from public.cards c where c.id = r.card_id),
    'seconds_left', greatest(0, extract(epoch from (d + 1)::timestamp - (now() at time zone 'Europe/Brussels')))::int);
end $$;

-- Spel starten: dit telt als je poging van vandaag
create or replace function public.exam_start() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  d date := (now() at time zone 'Europe/Brussels')::date;
  g text := public._exam_game(d);
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if g = 'wordle' then raise exception 'Vandaag is het de Wordle.'; end if;
  if exists (select 1 from public.exam_results where user_id = me and exam_date = d) then
    raise exception 'Je hebt het examen van vandaag al gestart.';
  end if;
  insert into public.exam_results (user_id, exam_date, game) values (me, d, g);
  return jsonb_build_object('game', g, 'seed', floor(random() * 1000000)::int);
end $$;

-- Score indienen: cijfer berekenen en een kaart trekken
create or replace function public.exam_submit(p_score int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  d date := (now() at time zone 'Europe/Brussels')::date;
  r public.exam_results; rules int[]; v_score int; v_grade text; v_draw jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into r from public.exam_results where user_id = me and exam_date = d for update;
  if not found or r.game = 'wordle' then raise exception 'Je hebt vandaag geen examen gestart.'; end if;
  if r.status <> 'playing' then raise exception 'Dit examen is al ingediend.'; end if;
  rules := public._exam_rules(r.game);
  if now() - r.started_at < make_interval(secs => rules[3]) then raise exception 'Dat ging verdacht snel.'; end if;
  v_score := least(greatest(coalesce(p_score, 0), rules[1]), rules[2]);
  if r.started_at < now() - interval '20 minutes' then v_score := 0; end if;
  v_grade := case when v_score >= rules[4] then 'A' when v_score >= rules[5] then 'B'
                  when v_score >= rules[6] then 'C' when v_score >= rules[7] then 'D' else 'F' end;
  v_draw := public._grade_draw(me, v_grade);
  update public.exam_results set status = 'done', score = v_score, grade = v_grade,
    card_id = (v_draw->'card'->>'id')::int, is_duplicate = (v_draw->>'dup')::boolean,
    coins_earned = (v_draw->>'coins')::int, finished_at = now()
  where user_id = me and exam_date = d;
  return jsonb_build_object('grade', v_grade, 'score', v_score, 'card', v_draw->'card',
    'isDuplicate', (v_draw->>'dup')::boolean, 'coinsEarned', (v_draw->>'coins')::int);
end $$;
grant execute on function public.exam_today() to authenticated;
grant execute on function public.exam_start() to authenticated;
grant execute on function public.exam_submit(int) to authenticated;


-- 4. Wordle enkel op maandag, met een cijfer --------------------------------------------
create or replace function public.wordle_guess(p_slot int, p_guess text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  guess text := upper(trim(p_guess));
  g public.wordle_games;
  w text; score text; n int;
  v_draw jsonb; v_grade text;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if public._exam_game(d) <> 'wordle' then raise exception 'Vandaag staat er geen Wordle op het rooster.'; end if;
  if p_slot <> 1 then raise exception 'Onbekende ronde.'; end if;
  if loc::time < public._wordle_opens(p_slot) then
    raise exception 'Deze Wordle opent pas om % (Belgische tijd).', to_char(public._wordle_opens(p_slot), 'HH24:MI');
  end if;
  if guess !~ '^[A-Z]{5}$' then raise exception 'Een gok moet uit precies 5 letters bestaan.'; end if;

  insert into public.wordle_games (user_id, round_date, slot) values (me, d, p_slot) on conflict do nothing;
  select * into g from public.wordle_games where user_id = me and round_date = d and slot = p_slot for update;
  if g.status <> 'playing' then raise exception 'Deze Wordle heb je al gespeeld.'; end if;

  w := public._wordle_word(d, p_slot);
  score := public._wordle_score(guess, w);
  g.guesses := g.guesses || guess;
  n := array_length(g.guesses, 1);

  if score = 'ggggg' or n >= 6 + (case when g.extra_guess then 1 else 0 end) then
    g.status := case when score = 'ggggg' then 'won' else 'lost' end;
    g.attempts := case when g.status = 'won' then n end;
    v_grade := public._wordle_grade(g.attempts);
    v_draw := public._grade_draw(me, v_grade);
    insert into public.exam_results (user_id, exam_date, game, status, score, grade, card_id, is_duplicate, coins_earned, started_at, finished_at)
    values (me, d, 'wordle', 'done', g.attempts, v_grade, (v_draw->'card'->>'id')::int, (v_draw->>'dup')::boolean, (v_draw->>'coins')::int, g.created_at, now())
    on conflict (user_id, exam_date) do nothing;
    update public.wordle_games set guesses = g.guesses, status = g.status, attempts = g.attempts,
      card_id = (v_draw->'card'->>'id')::int, is_duplicate = (v_draw->>'dup')::boolean,
      coins_earned = (v_draw->>'coins')::int, finished_at = now()
    where user_id = me and round_date = d and slot = p_slot;
    return jsonb_build_object('result', score, 'status', g.status, 'attempts', g.attempts, 'guess', guess,
      'grade', v_grade, 'card', v_draw->'card', 'rarity', v_draw->'card'->>'rarity', 'isDuplicate', (v_draw->>'dup')::boolean,
      'coinsEarned', (v_draw->>'coins')::int,
      'cardAdded', v_draw->'card' <> 'null'::jsonb, 'solved', g.status = 'won', 'answer', case when g.status = 'lost' then w end);
  end if;

  update public.wordle_games set guesses = g.guesses where user_id = me and round_date = d and slot = p_slot;
  return jsonb_build_object('result', score, 'status', 'playing', 'guess', guess, 'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;

create or replace function public.wordle_hint(p_slot int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  g public.wordle_games; w text; pos int; v_wallet int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if public._exam_game(d) <> 'wordle' then raise exception 'Vandaag staat er geen Wordle op het rooster.'; end if;
  if p_slot <> 1 or loc::time < public._wordle_opens(p_slot) then raise exception 'Deze Wordle is nog niet open.'; end if;
  insert into public.wordle_games (user_id, round_date, slot) values (me, d, p_slot) on conflict do nothing;
  select * into g from public.wordle_games where user_id = me and round_date = d and slot = p_slot for update;
  if g.status <> 'playing' then raise exception 'Deze Wordle is al afgelopen.'; end if;
  if jsonb_array_length(g.hints) >= 2 then raise exception 'Je kan maximaal 2 letters per ronde onthullen.'; end if;
  w := public._wordle_word(d, p_slot);
  -- Plaatsen die nog niet gekend zijn: nooit groen gegokt en nog niet onthuld
  select p into pos from generate_series(1, 5) p
  where not exists (select 1 from unnest(g.guesses) x where substr(x, p, 1) = substr(w, p, 1))
    and not exists (select 1 from jsonb_array_elements(g.hints) h where (h->>'pos')::int = p)
  order by random() limit 1;
  if pos is null then raise exception 'Je kent alle letters al — nu nog de juiste volgorde!'; end if;
  v_wallet := public._shop_spend(me, 40, 'wordle_hint', jsonb_build_object('date', d, 'slot', p_slot));
  update public.wordle_games set hints = hints || jsonb_build_object('pos', pos, 'letter', substr(w, pos, 1))
    where user_id = me and round_date = d and slot = p_slot;
  return jsonb_build_object('pos', pos, 'letter', substr(w, pos, 1), 'wallet', v_wallet);
end $$;

create or replace function public.wordle_extra_guess(p_slot int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  g public.wordle_games; v_wallet int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if public._exam_game(d) <> 'wordle' then raise exception 'Vandaag staat er geen Wordle op het rooster.'; end if;
  if p_slot <> 1 or loc::time < public._wordle_opens(p_slot) then raise exception 'Deze Wordle is nog niet open.'; end if;
  insert into public.wordle_games (user_id, round_date, slot) values (me, d, p_slot) on conflict do nothing;
  select * into g from public.wordle_games where user_id = me and round_date = d and slot = p_slot for update;
  if g.status <> 'playing' then raise exception 'Deze Wordle is al afgelopen.'; end if;
  if g.extra_guess then raise exception 'Je hebt voor deze ronde al een extra poging.'; end if;
  v_wallet := public._shop_spend(me, 60, 'wordle_extra', jsonb_build_object('date', d, 'slot', p_slot));
  update public.wordle_games set extra_guess = true where user_id = me and round_date = d and slot = p_slot;
  return jsonb_build_object('max_guesses', 7, 'wallet', v_wallet);
end $$;

-- 5. Het huis: wie speelde vandaag en hoeveel F's ----------------------------------------
drop function if exists public.house_members();
create or replace function public.house_members()
returns table (user_id uuid, display_name text, avatar_url text, room text, played boolean, cards int, legendaries int, fs int)
language sql stable security definer set search_path = public as $$
  select p.id, p.display_name, p.avatar_url, p.room,
    exists (select 1 from public.exam_results e where e.user_id = p.id and e.status = 'done'
            and e.exam_date = (now() at time zone 'Europe/Brussels')::date),
    (select count(distinct uc.card_id)::int from public.user_cards uc where uc.user_id = p.id),
    (select count(distinct uc.card_id)::int from public.user_cards uc join public.cards c on c.id = uc.card_id
      where uc.user_id = p.id and c.rarity = 'legendary'),
    (select count(*)::int from public.exam_results e where e.user_id = p.id and e.grade = 'F')
  from public.profiles p
  where auth.uid() is not null;
$$;
grant execute on function public.house_members() to authenticated;

-- Kamer van iemand: collectie, resultaten (cijfers) en battles
create or replace function public.member_room(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'cards', coalesce((select jsonb_agg(distinct uc.card_id) from public.user_cards uc where uc.user_id = p_user), '[]'::jsonb),
    'plays', coalesce((select jsonb_agg(jsonb_build_object('play_date', e.exam_date, 'game', e.game, 'grade', e.grade,
                         'solved', e.grade <> 'F', 'score', e.score) order by e.exam_date)
                       from public.exam_results e where e.user_id = p_user and e.status = 'done'), '[]'::jsonb),
    'battle', jsonb_build_object(
      'wins', (select count(*) from public.tbattles where status = 'done'
               and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'))),
      'pvp_wins', (select count(*) from public.tbattles where status = 'done' and mode = 'pvp'
               and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'))),
      'hard_wins', (select count(*) from public.tbattles where status = 'done' and mode = 'pve' and difficulty = 'hard'
               and player_a = p_user and winner = 'A'),
      'losses', (select count(*) from public.tbattles where status = 'done'
               and ((player_a = p_user and winner = 'B') or (player_b = p_user and winner = 'A')))))
  end;
$$;
grant execute on function public.member_room(uuid) to authenticated;
