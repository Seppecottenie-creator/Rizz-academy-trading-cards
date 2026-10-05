-- =====================================================================
-- RIZZ ACADEMY — update 07: nieuw rooster, onzichtbare admin, geen Wordle-hulp meer
--
-- 1. Rooster: ma English (Wordle) · di Math · wo Phys. Ed. (basketbal) · do History
--    vr Physics (kanon) · za Party (darts) · zo Party (blackjack)
-- 2. Admin-accounts (bv. seppe.cottenie@outlook.com) zijn onzichtbaar voor anderen:
--    niemand kan ermee bevriend zijn, ze wonen niet in het Frat House, en niemand
--    ziet hun kaarten, kamer of statistieken.
-- 3. Wordle-hulp (letter onthullen / 7e poging kopen) bestaat niet meer.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-06-lessenrooster.sql uit.
-- =====================================================================

-- 1. Rooster -----------------------------------------------------------------------------
create or replace function public._exam_game(p_date date) returns text
language sql immutable as $$
  select (array['wordle', 'math', 'hoops', 'history', 'launch', 'darts', 'blackjack'])[extract(isodow from p_date)::int];
$$;

-- Grenzen per spel: [laagste score, hoogste score, minimum aantal seconden, A, B, C, D]
create or replace function public._exam_rules(p_game text) returns int[]
language sql immutable as $$
  select case p_game
    when 'math'      then array[0, 80, 55, 24, 18, 12, 7]      -- juiste sommen in 60 seconden
    when 'hoops'     then array[0, 10, 8, 8, 6, 4, 2]          -- raak uit 10 worpen
    when 'history'   then array[0, 10, 12, 9, 7, 5, 3]         -- juist uit 10 vragen
    when 'launch'    then array[0, 8, 8, 6, 5, 3, 1]           -- raak uit 8 schoten
    when 'darts'     then array[0, 300, 6, 170, 125, 85, 45]   -- punten met 6 pijlen
    when 'blackjack' then array[0, 400, 6, 160, 125, 100, 70] -- chips na 10 handen (start 100)
    when 'pong'      then array[0, 6, 6, 6, 5, 4, 2]
    when 'pour'      then array[0, 500, 8, 440, 380, 300, 200]
  end;
$$;

-- 2. Admins onzichtbaar ---------------------------------------------------------------------
create or replace function public._is_admin_user(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins a where a.user_id = p_user);
$$;
revoke all on function public._is_admin_user(uuid) from public, anon, authenticated;

-- Geen vriendschappen met een admin, langs welke weg dan ook
create or replace function public._no_admin_friends() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public._is_admin_user(new.user_id) or public._is_admin_user(new.friend_id) then return null; end if;
  return new;
end $$;
drop trigger if exists no_admin_friends on public.friendships;
create trigger no_admin_friends before insert on public.friendships
  for each row execute function public._no_admin_friends();

-- Wie admin wordt, verliest meteen al zijn vriendschappen
create or replace function public._admin_unfriend() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.friendships where user_id = new.user_id or friend_id = new.user_id;
  delete from public.friend_requests where sender_id = new.user_id or recipient_id = new.user_id;
  update public.profiles set room = null where id = new.user_id;
  return new;
end $$;
drop trigger if exists admin_unfriend on public.admins;
create trigger admin_unfriend after insert on public.admins
  for each row execute function public._admin_unfriend();

delete from public.friendships f where public._is_admin_user(f.user_id) or public._is_admin_user(f.friend_id);
delete from public.friend_requests r where public._is_admin_user(r.sender_id) or public._is_admin_user(r.recipient_id);
update public.profiles set room = null where public._is_admin_user(id);
update public.trade_requests t set status = 'cancelled', updated_at = now()
  where status = 'pending' and (public._is_admin_user(t.proposer_id) or public._is_admin_user(t.recipient_id));
update public.tbattles b set status = 'cancelled', updated_at = now()
  where mode = 'pvp' and status in ('pending', 'active') and (public._is_admin_user(b.player_a) or public._is_admin_user(b.player_b));

-- Het huis: admins wonen er niet
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
  where auth.uid() is not null and not public._is_admin_user(p.id);
$$;
grant execute on function public.house_members() to authenticated;

-- Kamer/statistieken van een admin: enkel voor de admin zelf (of een andere admin)
create or replace function public.member_room(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null
      or (public._is_admin_user(p_user) and p_user <> auth.uid() and not public._is_admin_user(auth.uid())) then null
    else jsonb_build_object(
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

-- Kamers lezen: niet die van een admin
drop policy if exists "kamers lezen" on public.rooms;
create policy "kamers lezen" on public.rooms for select to authenticated
  using (auth.uid() = user_id or not public._is_admin_user(user_id));

-- 3. Geen Wordle-hulp meer ----------------------------------------------------------------------
revoke execute on function public.wordle_hint(int) from authenticated;
revoke execute on function public.wordle_extra_guess(int) from authenticated;
