-- =====================================================================
-- RIZZ ACADEMY — update 04: campus, kamers en nieuwe battles
--
-- 1. Battles v2: elke ronde kiezen beide spelers geheim FLEX, ROAST of CHARM
--    (FLEX > CHARM > ROAST > FLEX). Wie de clash wint, slaat hard en bouwt HYPE op;
--    met volle hype (3) kan je kaart haar SIGNATURE MOVE doen. Alles wordt in de
--    database berekend: de site kan niet valsspelen en ziet je zet pas na de ronde.
-- 2. Kamers in het Frat House: je hangt je beste kaarten aan je muur.
--    Enkel jij kan je muur aanpassen, en enkel met kaarten die je bezit.
--    Vrienden kunnen je kamer bekijken.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
-- =====================================================================

-- #####################################################################
-- 1. BATTLES V2
-- #####################################################################

-- Lopende gevechten met de oude regels vervallen (ze passen niet in het nieuwe systeem)
update public.tbattles set status = 'cancelled', updated_at = now()
where status = 'active' and coalesce(state->>'v', '1') <> '2';

-- Eén kant van het speelveld: stats van de 3 kaarten + hype en zetgeschiedenis
create or replace function public._tb_side(p_cards int[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cards', jsonb_agg(c.id order by u.ord),
    'hp', jsonb_agg(coalesce(c.hp, 50) order by u.ord),
    'max', jsonb_agg(coalesce(c.hp, 50) order by u.ord),
    'atk', jsonb_agg(coalesce(c.attack, 10) order by u.ord),
    'def', jsonb_agg(coalesce(c.defense, 0) order by u.ord),
    'sp', jsonb_agg(coalesce(c.special_power, 0) order by u.ord),
    'active', 0, 'hype', 0, 'hist', '[]'::jsonb)
  from unnest(p_cards) with ordinality u(id, ord) join public.cards c on c.id = u.id;
$$;

-- Welke zet wint van welke: FLEX > CHARM > ROAST > FLEX
create or replace function public._tb_beats(p_a text, p_b text) returns boolean
language sql immutable as $$
  select (p_a = 'flex' and p_b = 'charm') or (p_a = 'charm' and p_b = 'roast') or (p_a = 'roast' and p_b = 'flex');
$$;

-- Zet die wint van p_move
create or replace function public._tb_counter(p_move text) returns text
language sql immutable as $$
  select case p_move when 'flex' then 'roast' when 'roast' then 'charm' when 'charm' then 'flex' end;
$$;

-- Zet van de computer. Leest enkel de publieke toestand (nooit jouw geheime zet van deze ronde).
create or replace function public._tb_ai(p_state jsonb, p_side text, p_diff text) returns jsonb
language plpgsql volatile as $$
declare
  me jsonb := p_state -> p_side;
  op jsonb := p_state -> (case p_side when 'A' then 'B' else 'A' end);
  a int := (me->>'active')::int;
  hp_pct float8 := (me->'hp'->>a)::float8 / greatest(1, (me->'max'->>a)::float8);
  hist jsonb := coalesce(op->'hist', '[]'::jsonb);
  n int := jsonb_array_length(coalesce(op->'hist', '[]'::jsonb));
  tri text[] := array['flex', 'roast', 'charm'];
  guess text; best int; best_pct float8 := 0; i int; smart float8;
begin
  -- Signature move zodra de hype vol is
  if coalesce((me->>'hype')::int, 0) >= 3 then
    if random() < (case p_diff when 'easy' then .5 when 'normal' then .85 else 1 end) then
      return '{"a":"signature"}';
    end if;
  end if;
  -- Bijna uitgeschakelde kaart wegwisselen naar een gezonde kaart
  if p_diff <> 'easy' and hp_pct < .25 then
    for i in 0..jsonb_array_length(me->'hp') - 1 loop
      if i <> a and (me->'hp'->>i)::int > 0 and (me->'hp'->>i)::float8 / (me->'max'->>i)::float8 > best_pct then
        best := i; best_pct := (me->'hp'->>i)::float8 / (me->'max'->>i)::float8;
      end if;
    end loop;
    if best is not null and best_pct > .6 and random() < (case p_diff when 'hard' then .45 else .25 end) then
      return jsonb_build_object('a', 'switch', 't', best);
    end if;
  end if;
  -- Voorspellen: de zet die de tegenstander de laatste 4 rondes het vaakst koos
  smart := case p_diff when 'easy' then 0 when 'normal' then .45 else .65 end;
  if n > 0 and random() < smart then
    select m into guess from (
      select x.value #>> '{}' as m, count(*) as cnt, max(x.ord) as last
      from jsonb_array_elements(hist) with ordinality x(value, ord)
      where x.ord > n - 4 and x.value #>> '{}' = any(tri)
      group by 1 order by cnt desc, last desc limit 1) t;
    if guess is not null then return jsonb_build_object('a', public._tb_counter(guess)); end if;
  end if;
  return jsonb_build_object('a', tri[1 + floor(random() * 3)::int]);
end $$;

-- Schade van één slag
create or replace function public._tb_dmg(p_atk int, p_def int, p_mult float8, p_pierce boolean) returns int
language sql volatile as $$
  select greatest(2, round(p_atk * p_mult * (.9 + random() * .2) - case when p_pierce then 0 else p_def * .25 end))::int;
$$;

-- Eén ronde afwikkelen zodra beide zetten gekend zijn
create or replace function public._tb_resolve(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  b public.tbattles;
  st jsonb; ev jsonb; r int;
  act jsonb; mv jsonb := '{}'::jsonb;
  s text; o text; m text; om text; res text; w text; cw text;
  ai int; di int; nxt int; i int;
  dmg jsonb := '{"A": 0, "B": 0}'::jsonb;   -- schade die elke kant UITDEELT
  heal jsonb := '{"A": 0, "B": 0}'::jsonb;
  crit jsonb := '{"A": false, "B": false}'::jsonb;
  d int; mult float8; pierce boolean; hy int; ko_a boolean; ko_b boolean;
  v_ca int := 0; v_cb int := 0; reward int;
begin
  select * into b from public.tbattles where id = p_id for update;
  st := b.state; ev := coalesce(st->'events', '[]'::jsonb); r := b.round + 1;
  for s in select unnest(array['A', 'B']) loop
    select jsonb_build_object('a', h.action, 't', h.target) into act from public.tbattle_hidden h where h.battle_id = p_id and h.side = s;
    if act is null or act->>'a' is null then act := '{"a": "flex"}'::jsonb; end if;
    mv := mv || jsonb_build_object(s, act);
  end loop;

  -- Opgeven
  for s in select unnest(array['A', 'B']) loop
    if mv->s->>'a' = 'forfeit' then
      w := case s when 'A' then 'B' else 'A' end;
      ev := ev || jsonb_build_object('r', r, 't', 'forfeit', 's', s);
    end if;
  end loop;

  if w is null then
    -- 1. Wissels gebeuren eerst; wie wisselt, valt deze ronde niet aan
    for s in select unnest(array['A', 'B']) loop
      if mv->s->>'a' = 'switch' then
        st := jsonb_set(st, array[s, 'active'], to_jsonb((mv->s->>'t')::int));
        ev := ev || jsonb_build_object('r', r, 't', 'switch', 's', s, 'i', (mv->s->>'t')::int);
      end if;
    end loop;

    -- 2. De clash
    cw := null;
    if mv->'A'->>'a' = 'signature' and mv->'B'->>'a' <> 'signature' and mv->'B'->>'a' <> 'switch' then cw := 'A';
    elsif mv->'B'->>'a' = 'signature' and mv->'A'->>'a' <> 'signature' and mv->'A'->>'a' <> 'switch' then cw := 'B';
    elsif public._tb_beats(mv->'A'->>'a', mv->'B'->>'a') then cw := 'A';
    elsif public._tb_beats(mv->'B'->>'a', mv->'A'->>'a') then cw := 'B';
    end if;
    ev := ev || jsonb_build_object('r', r, 't', 'clash', 'a', mv->'A'->>'a', 'b', mv->'B'->>'a', 'w', cw);

    -- 3. Effect van elke zet, berekend op de toestand na de wissels (gelijktijdig)
    for s in select unnest(array['A', 'B']) loop
      o := case s when 'A' then 'B' else 'A' end;
      m := mv->s->>'a'; om := mv->o->>'a';
      if m = 'switch' then continue; end if;
      ai := (st->s->>'active')::int; di := (st->o->>'active')::int;
      res := case when om = 'switch' then 'free' when m = om then 'tie' when cw = s then 'win' else 'lose' end;
      mult := 0; pierce := false;
      if m = 'signature' then
        if res = 'lose' then continue; end if;      -- kan niet: signature verliest nooit
        d := case when (st->s->'sp'->>ai)::int > 0
                  then (st->s->'sp'->>ai)::int + round((st->s->'atk'->>ai)::int * .7)::int
                  else round((st->s->'atk'->>ai)::int * 2.4)::int end;
        dmg := jsonb_set(dmg, array[s], to_jsonb(d));
        continue;
      end if;
      if res = 'lose' then continue; end if;
      if m = 'flex' then
        mult := case res when 'win' then 2.0 when 'tie' then .7 else 1.4 end;
      elsif m = 'roast' then
        mult := case res when 'win' then 1.6 when 'tie' then .6 else 1.2 end; pierce := true;
      elsif m = 'charm' then
        mult := case res when 'win' then 1.0 else 0 end;
        heal := jsonb_set(heal, array[s], to_jsonb(round((st->s->'max'->>ai)::int * case res when 'tie' then .06 else .12 end)::int));
      end if;
      if mult > 0 then
        d := public._tb_dmg((st->s->'atk'->>ai)::int, (st->o->'def'->>di)::int, mult, pierce);
        if random() < .08 then d := round(d * 1.3)::int; crit := jsonb_set(crit, array[s], 'true'); end if;
        dmg := jsonb_set(dmg, array[s], to_jsonb(d));
      end if;
    end loop;

    -- 4. Toepassen: eerst genezen, dan schade
    for s in select unnest(array['A', 'B']) loop
      ai := (st->s->>'active')::int;
      if (heal->>s)::int > 0 then
        st := jsonb_set(st, array[s, 'hp', ai::text],
                        to_jsonb(least((st->s->'max'->>ai)::int, (st->s->'hp'->>ai)::int + (heal->>s)::int)));
        ev := ev || jsonb_build_object('r', r, 't', 'heal', 's', s, 'i', ai, 'v', (heal->>s)::int, 'hp', (st->s->'hp'->>ai)::int);
      end if;
    end loop;
    for s in select unnest(array['A', 'B']) loop
      o := case s when 'A' then 'B' else 'A' end;
      if (dmg->>s)::int > 0 then
        di := (st->o->>'active')::int;
        st := jsonb_set(st, array[o, 'hp', di::text], to_jsonb(greatest(0, (st->o->'hp'->>di)::int - (dmg->>s)::int)));
        ev := ev || jsonb_build_object('r', r, 't', 'hit', 's', s, 'k', mv->s->>'a', 'd', (dmg->>s)::int,
                                       'crit', (crit->>s)::boolean, 'di', di, 'hp', (st->o->'hp'->>di)::int);
      end if;
    end loop;

    -- 5. Hype: +1 voor wie de clash wint; signature zet de hype terug op 0
    for s in select unnest(array['A', 'B']) loop
      hy := coalesce((st->s->>'hype')::int, 0);
      if mv->s->>'a' = 'signature' then hy := 0;
      elsif cw = s then hy := least(3, hy + 1);
      end if;
      st := jsonb_set(st, array[s, 'hype'], to_jsonb(hy));
      st := jsonb_set(st, array[s, 'hist'], (
        select coalesce(jsonb_agg(x.value order by x.ord), '[]'::jsonb) from (
          select value, ord from jsonb_array_elements(coalesce(st->s->'hist', '[]'::jsonb) || to_jsonb(mv->s->>'a')) with ordinality e(value, ord)
          order by ord desc limit 8) x));
    end loop;

    -- 6. Uitgeschakelde kaarten: de volgende komt erin (met +1 hype als revanche), of einde
    ko_a := false; ko_b := false;
    for s in select unnest(array['A', 'B']) loop
      ai := (st->s->>'active')::int;
      if (st->s->'hp'->>ai)::int = 0 then
        ev := ev || jsonb_build_object('r', r, 't', 'ko', 's', s, 'i', ai);
        nxt := null;
        for i in 0..jsonb_array_length(st->s->'hp') - 1 loop
          if (st->s->'hp'->>i)::int > 0 then nxt := i; exit; end if;
        end loop;
        if nxt is null then
          if s = 'A' then ko_a := true; else ko_b := true; end if;
        else
          st := jsonb_set(st, array[s, 'active'], to_jsonb(nxt));
          st := jsonb_set(st, array[s, 'hype'], to_jsonb(least(3, (st->s->>'hype')::int + 1)));
          ev := ev || jsonb_build_object('r', r, 't', 'enter', 's', s, 'i', nxt);
        end if;
      end if;
    end loop;
    if ko_a and ko_b then w := case when (dmg->>'A')::int >= (dmg->>'B')::int then 'A' else 'B' end;
    elsif ko_a then w := 'B';
    elsif ko_b then w := 'A';
    end if;
    -- Veiligheidsnet: na 40 rondes wint wie procentueel het meeste HP over heeft
    if w is null and r >= 40 then
      w := case when (select sum((h.v)::float8 / m2.v::float8) from jsonb_array_elements_text(st->'A'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'A'->'max') with ordinality m2(v, n) using (n))
                  >= (select sum((h.v)::float8 / m2.v::float8) from jsonb_array_elements_text(st->'B'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'B'->'max') with ordinality m2(v, n) using (n))
               then 'A' else 'B' end;
    end if;
  end if;

  st := jsonb_set(st, '{moved}', '{"A": false, "B": false}');
  update public.tbattle_hidden set action = null, target = null where battle_id = p_id;

  if w is not null then
    ev := ev || jsonb_build_object('r', r, 't', 'end', 'w', w);
    if b.mode = 'pve' then
      if w = 'A' and public._tb_rewarded_today(b.player_a, 'pve') < 5 then
        v_ca := case b.difficulty when 'easy' then 5 when 'hard' then 20 else 10 end;
      end if;
    else
      reward := 25;
      if w = 'A' then
        if public._tb_rewarded_today(b.player_a, 'pvp') < 3 then v_ca := reward; end if;
        if public._tb_rewarded_today(b.player_b, 'pvp') < 3 and not exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') then v_cb := 5; end if;
      else
        if public._tb_rewarded_today(b.player_b, 'pvp') < 3 then v_cb := reward; end if;
        if public._tb_rewarded_today(b.player_a, 'pvp') < 3 and not exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') then v_ca := 5; end if;
      end if;
      -- Opgeven vóór ronde 3 levert niemand iets op (voorkomt credits "farmen" met een vriend)
      if exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') and r < 3 then v_ca := 0; v_cb := 0; end if;
    end if;
    if v_ca > 0 then perform public._tb_pay(b.player_a, v_ca); end if;
    if v_cb > 0 and b.player_b is not null then perform public._tb_pay(b.player_b, v_cb); end if;
    st := jsonb_set(st, '{events}', ev);
    update public.tbattles set state = st, round = r, status = 'done', winner = w,
      forfeit = exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit'),
      coins_a = v_ca, coins_b = v_cb, updated_at = now(), finished_at = now()
    where id = p_id;
  else
    st := jsonb_set(st, '{events}', ev);
    update public.tbattles set state = st, round = r, updated_at = now() where id = p_id;
  end if;
end $$;

-- Nieuwe gevechten krijgen versie 2
create or replace function public.tb_start_pve(p_cards int[], p_difficulty text) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  opp int[] := '{}'; c int; rar text; v_id bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_difficulty not in ('easy', 'normal', 'hard') then raise exception 'Onbekende moeilijkheid.'; end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  update public.tbattles set status = 'cancelled', updated_at = now()
    where player_a = me and mode = 'pve' and status = 'active';
  -- Tegenstander: per kaart een kaart van dezelfde zeldzaamheid (makkelijk: lager, moeilijk: hoger)
  foreach c in array p_cards loop
    select rarity into rar from public.cards where id = c;
    if rar = 'cat' then rar := 'common'; end if;
    rar := case p_difficulty
      when 'easy' then case rar when 'legendary' then 'epic' else 'common' end
      when 'hard' then case rar when 'common' then 'epic' else 'legendary' end
      else rar end;
    opp := opp || (select id from public.cards where rarity = rar and not (id = any(opp)) order by random() limit 1);
  end loop;
  insert into public.tbattles (mode, difficulty, player_a, status, state)
  values ('pve', p_difficulty, me, 'active',
          jsonb_build_object('v', 2, 'A', public._tb_side(p_cards), 'B', public._tb_side(opp), 'events', '[]'::jsonb,
                             'moved', '{"A": false, "B": false}'::jsonb))
  returning id into v_id;
  insert into public.tbattle_hidden (battle_id, side) values (v_id, 'A'), (v_id, 'B');
  return v_id;
end $$;

create or replace function public.tb_respond(p_id bigint, p_action text, p_cards int[] default null) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); b public.tbattles; a_cards int[];
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into b from public.tbattles where id = p_id for update;
  if not found or b.mode <> 'pvp' then raise exception 'Battle niet gevonden.'; end if;
  if b.status <> 'pending' then raise exception 'Deze uitdaging is al afgehandeld.'; end if;
  if p_action = 'cancel' then
    if me <> b.player_a then raise exception 'Enkel de uitdager kan annuleren.'; end if;
    update public.tbattles set status = 'cancelled', updated_at = now() where id = p_id;
    return;
  end if;
  if me <> b.player_b then raise exception 'Deze uitdaging is niet aan jou gericht.'; end if;
  if p_action = 'decline' then
    update public.tbattles set status = 'declined', updated_at = now() where id = p_id;
    return;
  end if;
  if p_action <> 'accept' then raise exception 'Onbekende actie.'; end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  select cards into a_cards from public.tbattle_hidden where battle_id = p_id and side = 'A';
  if not public._tb_team_ok(b.player_a, a_cards) then
    update public.tbattles set status = 'cancelled', updated_at = now() where id = p_id;
    return;
  end if;
  insert into public.tbattle_hidden (battle_id, side) values (p_id, 'B') on conflict do nothing;
  update public.tbattles set status = 'active', updated_at = now(),
    state = jsonb_build_object('v', 2, 'A', public._tb_side(a_cards), 'B', public._tb_side(p_cards), 'events', '[]'::jsonb,
                               'moved', '{"A": false, "B": false}'::jsonb)
  where id = p_id;
end $$;

-- Een zet doen: flex, roast, charm, signature (hype 3), switch (met p_target) of forfeit
create or replace function public.tb_act(p_id bigint, p_action text, p_target int default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  b public.tbattles; s text; o text; v_side jsonb; a int; ai jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into b from public.tbattles where id = p_id for update;
  if not found then raise exception 'Battle niet gevonden.'; end if;
  if b.status <> 'active' then raise exception 'Deze battle is niet (meer) bezig.'; end if;
  s := case when me = b.player_a then 'A' when me = b.player_b then 'B' end;
  if s is null then raise exception 'Dit is niet jouw battle.'; end if;
  o := case s when 'A' then 'B' else 'A' end;
  if p_action not in ('flex', 'roast', 'charm', 'signature', 'switch', 'forfeit') then raise exception 'Onbekende zet.'; end if;
  if p_action <> 'forfeit' and (b.state->'moved'->>s)::boolean then
    raise exception 'Je hebt deze ronde al gekozen. Wacht op je tegenstander.';
  end if;
  v_side := b.state->s; a := (v_side->>'active')::int;
  if p_action = 'signature' and coalesce((v_side->>'hype')::int, 0) < 3 then raise exception 'Je hype is nog niet vol.'; end if;
  if p_action = 'switch' then
    if p_target is null or p_target < 0 or p_target >= jsonb_array_length(v_side->'hp') or p_target = a
       or (v_side->'hp'->>p_target)::int <= 0 then
      raise exception 'Kies een andere kaart die nog kan vechten.';
    end if;
  end if;

  update public.tbattle_hidden h set action = p_action, target = case when p_action = 'switch' then p_target end
    where h.battle_id = p_id and h.side = s;
  update public.tbattles set state = jsonb_set(state, array['moved', s], 'true'), updated_at = now() where id = p_id;

  if b.mode = 'pve' then
    ai := public._tb_ai(b.state, o, b.difficulty);
    update public.tbattle_hidden h set action = ai->>'a', target = (ai->>'t')::int where h.battle_id = p_id and h.side = o;
    perform public._tb_resolve(p_id);
  elsif p_action = 'forfeit' or (b.state->'moved'->>o)::boolean then
    perform public._tb_resolve(p_id);
  end if;

  select * into b from public.tbattles where id = p_id;
  return to_jsonb(b);
end $$;

revoke all on function public._tb_side(int[]) from public, anon, authenticated;
revoke all on function public._tb_ai(jsonb, text, text) from public, anon, authenticated;
revoke all on function public._tb_resolve(bigint) from public, anon, authenticated;
revoke all on function public._tb_dmg(int, int, float8, boolean) from public, anon, authenticated;
grant execute on function public.tb_start_pve(int[], text) to authenticated;
grant execute on function public.tb_respond(bigint, text, int[]) to authenticated;
grant execute on function public.tb_act(bigint, text, int) to authenticated;

-- #####################################################################
-- 2. KAMERS IN HET FRAT HOUSE
-- #####################################################################
-- pins: 13 plekken aan de muur (0 = leeg). Plek 1 is de grote gouden lijst.
create table if not exists public.rooms (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pins int[] not null default '{}',
  theme text not null default 'navy' check (theme in ('navy', 'crimson', 'forest', 'charcoal', 'cream')),
  motto text check (char_length(motto) <= 60),
  updated_at timestamptz not null default now()
);
alter table public.rooms enable row level security;
drop policy if exists "eigen kamer en kamers van vrienden lezen" on public.rooms;
create policy "eigen kamer en kamers van vrienden lezen" on public.rooms
  for select to authenticated using (
    auth.uid() = user_id
    or exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = rooms.user_id)
  );
revoke insert, update, delete on public.rooms from anon, authenticated;

-- Je muur en kamer aanpassen (enkel met kaarten die je bezit)
create or replace function public.set_room(p_pins int[], p_theme text, p_motto text default null) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if coalesce(array_length(p_pins, 1), 0) > 13 then raise exception 'Er passen maar 13 kaarten aan je muur.'; end if;
  if exists (select 1 from unnest(p_pins) x where x is null) then raise exception 'Ongeldige muur.'; end if;
  if (select count(*) from unnest(p_pins) x where x <> 0) <> (select count(distinct x) from unnest(p_pins) x where x <> 0) then
    raise exception 'Elke kaart mag maar één keer aan je muur hangen.';
  end if;
  if exists (select 1 from unnest(p_pins) x where x <> 0
             and not exists (select 1 from public.user_cards uc where uc.user_id = me and uc.card_id = x)) then
    raise exception 'Je kan enkel kaarten ophangen die je bezit.';
  end if;
  if p_theme not in ('navy', 'crimson', 'forest', 'charcoal', 'cream') then raise exception 'Onbekende kleur.'; end if;
  insert into public.rooms (user_id, pins, theme, motto, updated_at)
  values (me, p_pins, p_theme, nullif(left(trim(coalesce(p_motto, '')), 60), ''), now())
  on conflict (user_id) do update set pins = excluded.pins, theme = excluded.theme, motto = excluded.motto, updated_at = now();
end $$;
grant execute on function public.set_room(int[], text, text) to authenticated;

-- Gewonnen/verloren battles van jezelf of een vriend (voor de trofeeën in de kamer)
create or replace function public.room_battle_stats(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p_user = auth.uid()
      or exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = p_user)
    then jsonb_build_object(
      'wins', (select count(*) from public.tbattles where status = 'done'
               and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'))),
      'pvp_wins', (select count(*) from public.tbattles where status = 'done' and mode = 'pvp'
               and ((player_a = p_user and winner = 'A') or (player_b = p_user and winner = 'B'))),
      'hard_wins', (select count(*) from public.tbattles where status = 'done' and mode = 'pve' and difficulty = 'hard'
               and player_a = p_user and winner = 'A'),
      'losses', (select count(*) from public.tbattles where status = 'done'
               and ((player_a = p_user and winner = 'B') or (player_b = p_user and winner = 'A'))))
    else null end;
$$;
grant execute on function public.room_battle_stats(uuid) to authenticated;

-- Wie van je vrienden heeft vandaag al gespeeld? (licht in het raam van het Frat House)
create or replace function public.house_today() returns table (user_id uuid, played boolean)
language sql stable security definer set search_path = public as $$
  select f.friend_id, exists (
    select 1 from public.wordle_games g where g.user_id = f.friend_id and g.status <> 'playing'
      and g.round_date = (now() at time zone 'Europe/Brussels')::date)
  from public.friendships f where f.user_id = auth.uid();
$$;
grant execute on function public.house_today() to authenticated;
