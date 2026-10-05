-- =====================================================================
-- RIZZ ACADEMY — update 05: iedereen woont in het Frat House
--
-- 1. Iedereen met een account is automatisch bevriend met iedereen
--    (ook wie later nog registreert). Vriendencodes zijn niet meer nodig.
-- 2. Elke persoon van de kaarten heeft een vaste kamer in het huis.
--    Je account wordt aan je kamer gekoppeld: automatisch op basis van je naam,
--    of je kiest zelf je kamer (één keer, en enkel als ze nog vrij is).
-- 3. Iedereen kan de kamer van iedereen bekijken.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-04-campus.sql uit.
-- =====================================================================

-- 1. Iedereen bevriend ------------------------------------------------------------
insert into public.friendships (user_id, friend_id)
select a.id, b.id from public.profiles a cross join public.profiles b where a.id <> b.id
on conflict do nothing;
delete from public.friend_requests;

create or replace function public.befriend_everyone() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.friendships (user_id, friend_id)
  select new.id, p.id from public.profiles p where p.id <> new.id
  union all
  select p.id, new.id from public.profiles p where p.id <> new.id
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists on_profile_befriend on public.profiles;
create trigger on_profile_befriend after insert on public.profiles
  for each row execute function public.befriend_everyone();
revoke all on function public.befriend_everyone() from public, anon, authenticated;

-- 2. Kamers -------------------------------------------------------------------------
alter table public.profiles add column if not exists room text;
create unique index if not exists profiles_room_key on public.profiles (room) where room is not null;

-- Je kamer kiezen (enkel een kamer van iemand van de kaarten, en enkel als ze vrij is)
create or replace function public.claim_room(p_room text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if not exists (select 1 from public.cards where person = p_room and rarity <> 'cat') then
    raise exception 'Deze kamer bestaat niet.';
  end if;
  if exists (select 1 from public.profiles where room = p_room and id <> auth.uid()) then
    raise exception 'Deze kamer is al bezet.';
  end if;
  update public.profiles set room = p_room where id = auth.uid();
end $$;
grant execute on function public.claim_room(text) to authenticated;

-- Alle bewoners met hun kamer, of ze vandaag speelden en hoeveel kaarten ze hebben
create or replace function public.house_members()
returns table (user_id uuid, display_name text, avatar_url text, room text, played boolean, cards int, legendaries int)
language sql stable security definer set search_path = public as $$
  select p.id, p.display_name, p.avatar_url, p.room,
    exists (select 1 from public.wordle_games g where g.user_id = p.id and g.status <> 'playing'
            and g.round_date = (now() at time zone 'Europe/Brussels')::date),
    (select count(distinct uc.card_id)::int from public.user_cards uc join public.cards c on c.id = uc.card_id
      where uc.user_id = p.id and c.rarity <> 'cat'),
    (select count(distinct uc.card_id)::int from public.user_cards uc join public.cards c on c.id = uc.card_id
      where uc.user_id = p.id and c.rarity = 'legendary')
  from public.profiles p
  where auth.uid() is not null;
$$;
grant execute on function public.house_members() to authenticated;

-- 3. Iedereen kan elke kamer bekijken ---------------------------------------------------
drop policy if exists "eigen kamer en kamers van vrienden lezen" on public.rooms;
drop policy if exists "kamers lezen" on public.rooms;
create policy "kamers lezen" on public.rooms for select to authenticated using (true);

-- Alles wat je nodig hebt om een kamer te tonen: muur, verzameling, Wordles en battles
create or replace function public.member_room(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'pins', (select to_jsonb(r.pins) from public.rooms r where r.user_id = p_user),
    'theme', (select r.theme from public.rooms r where r.user_id = p_user),
    'motto', (select r.motto from public.rooms r where r.user_id = p_user),
    'cards', coalesce((select jsonb_agg(distinct uc.card_id) from public.user_cards uc where uc.user_id = p_user), '[]'::jsonb),
    'plays', coalesce((select jsonb_agg(jsonb_build_object('play_date', g.round_date, 'solved', g.status = 'won', 'attempts', g.attempts) order by g.round_date)
                       from public.wordle_games g where g.user_id = p_user and g.status <> 'playing'), '[]'::jsonb),
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
