-- =====================================================================
-- RIZZ ACADEMY — update 08: Friends-pagina, geen kamers meer claimen
--
-- 1. Nieuwe accounts worden niet meer automatisch met iedereen bevriend:
--    je voegt zelf vrienden toe (met hun code of rechtstreeks vanuit de lijst).
--    Bestaande vriendschappen blijven gewoon bestaan.
-- 2. De kamers in het Frat House horen bij de personen van de kaarten,
--    niet bij een account: "Dit is mijn kamer" bestaat niet meer.
-- 3. friends_overview(): alles voor de Friends-pagina in één keer
--    (vrienden met hun stats, verzoeken, en wie je nog kan toevoegen).
-- 4. De gedetailleerde stats (cijfers, trofeeën) van iemand zie je enkel als
--    jullie vrienden zijn.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-07-rooster-admin.sql uit.
-- =====================================================================

-- 1. Niet meer automatisch bevriend -------------------------------------------------------
drop trigger if exists on_profile_befriend on public.profiles;

-- 2. Geen kamers meer claimen ------------------------------------------------------------
update public.profiles set room = null where room is not null;
revoke execute on function public.claim_room(text) from authenticated;

-- 3. Vriendschapsverzoeken ---------------------------------------------------------------
-- Verzoek via code: een admin-account is niet te vinden
create or replace function public.send_friend_request(p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_target public.profiles;
  v_reverse bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if public._is_admin_user(me) then raise exception 'Een admin-account kan geen vrienden hebben.'; end if;

  select * into v_target from public.profiles where friend_code = upper(trim(p_code));
  if not found or public._is_admin_user(v_target.id) then raise exception 'Geen account gevonden met die code.'; end if;
  if v_target.id = me then raise exception 'Dat is je eigen code.'; end if;

  if exists (select 1 from public.friendships where user_id = me and friend_id = v_target.id) then
    raise exception '% is al je vriend.', v_target.display_name;
  end if;

  -- Had de ander jou al een verzoek gestuurd? Dan meteen vrienden.
  select id into v_reverse from public.friend_requests where sender_id = v_target.id and recipient_id = me;
  if found then
    insert into public.friendships (user_id, friend_id) values (me, v_target.id), (v_target.id, me) on conflict do nothing;
    delete from public.friend_requests where id = v_reverse;
    return jsonb_build_object('status', 'accepted', 'name', v_target.display_name);
  end if;

  if exists (select 1 from public.friend_requests where sender_id = me and recipient_id = v_target.id) then
    raise exception 'Je hebt al een verzoek gestuurd naar %.', v_target.display_name;
  end if;

  insert into public.friend_requests (sender_id, recipient_id) values (me, v_target.id);
  return jsonb_build_object('status', 'sent', 'name', v_target.display_name);
end $$;
grant execute on function public.send_friend_request(text) to authenticated;

-- Verzoek rechtstreeks vanuit de lijst "Op de campus"
create or replace function public.send_friend_request_to(p_user uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  select friend_code into v_code from public.profiles where id = p_user;
  if v_code is null or public._is_admin_user(p_user) then raise exception 'Dit account bestaat niet.'; end if;
  return public.send_friend_request(v_code);
end $$;
grant execute on function public.send_friend_request_to(uuid) to authenticated;

-- Vriend verwijderen (beide kanten tegelijk)
create or replace function public.remove_friend(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  delete from public.friendships
    where (user_id = auth.uid() and friend_id = p_user) or (user_id = p_user and friend_id = auth.uid());
end $$;
grant execute on function public.remove_friend(uuid) to authenticated;

-- 4. Alles voor de Friends-pagina -----------------------------------------------------------
create or replace function public.friends_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id),
  stats as (
    select p.id, p.display_name, p.avatar_url,
      (select count(distinct uc.card_id)::int from public.user_cards uc where uc.user_id = p.id) as cards,
      (select count(distinct uc.card_id)::int from public.user_cards uc join public.cards c on c.id = uc.card_id
        where uc.user_id = p.id and c.rarity = 'legendary') as legendaries,
      (select count(*)::int from public.exam_results e where e.user_id = p.id and e.grade = 'F') as fs,
      (select count(*)::int from public.exam_results e where e.user_id = p.id and e.grade = 'A') as a_s,
      (select e.grade from public.exam_results e where e.user_id = p.id and e.status = 'done'
        and e.exam_date = (now() at time zone 'Europe/Brussels')::date limit 1) as today,
      (select count(*)::int from public.tbattles b where b.status = 'done'
        and ((b.player_a = p.id and b.winner = 'A') or (b.player_b = p.id and b.winner = 'B'))) as wins,
      (select count(*)::int from public.tbattles b where b.status = 'done'
        and ((b.player_a = p.id and b.winner = 'B') or (b.player_b = p.id and b.winner = 'A'))) as losses
    from public.profiles p, me
    where p.id in (select f.friend_id from public.friendships f where f.user_id = me.id)
  )
  select case when (select id from me) is null then null else jsonb_build_object(
    'friends', coalesce((select jsonb_agg(to_jsonb(s) order by s.display_name) from stats s), '[]'::jsonb),
    'incoming', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'user_id', p.id, 'display_name', p.display_name, 'avatar_url', p.avatar_url)
                           order by r.created_at desc)
                          from public.friend_requests r join public.profiles p on p.id = r.sender_id, me
                          where r.recipient_id = me.id and not public._is_admin_user(p.id)), '[]'::jsonb),
    'outgoing', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'user_id', p.id, 'display_name', p.display_name, 'avatar_url', p.avatar_url)
                           order by r.created_at desc)
                          from public.friend_requests r join public.profiles p on p.id = r.recipient_id, me
                          where r.sender_id = me.id), '[]'::jsonb),
    'others', case when public._is_admin_user((select id from me)) then '[]'::jsonb else
              coalesce((select jsonb_agg(jsonb_build_object('user_id', p.id, 'display_name', p.display_name, 'avatar_url', p.avatar_url)
                           order by p.display_name)
                          from public.profiles p, me
                          where p.id <> me.id and not public._is_admin_user(p.id)
                            and not exists (select 1 from public.friendships f where f.user_id = me.id and f.friend_id = p.id)
                            and not exists (select 1 from public.friend_requests r
                                            where (r.sender_id = me.id and r.recipient_id = p.id) or (r.sender_id = p.id and r.recipient_id = me.id))),
                       '[]'::jsonb) end)
  end;
$$;
grant execute on function public.friends_overview() to authenticated;

-- 5. Gedetailleerde stats: enkel van jezelf of van een vriend (een admin ziet alles) ----------
create or replace function public.member_room(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null
      or not (p_user = auth.uid()
              or public._is_admin_user(auth.uid())
              or exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = p_user)) then null
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
