-- =====================================================================
-- RIZZ ACADEMY — update 26: Sportsbook (inzetten op echte voetbalwedstrijden)
--
-- - Wedstrijden van Champions League, Premier League, Serie A, La Liga en Ligue 1 komen automatisch
--   binnen via de functie "rizz-voetbal" (gratis football-data.org, elk uur).
--   Pro League en Nations League zitten niet in die gratis API: die voegt de admin zelf toe.
-- - Iedereen kan per wedstrijd gratis voorspellen (1 / X / 2). Die stemmen bepalen de quoteringen:
--   hoe meer stemmen op een uitslag, hoe lager de quotering. Je quotering ligt vast op het moment dat je inzet.
-- - Inzetten: 5 tot 50 credits, één inzet per wedstrijd, tot aan de aftrap. Je stem volgt je inzet.
-- - Na de wedstrijd betaalt de server automatisch uit (inzet × quotering). Afgelast = inzet terug.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-14-casino-zonder-limiet.sql uit.
-- =====================================================================

-- 1. Tabellen ----------------------------------------------------------------------------------------
create table if not exists public.fb_matches (
  id bigserial primary key,
  ext_id bigint unique,                         -- id bij football-data.org (null = door de admin toegevoegd)
  competition text not null,                    -- CL, PL, SA, PD, FL1, BPL (Pro League), UNL (Nations League)
  home text not null,
  away text not null,
  kickoff timestamptz not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'finished', 'cancelled')),
  home_goals int,
  away_goals int,
  settled boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists fb_matches_kickoff_idx on public.fb_matches (kickoff);
alter table public.fb_matches enable row level security;
drop policy if exists "wedstrijden lezen" on public.fb_matches;
create policy "wedstrijden lezen" on public.fb_matches for select to authenticated using (true);

create table if not exists public.fb_votes (
  match_id bigint not null references public.fb_matches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  pick text not null check (pick in ('1', 'X', '2')),
  primary key (match_id, user_id)
);
alter table public.fb_votes enable row level security; -- geen policies: enkel via de functies

create table if not exists public.fb_bets (
  id bigserial primary key,
  match_id bigint not null references public.fb_matches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  pick text not null check (pick in ('1', 'X', '2')),
  stake int not null,
  odds numeric(5, 2) not null,
  payout int,
  status text not null default 'open' check (status in ('open', 'won', 'lost', 'void')),
  created_at timestamptz not null default now(),
  unique (match_id, user_id)
);
alter table public.fb_bets enable row level security;
drop policy if exists "eigen voetbalinzetten lezen" on public.fb_bets;
create policy "eigen voetbalinzetten lezen" on public.fb_bets for select to authenticated using (auth.uid() = user_id);

create table if not exists public.fb_config (
  id int primary key default 1 check (id = 1),
  last_sync timestamptz,
  last_msg text
);
alter table public.fb_config enable row level security; -- enkel de server
insert into public.fb_config (id) values (1) on conflict do nothing;

-- 2. Quoteringen uit de stemmen ----------------------------------------------------------------------
-- Startpunt (zonder stemmen): thuis 44%, gelijk 27%, uit 29%, telt als 6 "neppe" stemmen.
-- Kans = (stemmen + 6 × startpunt) / (alle stemmen + 6). Quotering = 0,93 / kans (7% voor het casino),
-- afgerond op 0,05 en tussen 1,10 en 10.
create or replace function public._fb_odds(p_match bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  with v as (
    select count(*) filter (where pick = '1') as v1, count(*) filter (where pick = 'X') as vx,
           count(*) filter (where pick = '2') as v2, count(*) as n
    from public.fb_votes where match_id = p_match
  ), p as (
    select v.*, (v1 + 6 * .44) / (n + 6) as p1, (vx + 6 * .27) / (n + 6) as px, (v2 + 6 * .29) / (n + 6) as p2 from v
  )
  select jsonb_build_object(
    '1', round(least(10, greatest(1.10, round(.93 / p1 * 20) / 20)), 2),
    'X', round(least(10, greatest(1.10, round(.93 / px * 20) / 20)), 2),
    '2', round(least(10, greatest(1.10, round(.93 / p2 * 20) / 20)), 2),
    'votes', jsonb_build_object('1', v1, 'X', vx, '2', v2))
  from p;
$$;
revoke all on function public._fb_odds(bigint) from public, anon, authenticated;

-- 3. Uitbetalen ---------------------------------------------------------------------------------------
create or replace function public._fb_settle(p_match bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare m public.fb_matches; res text; bt public.fb_bets; pay int;
begin
  select * into m from public.fb_matches where id = p_match for update;
  if not found or m.settled or m.status = 'scheduled' then return; end if;
  res := case when m.status = 'cancelled' then null
              when m.home_goals > m.away_goals then '1' when m.home_goals = m.away_goals then 'X' else '2' end;
  for bt in select * from public.fb_bets where match_id = p_match and status = 'open' for update loop
    if m.status = 'cancelled' then pay := bt.stake;
    elsif bt.pick = res then pay := floor(bt.stake * bt.odds)::int;
    else pay := 0; end if;
    if pay > 0 then update public.user_wallet set polycoins = polycoins + pay where user_id = bt.user_id; end if;
    update public.fb_bets set payout = pay,
      status = case when m.status = 'cancelled' then 'void' when pay > 0 then 'won' else 'lost' end
    where id = bt.id;
    insert into public.casino_plays (user_id, game, bet, payout, result)
    values (bt.user_id, 'football', bt.stake, pay, jsonb_build_object('match', m.id, 'home', m.home, 'away', m.away,
            'pick', bt.pick, 'odds', bt.odds, 'score', concat(m.home_goals, '-', m.away_goals), 'outcome',
            case when m.status = 'cancelled' then 'void' when pay > 0 then 'win' else 'lose' end));
  end loop;
  update public.fb_matches set settled = true where id = p_match;
end $$;
revoke all on function public._fb_settle(bigint) from public, anon, authenticated;

-- 4. Alles voor het scherm ----------------------------------------------------------------------------
create or replace function public.fb_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'is_admin', public._is_admin_user(auth.uid()),
    'last_sync', (select last_sync from public.fb_config where id = 1),
    'matches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'competition', m.competition, 'home', m.home, 'away', m.away, 'kickoff', m.kickoff,
        'status', m.status, 'home_goals', m.home_goals, 'away_goals', m.away_goals, 'settled', m.settled,
        'manual', m.ext_id is null, 'started', m.kickoff <= now(),
        'odds', public._fb_odds(m.id),
        'my_vote', (select pick from public.fb_votes v where v.match_id = m.id and v.user_id = auth.uid()),
        'my_bet', (select jsonb_build_object('pick', b.pick, 'stake', b.stake, 'odds', b.odds, 'payout', b.payout, 'status', b.status)
                   from public.fb_bets b where b.match_id = m.id and b.user_id = auth.uid()))
        order by m.kickoff)
      from public.fb_matches m
      where m.kickoff between now() - interval '3 days' and now() + interval '14 days'
         or (not m.settled and m.status <> 'cancelled' and m.kickoff < now())
         or exists (select 1 from public.fb_bets b where b.match_id = m.id and b.user_id = auth.uid() and b.status = 'open')), '[]'::jsonb)
  ) end;
$$;
grant execute on function public.fb_overview() to authenticated;

-- 5. Stemmen en inzetten ------------------------------------------------------------------------------
create or replace function public.fb_vote(p_match bigint, p_pick text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m public.fb_matches;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_pick not in ('1', 'X', '2') then raise exception 'Kies 1, X of 2.'; end if;
  select * into m from public.fb_matches where id = p_match;
  if not found then raise exception 'Wedstrijd niet gevonden.'; end if;
  if m.kickoff <= now() or m.status <> 'scheduled' then raise exception 'De wedstrijd is al begonnen.'; end if;
  if exists (select 1 from public.fb_bets where match_id = p_match and user_id = auth.uid()) then
    raise exception 'Je hebt al ingezet: je stem volgt je inzet.';
  end if;
  insert into public.fb_votes (match_id, user_id, pick) values (p_match, auth.uid(), p_pick)
  on conflict (match_id, user_id) do update set pick = excluded.pick;
  return public._fb_odds(p_match);
end $$;
grant execute on function public.fb_vote(bigint, text) to authenticated;

create or replace function public.fb_bet(p_match bigint, p_pick text, p_stake int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m public.fb_matches; o numeric; v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_pick not in ('1', 'X', '2') then raise exception 'Kies 1, X of 2.'; end if;
  select * into m from public.fb_matches where id = p_match for update;
  if not found then raise exception 'Wedstrijd niet gevonden.'; end if;
  if m.kickoff <= now() or m.status <> 'scheduled' then raise exception 'Inzetten kan enkel tot aan de aftrap.'; end if;
  if exists (select 1 from public.fb_bets where match_id = p_match and user_id = auth.uid()) then
    raise exception 'Je hebt al ingezet op deze wedstrijd.';
  end if;
  -- eerst je stem op je keuze zetten, dan de quotering vastleggen
  insert into public.fb_votes (match_id, user_id, pick) values (p_match, auth.uid(), p_pick)
  on conflict (match_id, user_id) do update set pick = excluded.pick;
  o := (public._fb_odds(p_match)->>p_pick)::numeric;
  perform public._casino_take(p_stake);
  insert into public.fb_bets (match_id, user_id, pick, stake, odds) values (p_match, auth.uid(), p_pick, p_stake, o);
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid();
  return jsonb_build_object('pick', p_pick, 'stake', p_stake, 'odds', o, 'wallet', v_coins);
end $$;
grant execute on function public.fb_bet(bigint, text, int) to authenticated;

-- 6. Admin: zelf wedstrijden toevoegen, uitslag invullen, afgelasten ----------------------------------
create or replace function public.fb_admin_add(p_competition text, p_home text, p_away text, p_kickoff timestamptz) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  if p_competition not in ('CL', 'PL', 'SA', 'PD', 'FL1', 'BPL', 'UNL') then raise exception 'Onbekende competitie.'; end if;
  if coalesce(trim(p_home), '') = '' or coalesce(trim(p_away), '') = '' then raise exception 'Vul beide ploegen in.'; end if;
  if p_kickoff <= now() then raise exception 'De aftrap moet in de toekomst liggen.'; end if;
  insert into public.fb_matches (competition, home, away, kickoff) values (p_competition, trim(p_home), trim(p_away), p_kickoff)
  returning id into v_id;
  return v_id;
end $$;
grant execute on function public.fb_admin_add(text, text, text, timestamptz) to authenticated;

create or replace function public.fb_admin_result(p_match bigint, p_home_goals int, p_away_goals int) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  if p_home_goals is null or p_away_goals is null or p_home_goals < 0 or p_away_goals < 0 then raise exception 'Ongeldige score.'; end if;
  update public.fb_matches set status = 'finished', home_goals = p_home_goals, away_goals = p_away_goals
  where id = p_match and not settled and kickoff <= now();
  if not found then raise exception 'Kan nog niet: de wedstrijd is nog niet begonnen of is al afgerekend.'; end if;
  perform public._fb_settle(p_match);
end $$;
grant execute on function public.fb_admin_result(bigint, int, int) to authenticated;

create or replace function public.fb_admin_cancel(p_match bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  update public.fb_matches set status = 'cancelled' where id = p_match and not settled;
  perform public._fb_settle(p_match);
end $$;
grant execute on function public.fb_admin_cancel(bigint) to authenticated;

-- 7. Binnenkomende wedstrijden van de functie rizz-voetbal (enkel de server) ---------------------------
-- p_matches: [{ext_id, competition, home, away, kickoff, status, home_goals, away_goals}]
create or replace function public.fb_sync(p_matches jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x jsonb; v_id bigint; n int := 0; s int := 0;
begin
  for x in select * from jsonb_array_elements(p_matches) loop
    insert into public.fb_matches (ext_id, competition, home, away, kickoff, status, home_goals, away_goals)
    values ((x->>'ext_id')::bigint, x->>'competition', x->>'home', x->>'away', (x->>'kickoff')::timestamptz,
            x->>'status', (x->>'home_goals')::int, (x->>'away_goals')::int)
    on conflict (ext_id) do update set
      home = excluded.home, away = excluded.away, kickoff = excluded.kickoff,
      status = case when fb_matches.settled then fb_matches.status else excluded.status end,
      home_goals = case when fb_matches.settled then fb_matches.home_goals else excluded.home_goals end,
      away_goals = case when fb_matches.settled then fb_matches.away_goals else excluded.away_goals end
    returning id into v_id;
    n := n + 1;
    if x->>'status' in ('finished', 'cancelled') then perform public._fb_settle(v_id); s := s + 1; end if;
  end loop;
  update public.fb_config set last_sync = now(), last_msg = format('%s wedstrijden, %s afgelopen', n, s) where id = 1;
  return jsonb_build_object('matches', n, 'finished', s);
end $$;
revoke all on function public.fb_sync(jsonb) from public, anon, authenticated;
grant execute on function public.fb_sync(jsonb) to service_role;

create or replace function public.fb_should_sync() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select last_sync < now() - interval '10 minutes' from public.fb_config where id = 1), true);
$$;
revoke all on function public.fb_should_sync() from public, anon, authenticated;
grant execute on function public.fb_should_sync() to service_role;

-- 8. Elk uur de wedstrijden ophalen (functie rizz-voetbal) ---------------------------------------------
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'rizz-voetbal';
    perform cron.schedule('rizz-voetbal', '17 * * * *', $cron$
      select net.http_post(
        url := 'https://njrqohhmlosvkandtkll.supabase.co/functions/v1/rizz-voetbal',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5qcnFvaGhtbG9zdmthbmR0a2xsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExMDY1NTAsImV4cCI6MjEwNjY4MjU1MH0.c19_JTKlto6buo8jeekMBSwwjPa_Le_tKjDsimPwNZY'),
        body := '{"action":"sync"}'::jsonb
      );
    $cron$);
  end if;
end $$;

notify pgrst, 'reload schema';
