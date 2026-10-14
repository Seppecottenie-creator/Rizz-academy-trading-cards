-- =====================================================================
-- RIZZ ACADEMY — update 24: opgeven tegen een vriend = winst voor de ander
--
-- Geeft je tegenstander op, dan krijg jij altijd je 25 credits voor de overwinning
-- (zoals bij een gewone overwinning: max. 3 beloonde gevechten tegen vrienden per dag).
-- Wie opgeeft, krijgt niets.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
-- =====================================================================
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
      -- Opgeven: de winnaar krijgt gewoon zijn 25 credits (max. 3 beloonde gevechten per dag), wie opgeeft krijgt niets
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
revoke all on function public._tb_resolve(bigint) from public, anon, authenticated;

notify pgrst, 'reload schema';
