-- =====================================================================
-- RIZZ ACADEMY — update 15: ideeën uit de groep
--
-- 1. Emotes tijdens gevechten (zoals in Clash Royale)
-- 2. Trofeeën geven een beloning in credits (één keer per trofee, de server controleert)
-- 3. Online / AFK / offline zien bij je vrienden en in een gevecht
-- 4. Inruilen in The Vault: 2 dubbele commons -> een willekeurige epic,
--    of 3 dubbele commons -> een epic van een persoon naar keuze
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-14 uit.
-- =====================================================================

-- 1. Emotes ----------------------------------------------------------------------------------------
create table if not exists public.tb_emotes (
  id bigserial primary key,
  battle_id bigint not null references public.tbattles(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emote text not null,
  created_at timestamptz not null default now()
);
create index if not exists tb_emotes_battle_idx on public.tb_emotes (battle_id, id);
alter table public.tb_emotes enable row level security;
drop policy if exists "emotes van je eigen gevechten lezen" on public.tb_emotes;
create policy "emotes van je eigen gevechten lezen" on public.tb_emotes for select to authenticated
  using (exists (select 1 from public.tbattles b where b.id = battle_id and (b.player_a = auth.uid() or b.player_b = auth.uid())));

create or replace function public.tb_emote(p_id bigint, p_emote text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare b public.tbattles;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_emote not in ('lol', 'cool', 'mad', 'gg', 'cry', 'fire') then raise exception 'Onbekende emote.'; end if;
  select * into b from public.tbattles where id = p_id;
  if not found or (b.player_a <> auth.uid() and coalesce(b.player_b, '00000000-0000-0000-0000-000000000000') <> auth.uid()) then
    raise exception 'Dit is niet jouw gevecht.';
  end if;
  if b.status not in ('active', 'done') or (b.status = 'done' and b.updated_at < now() - interval '15 minutes') then
    raise exception 'Dit gevecht is voorbij.';
  end if;
  -- niet spammen: max. één emote per 2 seconden
  if exists (select 1 from public.tb_emotes where battle_id = p_id and user_id = auth.uid() and created_at > now() - interval '2 seconds') then
    return;
  end if;
  insert into public.tb_emotes (battle_id, user_id, emote) values (p_id, auth.uid(), p_emote);
end $$;
grant execute on function public.tb_emote(bigint, text) to authenticated;

-- 2. Trofeeën met beloning -----------------------------------------------------------------------------
create table if not exists public.trophy_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  key text not null,
  reward int not null,
  claimed_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table public.trophy_claims enable row level security;
drop policy if exists "eigen trofeeën lezen" on public.trophy_claims;
create policy "eigen trofeeën lezen" on public.trophy_claims for select to authenticated using (auth.uid() = user_id);

-- Welke trofeeën heeft een speler behaald (zelfde regels als op de site)
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
  select k, d, r from best, fullset, bat, lateral (values
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
    ('flunked',       exists (select 1 from plays where grade = 'F'),           10)
  ) t(k, d, r);
$$;
revoke all on function public._trophies(uuid) from public, anon, authenticated;

create or replace function public.trophy_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'done', t.done, 'reward', t.reward,
           'claimed', exists (select 1 from public.trophy_claims c where c.user_id = auth.uid() and c.key = t.key))), '[]'::jsonb)
  from public._trophies(auth.uid()) t where auth.uid() is not null;
$$;
grant execute on function public.trophy_status() to authenticated;

create or replace function public.claim_trophy(p_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare t record; v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  select * into t from public._trophies(auth.uid()) x where x.key = p_key;
  if not found then raise exception 'Onbekende trofee.'; end if;
  if not t.done then raise exception 'Deze trofee heb je nog niet behaald.'; end if;
  insert into public.trophy_claims (user_id, key, reward) values (auth.uid(), p_key, t.reward) on conflict do nothing;
  if not found then raise exception 'Deze beloning heb je al opgehaald.'; end if;
  update public.user_wallet set polycoins = polycoins + t.reward where user_id = auth.uid() returning polycoins into v_coins;
  return jsonb_build_object('reward', t.reward, 'wallet', v_coins);
end $$;
grant execute on function public.claim_trophy(text) to authenticated;

-- 3. Online / AFK ---------------------------------------------------------------------------------------
-- last_seen: de app staat open · last_active: je deed iets (tikken, typen)
alter table public.profiles add column if not exists last_seen timestamptz;
alter table public.profiles add column if not exists last_active timestamptz;

create or replace function public.touch_presence(p_active boolean) returns void
language sql volatile security definer set search_path = public as $$
  update public.profiles set last_seen = now(), last_active = case when p_active then now() else last_active end
  where id = auth.uid();
$$;
grant execute on function public.touch_presence(boolean) to authenticated;

-- friends_overview opnieuw, nu met last_seen en last_active
create or replace function public.friends_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id),
  stats as (
    select p.id, p.display_name, p.avatar_url, p.last_seen, p.last_active,
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

-- 4. Inruilen in The Vault -------------------------------------------------------------------------------
-- 2 dubbele commons -> willekeurige epic (bij voorkeur een die je nog niet hebt)
-- 3 dubbele commons -> epic van een persoon naar keuze (bij voorkeur een die je nog niet hebt)
-- Je houdt altijd minstens 1 exemplaar van elke kaart.
create or replace function public.vault_tradeup(p_cards int[], p_person text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); n int; c record; v_card int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  n := coalesce(array_length(p_cards, 1), 0);
  if p_person is null and n <> 2 then raise exception 'Kies precies 2 dubbele commons.'; end if;
  if p_person is not null and n <> 3 then raise exception 'Kies precies 3 dubbele commons.'; end if;
  if p_person is not null and not exists (select 1 from public.cards where person = p_person and rarity = 'epic') then
    raise exception 'Deze persoon bestaat niet.';
  end if;
  for c in select x.id, count(*)::int as k from unnest(p_cards) x(id) group by x.id loop
    if not exists (select 1 from public.cards where id = c.id and rarity = 'common') then raise exception 'Je kan enkel commons inruilen.'; end if;
    if (select count(*) from public.user_cards where user_id = me and card_id = c.id) < c.k + 1 then
      raise exception 'Je kan enkel dubbels inruilen: van elke kaart hou je er minstens één.';
    end if;
    delete from public.user_cards where id in (select id from public.user_cards where user_id = me and card_id = c.id order by created_at desc limit c.k);
  end loop;
  select id into v_card from public.cards x
  where x.rarity = 'epic' and (p_person is null or x.person = p_person)
  order by exists (select 1 from public.user_cards uc where uc.user_id = me and uc.card_id = x.id), random()
  limit 1;
  insert into public.user_cards (user_id, card_id) values (me, v_card);
  return jsonb_build_object('card_id', v_card);
end $$;
grant execute on function public.vault_tradeup(int[], text) to authenticated;
