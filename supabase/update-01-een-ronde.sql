-- =====================================================================
-- RIZZ ACADEMY — update 01: 1 Wordle per dag + "credits"
-- Voer dit uit NA setup.sql (dat je al gedaan hebt).
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
--
-- Wat verandert er:
--  * Nog maar 1 Wordle-ronde per dag, open vanaf middernacht (Belgische tijd).
--  * Foutmelding in de shop spreekt van "credits" i.p.v. "polycoins".
-- (setup.sql in de repo bevat deze wijzigingen al, voor een nieuw project.)
-- =====================================================================

create or replace function public._wordle_opens(p_slot int) returns time
language sql immutable as $$ select time '00:00' $$;

create or replace function public._shop_spend(p_user uuid, p_amount int, p_kind text, p_detail jsonb default null) returns int
language plpgsql volatile security definer set search_path = public as $$
declare v int;
begin
  update public.user_wallet set polycoins = polycoins - p_amount
    where user_id = p_user and polycoins >= p_amount
    returning polycoins into v;
  if not found then
    raise exception 'Niet genoeg credits: je hebt er %, je hebt er % nodig.',
      coalesce((select polycoins from public.user_wallet where user_id = p_user), 0), p_amount;
  end if;
  insert into public.shop_log (user_id, kind, amount, detail) values (p_user, p_kind, -p_amount, p_detail);
  return v;
end $$;

create or replace function public.wordle_state() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  out_ jsonb := '[]'::jsonb;
  s int; g public.wordle_games; w text; rows_ jsonb; opens time;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  for s in 1..1 loop
    opens := public._wordle_opens(s);
    select * into g from public.wordle_games where user_id = me and round_date = d and slot = s;
    rows_ := '[]'::jsonb;
    if found and coalesce(array_length(g.guesses, 1), 0) > 0 then
      w := public._wordle_word(d, s);
      select coalesce(jsonb_agg(jsonb_build_object('w', x.guess, 'r', public._wordle_score(x.guess, w)) order by x.n), '[]')
        into rows_ from unnest(g.guesses) with ordinality x(guess, n);
    end if;
    out_ := out_ || jsonb_build_object(
      'slot', s,
      'opens', to_char(opens, 'HH24:MI'),
      'open', loc::time >= opens,
      'seconds_until_open', greatest(0, extract(epoch from (d + opens) - loc))::int,
      'status', coalesce(g.status, 'new'),
      'rows', rows_,
      'attempts', g.attempts,
      'hints', coalesce(g.hints, '[]'::jsonb),
      'max_guesses', 6 + case when g.extra_guess then 1 else 0 end,
      'card_id', g.card_id,
      'answer', case when g.status = 'lost' then public._wordle_word(d, s) end
    );
  end loop;
  return jsonb_build_object('date', d, 'slots', out_);
end $$;

create or replace function public.wordle_guess(p_slot int, p_guess text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  guess text := upper(trim(p_guess));
  g public.wordle_games;
  w text; score text; n int;
  v_draw jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
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
    v_draw := public._wordle_draw(me, g.attempts);
    update public.wordle_games set guesses = g.guesses, status = g.status, attempts = g.attempts,
      card_id = (v_draw->'card'->>'id')::int, is_duplicate = (v_draw->>'dup')::boolean,
      coins_earned = (v_draw->>'coins')::int, finished_at = now()
    where user_id = me and round_date = d and slot = p_slot;
    return jsonb_build_object('result', score, 'status', g.status, 'attempts', g.attempts, 'guess', guess,
      'card', v_draw->'card', 'rarity', v_draw->'card'->>'rarity', 'isDuplicate', (v_draw->>'dup')::boolean,
      'coinsEarned', (v_draw->>'coins')::int,
      'cardAdded', true, 'solved', g.status = 'won', 'answer', case when g.status = 'lost' then w end);
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
  if p_slot <> 1 or loc::time < public._wordle_opens(p_slot) then raise exception 'Deze Wordle is nog niet open.'; end if;
  insert into public.wordle_games (user_id, round_date, slot) values (me, d, p_slot) on conflict do nothing;
  select * into g from public.wordle_games where user_id = me and round_date = d and slot = p_slot for update;
  if g.status <> 'playing' then raise exception 'Deze Wordle is al afgelopen.'; end if;
  if g.extra_guess then raise exception 'Je hebt voor deze ronde al een extra poging.'; end if;
  v_wallet := public._shop_spend(me, 60, 'wordle_extra', jsonb_build_object('date', d, 'slot', p_slot));
  update public.wordle_games set extra_guess = true where user_id = me and round_date = d and slot = p_slot;
  return jsonb_build_object('max_guesses', 7, 'wallet', v_wallet);
end $$;

revoke all on function public._shop_spend(uuid, int, text, jsonb) from public, anon, authenticated;
grant execute on function public.wordle_state() to authenticated;
grant execute on function public.wordle_guess(int, text) to authenticated;
grant execute on function public.wordle_hint(int) to authenticated;
grant execute on function public.wordle_extra_guess(int) to authenticated;
