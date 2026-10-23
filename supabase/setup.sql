-- =====================================================================
-- SETUP: volledige database voor een NIEUW, LEEG Supabase-project
-- Verzamelkaarten-site: accounts, kaarten, vrienden, ruilen, welkomstpakket,
-- dagelijks spel (Wordle, 1 ronde per dag), battles (Flex/Roast/Charm), kamers, shop en ideeënbus.
--
-- Gebruik: Supabase → SQL Editor → nieuwe query → dit VOLLEDIGE bestand plakken → Run.
-- Kies bij de waarschuwing "Run without RLS": het script zet RLS zelf aan.
-- Veilig om opnieuw uit te voeren.
--
-- Bevat GEEN kaarten: die voeg je daarna toe in public.cards (9 per persoon:
-- slot 1-6 common, 7-8 epic, 9 legendary).
-- =====================================================================

-- #####################################################################
-- BASIS: profielen, kaarten, collectie, polycoins, admins
-- #####################################################################
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now()
);
create table if not exists public.cards (
  id serial primary key,
  person text not null,                 -- naam van de vriend (of 'Katten' voor troostkaarten)
  slot int not null,                    -- 1-6 common, 7-8 epic, 9 legendary
  name text not null,
  rarity text not null check (rarity in ('common', 'epic', 'legendary', 'cat')),
  hp int not null default 60,
  attack int not null default 20,
  defense int not null default 15,
  image_url text,
  flavor_text text,
  special_name text,
  special_desc text,
  special_power int,
  unique (person, slot)
);
create table if not exists public.user_cards (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  card_id int not null references public.cards(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists user_cards_user_idx on public.user_cards (user_id, card_id);
create table if not exists public.user_wallet (
  user_id uuid primary key references auth.users(id) on delete cascade,
  polycoins int not null default 0 check (polycoins >= 0)
);
-- Tabel van het oude dagelijkse systeem; blijft bestaan omdat de statistieken ernaar kijken
create table if not exists public.daily_plays (
  user_id uuid not null references auth.users(id) on delete cascade,
  play_date date not null,
  attempts int,
  solved boolean not null default false,
  card_id int references public.cards(id),
  primary key (user_id, play_date)
);
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.profiles enable row level security;
alter table public.cards enable row level security;
alter table public.user_cards enable row level security;
alter table public.user_wallet enable row level security;
alter table public.daily_plays enable row level security;
alter table public.admins enable row level security;

drop policy if exists "profielen lezen" on public.profiles;
create policy "profielen lezen" on public.profiles for select to authenticated using (true);
drop policy if exists "eigen profiel aanpassen" on public.profiles;
create policy "eigen profiel aanpassen" on public.profiles for update to authenticated
  using (auth.uid() = id) with check (auth.uid() = id);
drop policy if exists "kaarten lezen" on public.cards;
create policy "kaarten lezen" on public.cards for select to authenticated using (true);
drop policy if exists "eigen kaarten lezen" on public.user_cards;
create policy "eigen kaarten lezen" on public.user_cards for select to authenticated using (auth.uid() = user_id);
drop policy if exists "eigen wallet lezen" on public.user_wallet;
create policy "eigen wallet lezen" on public.user_wallet for select to authenticated using (auth.uid() = user_id);
drop policy if exists "eigen spelletjes lezen" on public.daily_plays;
create policy "eigen spelletjes lezen" on public.daily_plays for select to authenticated using (auth.uid() = user_id);
drop policy if exists "eigen adminstatus lezen" on public.admins;
create policy "eigen adminstatus lezen" on public.admins for select to authenticated using (auth.uid() = user_id);

-- Gebruikers mogen enkel hun naam en profielfoto aanpassen; kaarten en admins nooit
revoke insert, update, delete on public.profiles, public.cards, public.admins from anon, authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;

-- #####################################################################
-- VRIENDEN + RUILEN
-- #####################################################################
alter table public.profiles add column if not exists friend_code text unique;

create or replace function public.generate_friend_code() returns text
language sql as $$
  select upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
$$;

-- handle_new_user krijgt er een unieke code bij voor nieuwe accounts
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  loop
    v_code := public.generate_friend_code();
    exit when not exists (select 1 from public.profiles where friend_code = v_code);
  end loop;
  insert into public.profiles (id, display_name, friend_code)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), split_part(new.email, '@', 1)),
    v_code
  );
  insert into public.user_wallet (user_id, polycoins) values (new.id, 0);
  return new;
end;
$$;

-- Backfill: bestaande accounts krijgen ook meteen een code
do $$
declare
  r record; v_code text;
begin
  for r in select id from public.profiles where friend_code is null loop
    loop
      v_code := public.generate_friend_code();
      exit when not exists (select 1 from public.profiles where friend_code = v_code);
    end loop;
    update public.profiles set friend_code = v_code where id = r.id;
  end loop;
end $$;

-- 2. Vriendschappen (twee rijen per vriendschap, één per richting) --------
create table if not exists public.friendships (
  user_id uuid not null references auth.users(id) on delete cascade,
  friend_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
alter table public.friendships enable row level security;

drop policy if exists "eigen vriendschappen lezen" on public.friendships;
create policy "eigen vriendschappen lezen" on public.friendships
  for select to authenticated using (auth.uid() = user_id or auth.uid() = friend_id);
-- Toevoegen gebeurt in 1 call met 2 rijen ((ik,vriend) en (vriend,ik)) —
-- de check hieronder laat elke rij toe zolang jij één van de twee kanten bent.
drop policy if exists "vriend toevoegen" on public.friendships;
create policy "vriend toevoegen" on public.friendships
  for insert to authenticated with check (auth.uid() = user_id or auth.uid() = friend_id);
-- Verwijderen: je kan de vriendschap in beide richtingen wissen, ook al
-- stond je zelf niet als user_id in die specifieke rij.
drop policy if exists "vriend verwijderen" on public.friendships;
create policy "vriend verwijderen" on public.friendships
  for delete to authenticated using (auth.uid() = user_id or auth.uid() = friend_id);

-- Vrienden mogen elkaars kaartenverzameling zien (nodig om iets te kunnen vragen in een ruil)
drop policy if exists "vrienden kaarten lezen" on public.user_cards;
create policy "vrienden kaarten lezen" on public.user_cards
  for select to authenticated using (
    exists (
      select 1 from public.friendships f
      where f.user_id = auth.uid() and f.friend_id = user_cards.user_id
    )
  );

-- 3. Ruilvoorstellen --------------------------------------------------------
create table if not exists public.trade_requests (
  id bigserial primary key,
  proposer_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  proposer_cards int[] not null default '{}',   -- kaarten die proposer geeft
  recipient_cards int[] not null default '{}',  -- kaarten die recipient geeft
  status text not null default 'pending' check (status in ('pending','accepted','cancelled')),
  turn uuid not null,           -- wie nu aan zet is om te reageren
  last_action_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (proposer_id <> recipient_id)
);
create index if not exists trade_requests_proposer_idx on public.trade_requests (proposer_id, status);
create index if not exists trade_requests_recipient_idx on public.trade_requests (recipient_id, status);

alter table public.trade_requests enable row level security;
drop policy if exists "eigen ruilvoorstellen lezen" on public.trade_requests;
create policy "eigen ruilvoorstellen lezen" on public.trade_requests
  for select to authenticated using (auth.uid() = proposer_id or auth.uid() = recipient_id);
-- Bewust GEEN insert/update/delete policy: alle schrijfacties verlopen via
-- de onderstaande functies (security definer), zodat eigendom van kaarten
-- altijd server-side gevalideerd wordt en nooit rechtstreeks aanpasbaar is.

-- 4. create_trade: nieuw ruilvoorstel aanmaken -----------------------------
create or replace function public.create_trade(
  p_friend_id uuid,
  p_my_cards int[],
  p_their_cards int[]
) returns public.trade_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_row public.trade_requests;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if me = p_friend_id then raise exception 'Je kan niet met jezelf ruilen.'; end if;
  if not exists (select 1 from public.friendships where user_id = me and friend_id = p_friend_id) then
    raise exception 'Jullie zijn geen vrienden.';
  end if;
  if coalesce(array_length(p_my_cards,1),0) = 0 and coalesce(array_length(p_their_cards,1),0) = 0 then
    raise exception 'Selecteer minstens één kaart.';
  end if;

  if exists (
    select 1 from (select unnest(coalesce(p_my_cards,'{}')) as card_id) x
    group by x.card_id
    having count(*) > (select count(*) from public.user_cards uc where uc.user_id = me and uc.card_id = x.card_id) - 1
  ) then
    raise exception 'Je kan enkel dubbels aanbieden (je houdt altijd minstens 1 exemplaar over).';
  end if;

  if exists (
    select 1 from (select unnest(coalesce(p_their_cards,'{}')) as card_id) x
    group by x.card_id
    having count(*) > (select count(*) from public.user_cards uc where uc.user_id = p_friend_id and uc.card_id = x.card_id) - 1
  ) then
    raise exception 'Je vriend heeft niet genoeg dubbels van de gevraagde kaart(en).';
  end if;

  insert into public.trade_requests (proposer_id, recipient_id, proposer_cards, recipient_cards, status, turn, last_action_by)
  values (me, p_friend_id, coalesce(p_my_cards,'{}'), coalesce(p_their_cards,'{}'), 'pending', p_friend_id, me)
  returning * into v_row;

  return v_row;
end;
$$;

-- 5. respond_trade: accepteren / tegenbod doen / annuleren -----------------
create or replace function public.respond_trade(
  p_trade_id bigint,
  p_action text,
  p_proposer_cards int[] default null,
  p_recipient_cards int[] default null
) returns public.trade_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  t public.trade_requests;
  v_card int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;

  select * into t from public.trade_requests where id = p_trade_id for update;
  if not found then raise exception 'Ruilvoorstel niet gevonden.'; end if;
  if me <> t.proposer_id and me <> t.recipient_id then
    raise exception 'Dit is niet jouw ruilvoorstel.';
  end if;
  if t.status <> 'pending' then
    raise exception 'Dit ruilvoorstel is al afgehandeld.';
  end if;

  if p_action = 'cancel' then
    update public.trade_requests set status = 'cancelled', updated_at = now(), last_action_by = me
      where id = p_trade_id returning * into t;
    return t;
  end if;

  if me <> t.turn then
    raise exception 'Het is niet jouw beurt.';
  end if;

  if p_action = 'counter' then
    if exists (
      select 1 from (select unnest(coalesce(p_proposer_cards, t.proposer_cards)) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.proposer_id and uc.card_id = x.card_id) - 1
    ) then
      raise exception 'De aanbieder heeft niet genoeg dubbels van de aangeboden kaart(en).';
    end if;
    if exists (
      select 1 from (select unnest(coalesce(p_recipient_cards, t.recipient_cards)) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.recipient_id and uc.card_id = x.card_id) - 1
    ) then
      raise exception 'De ontvanger heeft niet genoeg dubbels van de gevraagde kaart(en).';
    end if;

    update public.trade_requests set
      proposer_cards = coalesce(p_proposer_cards, t.proposer_cards),
      recipient_cards = coalesce(p_recipient_cards, t.recipient_cards),
      turn = case when me = t.proposer_id then t.recipient_id else t.proposer_id end,
      last_action_by = me,
      updated_at = now()
    where id = p_trade_id
    returning * into t;
    return t;
  end if;

  if p_action = 'accept' then
    if exists (
      select 1 from (select unnest(t.proposer_cards) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.proposer_id and uc.card_id = x.card_id) - 1
    ) then
      raise exception 'De aanbieder bezit de aangeboden kaart(en) niet meer als dubbel.';
    end if;
    if exists (
      select 1 from (select unnest(t.recipient_cards) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.recipient_id and uc.card_id = x.card_id) - 1
    ) then
      raise exception 'De ontvanger bezit de gevraagde kaart(en) niet meer als dubbel.';
    end if;

    foreach v_card in array t.proposer_cards loop
      delete from public.user_cards where id = (
        select id from public.user_cards where user_id = t.proposer_id and card_id = v_card limit 1
      );
      insert into public.user_cards (user_id, card_id) values (t.recipient_id, v_card);
    end loop;

    foreach v_card in array t.recipient_cards loop
      delete from public.user_cards where id = (
        select id from public.user_cards where user_id = t.recipient_id and card_id = v_card limit 1
      );
      insert into public.user_cards (user_id, card_id) values (t.proposer_id, v_card);
    end loop;

    update public.trade_requests set status = 'accepted', updated_at = now(), last_action_by = me
      where id = p_trade_id returning * into t;
    return t;
  end if;

  raise exception 'Onbekende actie.';
end;
$$;

grant execute on function public.create_trade(uuid, int[], int[]) to authenticated;
grant execute on function public.respond_trade(bigint, text, int[], int[]) to authenticated;

-- #####################################################################
-- REGISTRATIE-TRIGGER
-- #####################################################################

-- Bij registratie: automatisch profiel (met vriendencode) en wallet aanmaken
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- #####################################################################
-- VRIENDSCHAPSVERZOEKEN
-- #####################################################################
create table if not exists public.friend_requests (
  id bigserial primary key,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (sender_id, recipient_id),
  check (sender_id <> recipient_id)
);
create index if not exists friend_requests_recipient_idx on public.friend_requests (recipient_id);

alter table public.friend_requests enable row level security;
drop policy if exists "eigen vriendschapsverzoeken lezen" on public.friend_requests;
create policy "eigen vriendschapsverzoeken lezen" on public.friend_requests
  for select to authenticated using (auth.uid() = sender_id or auth.uid() = recipient_id);
-- Bewust GEEN insert/update/delete policy: alles verloopt via de functies hieronder.

-- 2. Niet meer rechtstreeks vrienden worden ----------------------------------
-- Vriendschappen ontstaan enkel nog via respond_friend_request / send_friend_request.
-- Verwijderen van een vriend blijft gewoon mogelijk (policy "vriend verwijderen").
drop policy if exists "vriend toevoegen" on public.friendships;

-- 3. send_friend_request: verzoek sturen op basis van vriendencode ----------
-- Heeft de andere persoon jou al een verzoek gestuurd? Dan worden jullie meteen vrienden.
create or replace function public.send_friend_request(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_target public.profiles;
  v_reverse bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;

  select * into v_target from public.profiles where friend_code = upper(trim(p_code));
  if not found then raise exception 'Geen account gevonden met die code.'; end if;
  if v_target.id = me then raise exception 'Dat is je eigen code.'; end if;

  if exists (select 1 from public.friendships where user_id = me and friend_id = v_target.id) then
    raise exception '% is al je vriend.', v_target.display_name;
  end if;

  select id into v_reverse from public.friend_requests
    where sender_id = v_target.id and recipient_id = me;
  if found then
    insert into public.friendships (user_id, friend_id)
      values (me, v_target.id), (v_target.id, me)
      on conflict do nothing;
    delete from public.friend_requests where id = v_reverse;
    return jsonb_build_object('status', 'accepted', 'name', v_target.display_name);
  end if;

  if exists (select 1 from public.friend_requests where sender_id = me and recipient_id = v_target.id) then
    raise exception 'Je hebt al een verzoek gestuurd naar %.', v_target.display_name;
  end if;

  insert into public.friend_requests (sender_id, recipient_id) values (me, v_target.id);
  return jsonb_build_object('status', 'sent', 'name', v_target.display_name);
end;
$$;

-- 4. respond_friend_request: accepteren / weigeren (ontvanger) of annuleren (verzender)
create or replace function public.respond_friend_request(
  p_request_id bigint,
  p_action text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  r public.friend_requests;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;

  select * into r from public.friend_requests where id = p_request_id for update;
  if not found then raise exception 'Dit verzoek bestaat niet meer.'; end if;

  if p_action in ('accept', 'decline') then
    if me <> r.recipient_id then raise exception 'Dit verzoek is niet aan jou gericht.'; end if;
    if p_action = 'accept' then
      insert into public.friendships (user_id, friend_id)
        values (r.sender_id, r.recipient_id), (r.recipient_id, r.sender_id)
        on conflict do nothing;
    end if;
  elsif p_action = 'cancel' then
    if me <> r.sender_id then raise exception 'Dit is niet jouw verzoek.'; end if;
  else
    raise exception 'Onbekende actie.';
  end if;

  delete from public.friend_requests where id = p_request_id;
end;
$$;

grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(bigint, text) to authenticated;

-- 5. Vrienden mogen elkaars Wordle-geschiedenis zien (voor de statistieken) --
drop policy if exists "vrienden spelletjes lezen" on public.daily_plays;
create policy "vrienden spelletjes lezen" on public.daily_plays
  for select to authenticated using (
    exists (
      select 1 from public.friendships f
      where f.user_id = auth.uid() and f.friend_id = daily_plays.user_id
    )
  );

-- #####################################################################
-- WELKOMSTPAKKET
-- #####################################################################
create table if not exists public.welcome_packs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  card_ids int[] not null,
  claimed_at timestamptz not null default now()
);
alter table public.welcome_packs enable row level security;
drop policy if exists "eigen welkomstpakket lezen" on public.welcome_packs;
create policy "eigen welkomstpakket lezen" on public.welcome_packs
  for select to authenticated using (auth.uid() = user_id);
-- Bewust GEEN insert/update/delete policy: ophalen kan enkel via claim_welcome_pack().

create or replace function public.claim_welcome_pack()
returns setof public.cards
language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_ids int[];
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if exists (select 1 from public.welcome_packs where user_id = me) then
    raise exception 'Je hebt je welkomstpakket al ontvangen.';
  end if;

  select array_agg(id) into v_ids
  from (select id from public.cards where rarity = 'common' order by random() limit 3) x;
  if coalesce(array_length(v_ids, 1), 0) < 3 then
    raise exception 'Er zijn niet genoeg common-kaarten om een pakket te maken.';
  end if;

  -- De primary key op user_id zorgt dat twee snelle klikken nooit twee pakketten opleveren
  begin
    insert into public.welcome_packs (user_id, card_ids) values (me, v_ids);
  exception when unique_violation then
    raise exception 'Je hebt je welkomstpakket al ontvangen.';
  end;

  insert into public.user_cards (user_id, card_id) select me, unnest(v_ids);

  return query
    select c.* from unnest(v_ids) with ordinality u(id, ord)
    join public.cards c on c.id = u.id
    order by u.ord;
end;
$$;

grant execute on function public.claim_welcome_pack() to authenticated;

-- #####################################################################
-- DAGELIJKS SPEL: WORDLE — te vervangen door het nieuwe spel
-- #####################################################################
create table if not exists public.wordle_answers (word text primary key check (word ~ '^[A-Z]{5}$'));
create table if not exists public.wordle_rounds (
  round_date date not null,
  slot smallint not null check (slot in (1, 2)),
  word text not null,
  created_at timestamptz not null default now(),
  primary key (round_date, slot)
);
alter table public.wordle_answers enable row level security;
alter table public.wordle_rounds enable row level security;
-- Bewust GEEN policies: enkel de functies hieronder (security definer) mogen erin kijken.

-- 2. Spelletjes per gebruiker per ronde
create table if not exists public.wordle_games (
  user_id uuid not null references auth.users(id) on delete cascade,
  round_date date not null,
  slot smallint not null check (slot in (1, 2)),
  guesses text[] not null default '{}',
  status text not null default 'playing' check (status in ('playing', 'won', 'lost')),
  attempts int,
  card_id int references public.cards(id),
  is_duplicate boolean,
  coins_earned int not null default 0,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  primary key (user_id, round_date, slot)
);
alter table public.wordle_games enable row level security;
drop policy if exists "eigen wordles lezen" on public.wordle_games;
create policy "eigen wordles lezen" on public.wordle_games
  for select to authenticated using (auth.uid() = user_id);
-- Vrienden zien je gokken bewust NIET (die verklappen het woord); statistieken via friend_wordle_stats().

-- 3. Hulpfuncties -------------------------------------------------------------
create or replace function public._wordle_local() returns timestamp
language sql stable as $$ select now() at time zone 'Europe/Brussels' $$;

create or replace function public._wordle_opens(p_slot int) returns time
language sql immutable as $$ select time '00:00' $$;  -- 1 ronde per dag, vanaf middernacht (Belgische tijd)

-- Het woord van een ronde; wordt bij de eerste speler willekeurig gekozen (voor iedereen hetzelfde)
create or replace function public._wordle_word(p_date date, p_slot int) returns text
language plpgsql volatile security definer set search_path = public as $$
declare v text;
begin
  select word into v from public.wordle_rounds where round_date = p_date and slot = p_slot;
  if found then return v; end if;
  insert into public.wordle_rounds (round_date, slot, word)
  select p_date, p_slot, a.word from public.wordle_answers a
  where not exists (select 1 from public.wordle_rounds r where r.word = a.word)  -- geen herhalingen
  order by random() limit 1
  on conflict do nothing;
  select word into v from public.wordle_rounds where round_date = p_date and slot = p_slot;
  if v is null then
    -- Alle woorden al eens gebruikt: dan mag er herhaald worden
    insert into public.wordle_rounds (round_date, slot, word)
    select p_date, p_slot, word from public.wordle_answers order by random() limit 1
    on conflict do nothing;
    select word into v from public.wordle_rounds where round_date = p_date and slot = p_slot;
  end if;
  return v;
end $$;

-- Kleurtjes zoals in Wordle: g = juist, y = zit erin maar elders, x = zit er niet in (met correcte dubbele letters)
create or replace function public._wordle_score(p_guess text, p_answer text) returns text
language plpgsql immutable as $$
declare
  res text[] := array['x','x','x','x','x'];
  left_ text[] := '{}';
  i int; j int;
begin
  for i in 1..5 loop
    if substr(p_guess, i, 1) = substr(p_answer, i, 1) then res[i] := 'g';
    else left_ := left_ || substr(p_answer, i, 1); end if;
  end loop;
  for i in 1..5 loop
    if res[i] <> 'g' then
      j := array_position(left_, substr(p_guess, i, 1));
      if j is not null then res[i] := 'y'; left_ := left_[1:j-1] || left_[j+1:]; end if;
    end if;
  end loop;
  return array_to_string(res, '');
end $$;

-- Kaart trekken na een ronde (zelfde kansen en polycoins als de vroegere Edge Function)
drop function if exists public._wordle_draw(uuid, int);
create or replace function public._wordle_draw(p_user uuid, p_attempts int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r float8 := random() * 100;
  leg float8; ep float8; v_rarity text;
  v_card public.cards; v_dup boolean; v_coins int;
begin
  if p_attempts is null then
    v_rarity := 'cat';
  else
    leg := (array[80, 30, 10, 3, 1, 0.5])[p_attempts];
    ep  := (array[20, 50, 35, 22, 11, 4.5])[p_attempts];
    v_rarity := case when r < leg then 'legendary' when r < leg + ep then 'epic' else 'common' end;
  end if;
  select * into v_card from public.cards where rarity = v_rarity order by random() limit 1;
  if not found then raise exception 'Geen kaarten gevonden voor zeldzaamheid %.', v_rarity; end if;
  v_dup := exists (select 1 from public.user_cards where user_id = p_user and card_id = v_card.id);
  insert into public.user_cards (user_id, card_id) values (p_user, v_card.id);  -- dubbels komen er ook bij
  v_coins := 0;
  if v_dup then
    v_coins := case v_rarity when 'common' then 10 when 'epic' then 25 when 'legendary' then 60 else 5 end;
    insert into public.user_wallet (user_id, polycoins) values (p_user, v_coins)
      on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
  end if;
  return jsonb_build_object('card', to_jsonb(v_card), 'dup', v_dup, 'coins', v_coins);
end $$;

revoke all on function public._wordle_word(date, int) from public, anon, authenticated;
revoke all on function public._wordle_draw(uuid, int) from public, anon, authenticated;

-- 4. wordle_state: de ronde van vandaag voor de ingelogde gebruiker ------------
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
      'card_id', g.card_id,
      'answer', case when g.status = 'lost' then public._wordle_word(d, s) end
    );
  end loop;
  return jsonb_build_object('date', d, 'slots', out_);
end $$;

-- 5. wordle_guess: één gok indienen ------------------------------------------------
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

  if score = 'ggggg' or n >= 6 then
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
  return jsonb_build_object('result', score, 'status', 'playing', 'guess', guess);
end $$;

-- 6. Statistieken van een vriend (enkel resultaten, nooit de gokken) -----------------
create or replace function public.friend_wordle_stats(p_friend uuid)
returns table (play_date date, solved boolean, attempts int)
language sql stable security definer set search_path = public as $$
  select g.round_date, g.status = 'won', g.attempts
  from public.wordle_games g
  where g.user_id = p_friend and g.status <> 'playing'
    and exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = p_friend)
  order by g.round_date;
$$;

grant execute on function public.wordle_state() to authenticated;
grant execute on function public.wordle_guess(int, text) to authenticated;
grant execute on function public.friend_wordle_stats(uuid) to authenticated;

-- 7. De geheime lijst met oplossingen (2307 woorden) ------------------------------
insert into public.wordle_answers (word) values
  ('ABACK'), ('ABASE'), ('ABATE'), ('ABBEY'), ('ABBOT'), ('ABHOR'), ('ABIDE'), ('ABLED'), ('ABODE'), ('ABORT'), ('ABOUT'), ('ABOVE'),
  ('ABUSE'), ('ABYSS'), ('ACORN'), ('ACRID'), ('ACTOR'), ('ACUTE'), ('ADAGE'), ('ADAPT'), ('ADEPT'), ('ADMIN'), ('ADMIT'), ('ADOBE'),
  ('ADOPT'), ('ADORE'), ('ADORN'), ('ADULT'), ('AFFIX'), ('AFIRE'), ('AFOOT'), ('AFOUL'), ('AFTER'), ('AGAIN'), ('AGAPE'), ('AGATE'),
  ('AGENT'), ('AGILE'), ('AGING'), ('AGLOW'), ('AGONY'), ('AGORA'), ('AGREE'), ('AHEAD'), ('AIDER'), ('AISLE'), ('ALARM'), ('ALBUM'),
  ('ALERT'), ('ALGAE'), ('ALIBI'), ('ALIEN'), ('ALIGN'), ('ALIKE'), ('ALIVE'), ('ALLAY'), ('ALLEY'), ('ALLOT'), ('ALLOW'), ('ALLOY'),
  ('ALOFT'), ('ALONE'), ('ALONG'), ('ALOOF'), ('ALOUD'), ('ALPHA'), ('ALTAR'), ('ALTER'), ('AMASS'), ('AMAZE'), ('AMBER'), ('AMBLE'),
  ('AMEND'), ('AMISS'), ('AMITY'), ('AMONG'), ('AMPLE'), ('AMPLY'), ('AMUSE'), ('ANGEL'), ('ANGER'), ('ANGLE'), ('ANGRY'), ('ANGST'),
  ('ANIME'), ('ANKLE'), ('ANNEX'), ('ANNOY'), ('ANNUL'), ('ANODE'), ('ANTIC'), ('ANVIL'), ('AORTA'), ('APART'), ('APHID'), ('APING'),
  ('APNEA'), ('APPLE'), ('APPLY'), ('APRON'), ('APTLY'), ('ARBOR'), ('ARDOR'), ('ARENA'), ('ARGUE'), ('ARISE'), ('ARMOR'), ('AROMA'),
  ('AROSE'), ('ARRAY'), ('ARROW'), ('ARSON'), ('ARTSY'), ('ASCOT'), ('ASHEN'), ('ASIDE'), ('ASKEW'), ('ASSAY'), ('ASSET'), ('ATOLL'),
  ('ATONE'), ('ATTIC'), ('AUDIO'), ('AUDIT'), ('AUGUR'), ('AUNTY'), ('AVAIL'), ('AVERT'), ('AVIAN'), ('AVOID'), ('AWAIT'), ('AWAKE'),
  ('AWARD'), ('AWARE'), ('AWASH'), ('AWFUL'), ('AWOKE'), ('AXIAL'), ('AXIOM'), ('AXION'), ('AZURE'), ('BACON'), ('BADGE'), ('BADLY'),
  ('BAGEL'), ('BAGGY'), ('BAKER'), ('BALER'), ('BALMY'), ('BANAL'), ('BANJO'), ('BARGE'), ('BARON'), ('BASAL'), ('BASIC'), ('BASIL'),
  ('BASIN'), ('BASIS'), ('BASTE'), ('BATCH'), ('BATHE'), ('BATON'), ('BATTY'), ('BAWDY'), ('BAYOU'), ('BEACH'), ('BEADY'), ('BEARD'),
  ('BEAST'), ('BEECH'), ('BEEFY'), ('BEFIT'), ('BEGAN'), ('BEGAT'), ('BEGET'), ('BEGIN'), ('BEGUN'), ('BEING'), ('BELCH'), ('BELIE'),
  ('BELLE'), ('BELLY'), ('BELOW'), ('BENCH'), ('BERET'), ('BERRY'), ('BERTH'), ('BESET'), ('BETEL'), ('BEVEL'), ('BEZEL'), ('BIBLE'),
  ('BICEP'), ('BIDDY'), ('BILGE'), ('BILLY'), ('BINGE'), ('BINGO'), ('BIOME'), ('BIRCH'), ('BIRTH'), ('BISON'), ('BITTY'), ('BLACK'),
  ('BLADE'), ('BLAME'), ('BLAND'), ('BLANK'), ('BLARE'), ('BLAST'), ('BLAZE'), ('BLEAK'), ('BLEAT'), ('BLEED'), ('BLEEP'), ('BLEND'),
  ('BLESS'), ('BLIMP'), ('BLIND'), ('BLINK'), ('BLISS'), ('BLITZ'), ('BLOAT'), ('BLOCK'), ('BLOKE'), ('BLOND'), ('BLOOD'), ('BLOOM'),
  ('BLOWN'), ('BLUER'), ('BLUFF'), ('BLUNT'), ('BLURB'), ('BLURT'), ('BLUSH'), ('BOARD'), ('BOAST'), ('BOBBY'), ('BONEY'), ('BONGO'),
  ('BONUS'), ('BOOBY'), ('BOOST'), ('BOOTH'), ('BOOTY'), ('BOOZE'), ('BOOZY'), ('BORAX'), ('BORNE'), ('BOSOM'), ('BOSSY'), ('BOTCH'),
  ('BOUGH'), ('BOULE'), ('BOUND'), ('BOWEL'), ('BOXER'), ('BRACE'), ('BRAID'), ('BRAIN'), ('BRAKE'), ('BRAND'), ('BRASH'), ('BRASS'),
  ('BRAVE'), ('BRAVO'), ('BRAWL'), ('BRAWN'), ('BREAD'), ('BREAK'), ('BREED'), ('BRIAR'), ('BRIBE'), ('BRICK'), ('BRIDE'), ('BRIEF'),
  ('BRINE'), ('BRING'), ('BRINK'), ('BRINY'), ('BRISK'), ('BROAD'), ('BROIL'), ('BROKE'), ('BROOD'), ('BROOK'), ('BROOM'), ('BROTH'),
  ('BROWN'), ('BRUNT'), ('BRUSH'), ('BRUTE'), ('BUDDY'), ('BUDGE'), ('BUGGY'), ('BUGLE'), ('BUILD'), ('BUILT'), ('BULGE'), ('BULKY'),
  ('BULLY'), ('BUNCH'), ('BUNNY'), ('BURLY'), ('BURNT'), ('BURST'), ('BUSED'), ('BUSHY'), ('BUTCH'), ('BUTTE'), ('BUXOM'), ('BUYER'),
  ('BYLAW'), ('CABAL'), ('CABBY'), ('CABIN'), ('CABLE'), ('CACAO'), ('CACHE'), ('CACTI'), ('CADDY'), ('CADET'), ('CAGEY'), ('CAIRN'),
  ('CAMEL'), ('CAMEO'), ('CANAL'), ('CANDY'), ('CANNY'), ('CANOE'), ('CANON'), ('CAPER'), ('CAPUT'), ('CARAT'), ('CARGO'), ('CAROL'),
  ('CARRY'), ('CARVE'), ('CASTE'), ('CATCH'), ('CATER'), ('CATTY'), ('CAULK'), ('CAUSE'), ('CAVIL'), ('CEASE'), ('CEDAR'), ('CELLO'),
  ('CHAFE'), ('CHAFF'), ('CHAIN'), ('CHAIR'), ('CHALK'), ('CHAMP'), ('CHANT'), ('CHAOS'), ('CHARD'), ('CHARM'), ('CHART'), ('CHASE'),
  ('CHASM'), ('CHEAP'), ('CHEAT'), ('CHECK'), ('CHEEK'), ('CHEER'), ('CHESS'), ('CHEST'), ('CHICK'), ('CHIDE'), ('CHIEF'), ('CHILD'),
  ('CHILI'), ('CHILL'), ('CHIME'), ('CHINA'), ('CHIRP'), ('CHOCK'), ('CHOIR'), ('CHOKE'), ('CHORD'), ('CHORE'), ('CHOSE'), ('CHUCK'),
  ('CHUMP'), ('CHUNK'), ('CHURN'), ('CHUTE'), ('CIDER'), ('CIGAR'), ('CINCH'), ('CIRCA'), ('CIVIC'), ('CIVIL'), ('CLACK'), ('CLAIM'),
  ('CLAMP'), ('CLANG'), ('CLANK'), ('CLASH'), ('CLASP'), ('CLASS'), ('CLEAN'), ('CLEAR'), ('CLEAT'), ('CLEFT'), ('CLERK'), ('CLICK'),
  ('CLIFF'), ('CLIMB'), ('CLING'), ('CLINK'), ('CLOAK'), ('CLOCK'), ('CLONE'), ('CLOSE'), ('CLOTH'), ('CLOUD'), ('CLOUT'), ('CLOVE'),
  ('CLOWN'), ('CLUCK'), ('CLUED'), ('CLUMP'), ('CLUNG'), ('COACH'), ('COAST'), ('COBRA'), ('COCOA'), ('COLON'), ('COLOR'), ('COMET'),
  ('COMFY'), ('COMIC'), ('COMMA'), ('CONCH'), ('CONDO'), ('CONIC'), ('COPSE'), ('CORAL'), ('CORER'), ('CORNY'), ('COUCH'), ('COUGH'),
  ('COULD'), ('COUNT'), ('COUPE'), ('COURT'), ('COVEN'), ('COVER'), ('COVET'), ('COVEY'), ('COWER'), ('COYLY'), ('CRACK'), ('CRAFT'),
  ('CRAMP'), ('CRANE'), ('CRANK'), ('CRASH'), ('CRASS'), ('CRATE'), ('CRAVE'), ('CRAWL'), ('CRAZE'), ('CRAZY'), ('CREAK'), ('CREAM'),
  ('CREDO'), ('CREED'), ('CREEK'), ('CREEP'), ('CREME'), ('CREPE'), ('CREPT'), ('CRESS'), ('CREST'), ('CRICK'), ('CRIED'), ('CRIER'),
  ('CRIME'), ('CRIMP'), ('CRISP'), ('CROAK'), ('CROCK'), ('CRONE'), ('CRONY'), ('CROOK'), ('CROSS'), ('CROUP'), ('CROWD'), ('CROWN'),
  ('CRUDE'), ('CRUEL'), ('CRUMB'), ('CRUMP'), ('CRUSH'), ('CRUST'), ('CRYPT'), ('CUBIC'), ('CUMIN'), ('CURIO'), ('CURLY'), ('CURRY'),
  ('CURSE'), ('CURVE'), ('CURVY'), ('CUTIE'), ('CYBER'), ('CYCLE'), ('CYNIC'), ('DADDY'), ('DAILY'), ('DAIRY'), ('DAISY'), ('DALLY'),
  ('DANCE'), ('DANDY'), ('DATUM'), ('DAUNT'), ('DEALT'), ('DEATH'), ('DEBAR'), ('DEBIT'), ('DEBUG'), ('DEBUT'), ('DECAL'), ('DECAY'),
  ('DECOR'), ('DECOY'), ('DECRY'), ('DEFER'), ('DEIGN'), ('DEITY'), ('DELAY'), ('DELTA'), ('DELVE'), ('DEMON'), ('DEMUR'), ('DENIM'),
  ('DENSE'), ('DEPOT'), ('DEPTH'), ('DERBY'), ('DETER'), ('DETOX'), ('DEUCE'), ('DEVIL'), ('DIARY'), ('DICEY'), ('DIGIT'), ('DILLY'),
  ('DIMLY'), ('DINER'), ('DINGO'), ('DINGY'), ('DIODE'), ('DIRGE'), ('DIRTY'), ('DISCO'), ('DITCH'), ('DITTO'), ('DITTY'), ('DIVER'),
  ('DIZZY'), ('DODGE'), ('DODGY'), ('DOGMA'), ('DOING'), ('DOLLY'), ('DONOR'), ('DONUT'), ('DOPEY'), ('DOUBT'), ('DOUGH'), ('DOWDY'),
  ('DOWEL'), ('DOWNY'), ('DOWRY'), ('DOZEN'), ('DRAFT'), ('DRAIN'), ('DRAKE'), ('DRAMA'), ('DRANK'), ('DRAPE'), ('DRAWL'), ('DRAWN'),
  ('DREAD'), ('DREAM'), ('DRESS'), ('DRIED'), ('DRIER'), ('DRIFT'), ('DRILL'), ('DRINK'), ('DRIVE'), ('DROIT'), ('DROLL'), ('DRONE'),
  ('DROOL'), ('DROOP'), ('DROSS'), ('DROVE'), ('DROWN'), ('DRUID'), ('DRUNK'), ('DRYER'), ('DRYLY'), ('DUCHY'), ('DULLY'), ('DUMMY'),
  ('DUMPY'), ('DUNCE'), ('DUSKY'), ('DUSTY'), ('DUTCH'), ('DUVET'), ('DWARF'), ('DWELL'), ('DWELT'), ('DYING'), ('EAGER'), ('EAGLE'),
  ('EARLY'), ('EARTH'), ('EASEL'), ('EATEN'), ('EATER'), ('EBONY'), ('ECLAT'), ('EDICT'), ('EDIFY'), ('EERIE'), ('EGRET'), ('EIGHT'),
  ('EJECT'), ('EKING'), ('ELATE'), ('ELBOW'), ('ELDER'), ('ELECT'), ('ELEGY'), ('ELFIN'), ('ELIDE'), ('ELITE'), ('ELOPE'), ('ELUDE'),
  ('EMAIL'), ('EMBED'), ('EMBER'), ('EMCEE'), ('EMPTY'), ('ENACT'), ('ENDOW'), ('ENEMA'), ('ENEMY'), ('ENJOY'), ('ENNUI'), ('ENSUE'),
  ('ENTER'), ('ENTRY'), ('ENVOY'), ('EPOCH'), ('EPOXY'), ('EQUAL'), ('EQUIP'), ('ERASE'), ('ERECT'), ('ERODE'), ('ERROR'), ('ERUPT'),
  ('ESSAY'), ('ESTER'), ('ETHER'), ('ETHIC'), ('ETHOS'), ('ETUDE'), ('EVADE'), ('EVENT'), ('EVERY'), ('EVICT'), ('EVOKE'), ('EXACT'),
  ('EXALT'), ('EXCEL'), ('EXERT'), ('EXILE'), ('EXIST'), ('EXPEL'), ('EXTOL'), ('EXTRA'), ('EXULT'), ('EYING'), ('FABLE'), ('FACET'),
  ('FAINT'), ('FAIRY'), ('FAITH'), ('FALSE'), ('FANCY'), ('FANNY'), ('FARCE'), ('FATAL'), ('FATTY'), ('FAULT'), ('FAUNA'), ('FAVOR'),
  ('FEAST'), ('FEIGN'), ('FELLA'), ('FELON'), ('FEMME'), ('FEMUR'), ('FENCE'), ('FERAL'), ('FERRY'), ('FETAL'), ('FETCH'), ('FETID'),
  ('FETUS'), ('FEVER'), ('FEWER'), ('FIBER'), ('FIBRE'), ('FICUS'), ('FIELD'), ('FIEND'), ('FIERY'), ('FIFTH'), ('FIFTY'), ('FIGHT'),
  ('FILER'), ('FILET'), ('FILLY'), ('FILMY'), ('FILTH'), ('FINAL'), ('FINCH'), ('FINER'), ('FIRST'), ('FISHY'), ('FIXER'), ('FIZZY'),
  ('FJORD'), ('FLACK'), ('FLAIL'), ('FLAIR'), ('FLAKE'), ('FLAKY'), ('FLAME'), ('FLANK'), ('FLARE'), ('FLASH'), ('FLASK'), ('FLECK'),
  ('FLEET'), ('FLESH'), ('FLICK'), ('FLIER'), ('FLING'), ('FLINT'), ('FLIRT'), ('FLOAT'), ('FLOCK'), ('FLOOD'), ('FLOOR'), ('FLORA'),
  ('FLOSS'), ('FLOUR'), ('FLOUT'), ('FLOWN'), ('FLUFF'), ('FLUID'), ('FLUKE'), ('FLUME'), ('FLUNG'), ('FLUNK'), ('FLUSH'), ('FLUTE'),
  ('FLYER'), ('FOAMY'), ('FOCAL'), ('FOCUS'), ('FOGGY'), ('FOIST'), ('FOLIO'), ('FOLLY'), ('FORAY'), ('FORCE'), ('FORGE'), ('FORGO'),
  ('FORTE'), ('FORTH'), ('FORTY'), ('FORUM'), ('FOUND'), ('FOYER'), ('FRAIL'), ('FRAME'), ('FRANK'), ('FRAUD'), ('FREAK'), ('FREED'),
  ('FREER'), ('FRESH'), ('FRIAR'), ('FRIED'), ('FRILL'), ('FRISK'), ('FRITZ'), ('FROCK'), ('FROND'), ('FRONT'), ('FROST'), ('FROTH'),
  ('FROWN'), ('FROZE'), ('FRUIT'), ('FUDGE'), ('FUGUE'), ('FULLY'), ('FUNGI'), ('FUNKY'), ('FUNNY'), ('FUROR'), ('FURRY'), ('FUSSY'),
  ('FUZZY'), ('GAFFE'), ('GAILY'), ('GAMER'), ('GAMMA'), ('GAMUT'), ('GASSY'), ('GAUDY'), ('GAUGE'), ('GAUNT'), ('GAUZE'), ('GAVEL'),
  ('GAWKY'), ('GAYER'), ('GAYLY'), ('GAZER'), ('GECKO'), ('GEEKY'), ('GEESE'), ('GENIE'), ('GENRE'), ('GHOST'), ('GHOUL'), ('GIANT'),
  ('GIDDY'), ('GIPSY'), ('GIRLY'), ('GIRTH'), ('GIVEN'), ('GIVER'), ('GLADE'), ('GLAND'), ('GLARE'), ('GLASS'), ('GLAZE'), ('GLEAM'),
  ('GLEAN'), ('GLIDE'), ('GLINT'), ('GLOAT'), ('GLOBE'), ('GLOOM'), ('GLORY'), ('GLOSS'), ('GLOVE'), ('GLYPH'), ('GNASH'), ('GNOME'),
  ('GODLY'), ('GOING'), ('GOLEM'), ('GOLLY'), ('GONAD'), ('GONER'), ('GOODY'), ('GOOEY'), ('GOOFY'), ('GOOSE'), ('GORGE'), ('GOUGE'),
  ('GOURD'), ('GRACE'), ('GRADE'), ('GRAFT'), ('GRAIL'), ('GRAIN'), ('GRAND'), ('GRANT'), ('GRAPE'), ('GRAPH'), ('GRASP'), ('GRASS'),
  ('GRATE'), ('GRAVE'), ('GRAVY'), ('GRAZE'), ('GREAT'), ('GREED'), ('GREEN'), ('GREET'), ('GRIEF'), ('GRILL'), ('GRIME'), ('GRIMY'),
  ('GRIND'), ('GRIPE'), ('GROAN'), ('GROIN'), ('GROOM'), ('GROPE'), ('GROSS'), ('GROUP'), ('GROUT'), ('GROVE'), ('GROWL'), ('GROWN'),
  ('GRUEL'), ('GRUFF'), ('GRUNT'), ('GUARD'), ('GUAVA'), ('GUESS'), ('GUEST'), ('GUIDE'), ('GUILD'), ('GUILE'), ('GUILT'), ('GUISE'),
  ('GULCH'), ('GULLY'), ('GUMBO'), ('GUMMY'), ('GUPPY'), ('GUSTO'), ('GUSTY'), ('HABIT'), ('HAIRY'), ('HALVE'), ('HANDY'), ('HAPPY'),
  ('HARDY'), ('HAREM'), ('HARPY'), ('HARRY'), ('HARSH'), ('HASTE'), ('HASTY'), ('HATCH'), ('HATER'), ('HAUNT'), ('HAUTE'), ('HAVEN'),
  ('HAVOC'), ('HAZEL'), ('HEADY'), ('HEARD'), ('HEART'), ('HEATH'), ('HEAVE'), ('HEAVY'), ('HEDGE'), ('HEFTY'), ('HEIST'), ('HELIX'),
  ('HELLO'), ('HENCE'), ('HERON'), ('HILLY'), ('HINGE'), ('HIPPO'), ('HIPPY'), ('HITCH'), ('HOARD'), ('HOBBY'), ('HOIST'), ('HOLLY'),
  ('HOMER'), ('HONEY'), ('HONOR'), ('HORDE'), ('HORNY'), ('HORSE'), ('HOTEL'), ('HOTLY'), ('HOUND'), ('HOUSE'), ('HOVEL'), ('HOVER'),
  ('HOWDY'), ('HUMAN'), ('HUMID'), ('HUMOR'), ('HUMPH'), ('HUMUS'), ('HUNCH'), ('HUNKY'), ('HURRY'), ('HUSKY'), ('HUSSY'), ('HUTCH'),
  ('HYDRO'), ('HYENA'), ('HYMEN'), ('HYPER'), ('ICILY'), ('ICING'), ('IDEAL'), ('IDIOM'), ('IDIOT'), ('IDLER'), ('IDYLL'), ('IGLOO'),
  ('ILIAC'), ('IMAGE'), ('IMBUE'), ('IMPEL'), ('IMPLY'), ('INANE'), ('INBOX'), ('INCUR'), ('INDEX'), ('INEPT'), ('INERT'), ('INFER'),
  ('INGOT'), ('INLAY'), ('INLET'), ('INNER'), ('INPUT'), ('INTER'), ('INTRO'), ('IONIC'), ('IRATE'), ('IRONY'), ('ISLET'), ('ISSUE'),
  ('ITCHY'), ('IVORY'), ('JAUNT'), ('JAZZY'), ('JELLY'), ('JERKY'), ('JETTY'), ('JEWEL'), ('JIFFY'), ('JOINT'), ('JOIST'), ('JOKER'),
  ('JOLLY'), ('JOUST'), ('JUDGE'), ('JUICE'), ('JUICY'), ('JUMBO'), ('JUMPY'), ('JUNTA'), ('JUNTO'), ('JUROR'), ('KAPPA'), ('KARMA'),
  ('KAYAK'), ('KEBAB'), ('KHAKI'), ('KIOSK'), ('KITTY'), ('KNACK'), ('KNAVE'), ('KNEAD'), ('KNEED'), ('KNEEL'), ('KNELT'), ('KNIFE'),
  ('KNOCK'), ('KNOLL'), ('KNOWN'), ('KOALA'), ('KRILL'), ('LABEL'), ('LABOR'), ('LADEN'), ('LADLE'), ('LAGER'), ('LANCE'), ('LANKY'),
  ('LAPEL'), ('LAPSE'), ('LARGE'), ('LARVA'), ('LASSO'), ('LATCH'), ('LATER'), ('LATHE'), ('LATTE'), ('LAUGH'), ('LAYER'), ('LEACH'),
  ('LEAFY'), ('LEAKY'), ('LEANT'), ('LEAPT'), ('LEARN'), ('LEASE'), ('LEASH'), ('LEAST'), ('LEAVE'), ('LEDGE'), ('LEECH'), ('LEERY'),
  ('LEFTY'), ('LEGAL'), ('LEGGY'), ('LEMON'), ('LEMUR'), ('LEPER'), ('LEVEL'), ('LEVER'), ('LIBEL'), ('LIEGE'), ('LIGHT'), ('LIKEN'),
  ('LILAC'), ('LIMBO'), ('LIMIT'), ('LINEN'), ('LINER'), ('LINGO'), ('LIPID'), ('LITHE'), ('LIVER'), ('LIVID'), ('LLAMA'), ('LOAMY'),
  ('LOATH'), ('LOBBY'), ('LOCAL'), ('LOCUS'), ('LODGE'), ('LOFTY'), ('LOGIC'), ('LOGIN'), ('LOOPY'), ('LOOSE'), ('LORRY'), ('LOSER'),
  ('LOUSE'), ('LOUSY'), ('LOVER'), ('LOWER'), ('LOWLY'), ('LOYAL'), ('LUCID'), ('LUCKY'), ('LUMEN'), ('LUMPY'), ('LUNAR'), ('LUNCH'),
  ('LUNGE'), ('LUPUS'), ('LURCH'), ('LURID'), ('LUSTY'), ('LYING'), ('LYMPH'), ('LYRIC'), ('MACAW'), ('MACHO'), ('MACRO'), ('MADAM'),
  ('MADLY'), ('MAFIA'), ('MAGIC'), ('MAGMA'), ('MAIZE'), ('MAJOR'), ('MAKER'), ('MAMBO'), ('MAMMA'), ('MAMMY'), ('MANGA'), ('MANGE'),
  ('MANGO'), ('MANGY'), ('MANIA'), ('MANIC'), ('MANLY'), ('MANOR'), ('MAPLE'), ('MARCH'), ('MARRY'), ('MARSH'), ('MASON'), ('MASSE'),
  ('MATCH'), ('MATEY'), ('MAUVE'), ('MAXIM'), ('MAYBE'), ('MAYOR'), ('MEALY'), ('MEANT'), ('MEATY'), ('MECCA'), ('MEDAL'), ('MEDIA'),
  ('MEDIC'), ('MELEE'), ('MELON'), ('MERCY'), ('MERGE'), ('MERIT'), ('MERRY'), ('METAL'), ('METER'), ('METRO'), ('MICRO'), ('MIDGE'),
  ('MIDST'), ('MIGHT'), ('MILKY'), ('MIMIC'), ('MINCE'), ('MINER'), ('MINIM'), ('MINOR'), ('MINTY'), ('MINUS'), ('MIRTH'), ('MISER'),
  ('MISSY'), ('MOCHA'), ('MODAL'), ('MODEL'), ('MODEM'), ('MOGUL'), ('MOIST'), ('MOLAR'), ('MOLDY'), ('MONEY'), ('MONTH'), ('MOODY'),
  ('MOOSE'), ('MORAL'), ('MORON'), ('MORPH'), ('MOSSY'), ('MOTEL'), ('MOTIF'), ('MOTOR'), ('MOTTO'), ('MOULT'), ('MOUND'), ('MOUNT'),
  ('MOURN'), ('MOUSE'), ('MOUTH'), ('MOVER'), ('MOVIE'), ('MOWER'), ('MUCKY'), ('MUCUS'), ('MUDDY'), ('MULCH'), ('MUMMY'), ('MUNCH'),
  ('MURAL'), ('MURKY'), ('MUSHY'), ('MUSIC'), ('MUSKY'), ('MUSTY'), ('MYRRH'), ('NADIR'), ('NAIVE'), ('NANNY'), ('NASAL'), ('NASTY'),
  ('NATAL'), ('NAVAL'), ('NAVEL'), ('NEEDY'), ('NEIGH'), ('NERDY'), ('NERVE'), ('NEVER'), ('NEWER'), ('NEWLY'), ('NICER'), ('NICHE'),
  ('NIECE'), ('NIGHT'), ('NINJA'), ('NINNY'), ('NINTH'), ('NOBLE'), ('NOBLY'), ('NOISE'), ('NOISY'), ('NOMAD'), ('NOOSE'), ('NORTH'),
  ('NOSEY'), ('NOTCH'), ('NOVEL'), ('NUDGE'), ('NURSE'), ('NUTTY'), ('NYLON'), ('NYMPH'), ('OAKEN'), ('OBESE'), ('OCCUR'), ('OCEAN'),
  ('OCTAL'), ('OCTET'), ('ODDER'), ('ODDLY'), ('OFFAL'), ('OFFER'), ('OFTEN'), ('OLDEN'), ('OLDER'), ('OLIVE'), ('OMBRE'), ('OMEGA'),
  ('ONION'), ('ONSET'), ('OPERA'), ('OPINE'), ('OPIUM'), ('OPTIC'), ('ORBIT'), ('ORDER'), ('ORGAN'), ('OTHER'), ('OTTER'), ('OUGHT'),
  ('OUNCE'), ('OUTDO'), ('OUTER'), ('OUTGO'), ('OVARY'), ('OVATE'), ('OVERT'), ('OVINE'), ('OVOID'), ('OWING'), ('OWNER'), ('OXIDE'),
  ('OZONE'), ('PADDY'), ('PAGAN'), ('PAINT'), ('PALER'), ('PALSY'), ('PANEL'), ('PANIC'), ('PANSY'), ('PAPAL'), ('PAPER'), ('PARER'),
  ('PARKA'), ('PARRY'), ('PARSE'), ('PARTY'), ('PASTA'), ('PASTE'), ('PASTY'), ('PATCH'), ('PATIO'), ('PATSY'), ('PATTY'), ('PAUSE'),
  ('PAYEE'), ('PAYER'), ('PEACE'), ('PEACH'), ('PEARL'), ('PECAN'), ('PEDAL'), ('PENAL'), ('PENCE'), ('PENNE'), ('PENNY'), ('PERCH'),
  ('PERIL'), ('PERKY'), ('PESKY'), ('PESTO'), ('PETAL'), ('PETTY'), ('PHASE'), ('PHONE'), ('PHONY'), ('PHOTO'), ('PIANO'), ('PICKY'),
  ('PIECE'), ('PIETY'), ('PIGGY'), ('PILOT'), ('PINCH'), ('PINEY'), ('PINKY'), ('PINTO'), ('PIPER'), ('PIQUE'), ('PITCH'), ('PITHY'),
  ('PIVOT'), ('PIXEL'), ('PIXIE'), ('PIZZA'), ('PLACE'), ('PLAID'), ('PLAIN'), ('PLAIT'), ('PLANE'), ('PLANK'), ('PLANT'), ('PLATE'),
  ('PLAZA'), ('PLEAD'), ('PLEAT'), ('PLIED'), ('PLIER'), ('PLUCK'), ('PLUMB'), ('PLUME'), ('PLUMP'), ('PLUNK'), ('PLUSH'), ('POESY'),
  ('POINT'), ('POISE'), ('POKER'), ('POLAR'), ('POLKA'), ('POLYP'), ('POOCH'), ('POPPY'), ('PORCH'), ('POSER'), ('POSIT'), ('POSSE'),
  ('POUCH'), ('POUND'), ('POUTY'), ('POWER'), ('PRANK'), ('PRAWN'), ('PREEN'), ('PRESS'), ('PRICE'), ('PRICK'), ('PRIDE'), ('PRIED'),
  ('PRIME'), ('PRIMO'), ('PRINT'), ('PRIOR'), ('PRISM'), ('PRIVY'), ('PRIZE'), ('PROBE'), ('PRONE'), ('PRONG'), ('PROOF'), ('PROSE'),
  ('PROUD'), ('PROVE'), ('PROWL'), ('PROXY'), ('PRUDE'), ('PRUNE'), ('PSALM'), ('PUBIC'), ('PUDGY'), ('PUFFY'), ('PULPY'), ('PULSE'),
  ('PUNCH'), ('PUPAL'), ('PUPIL'), ('PUPPY'), ('PUREE'), ('PURER'), ('PURGE'), ('PURSE'), ('PUSHY'), ('PUTTY'), ('PYGMY'), ('QUACK'),
  ('QUAIL'), ('QUAKE'), ('QUALM'), ('QUARK'), ('QUART'), ('QUASH'), ('QUASI'), ('QUEEN'), ('QUEER'), ('QUELL'), ('QUERY'), ('QUEST'),
  ('QUEUE'), ('QUICK'), ('QUIET'), ('QUILL'), ('QUILT'), ('QUIRK'), ('QUITE'), ('QUOTA'), ('QUOTE'), ('QUOTH'), ('RABBI'), ('RABID'),
  ('RACER'), ('RADAR'), ('RADII'), ('RADIO'), ('RAINY'), ('RAISE'), ('RAJAH'), ('RALLY'), ('RALPH'), ('RAMEN'), ('RANCH'), ('RANDY'),
  ('RANGE'), ('RAPID'), ('RARER'), ('RASPY'), ('RATIO'), ('RATTY'), ('RAVEN'), ('RAYON'), ('RAZOR'), ('REACH'), ('REACT'), ('READY'),
  ('REALM'), ('REARM'), ('REBAR'), ('REBEL'), ('REBUS'), ('REBUT'), ('RECAP'), ('RECUR'), ('RECUT'), ('REEDY'), ('REFER'), ('REFIT'),
  ('REGAL'), ('REHAB'), ('REIGN'), ('RELAX'), ('RELAY'), ('RELIC'), ('REMIT'), ('RENAL'), ('RENEW'), ('REPAY'), ('REPEL'), ('REPLY'),
  ('RERUN'), ('RESET'), ('RESIN'), ('RETCH'), ('RETRO'), ('RETRY'), ('REUSE'), ('REVEL'), ('REVUE'), ('RHINO'), ('RHYME'), ('RIDER'),
  ('RIDGE'), ('RIFLE'), ('RIGHT'), ('RIGID'), ('RIGOR'), ('RINSE'), ('RIPEN'), ('RIPER'), ('RISEN'), ('RISER'), ('RISKY'), ('RIVAL'),
  ('RIVER'), ('RIVET'), ('ROACH'), ('ROAST'), ('ROBIN'), ('ROBOT'), ('ROCKY'), ('RODEO'), ('ROGER'), ('ROGUE'), ('ROOMY'), ('ROOST'),
  ('ROTOR'), ('ROUGE'), ('ROUGH'), ('ROUND'), ('ROUSE'), ('ROUTE'), ('ROVER'), ('ROWDY'), ('ROWER'), ('ROYAL'), ('RUDDY'), ('RUDER'),
  ('RUGBY'), ('RULER'), ('RUMBA'), ('RUMOR'), ('RUPEE'), ('RURAL'), ('RUSTY'), ('SADLY'), ('SAFER'), ('SAINT'), ('SALAD'), ('SALLY'),
  ('SALON'), ('SALSA'), ('SALTY'), ('SALVE'), ('SALVO'), ('SANDY'), ('SANER'), ('SAPPY'), ('SASSY'), ('SATIN'), ('SATYR'), ('SAUCE'),
  ('SAUCY'), ('SAUNA'), ('SAUTE'), ('SAVOR'), ('SAVOY'), ('SAVVY'), ('SCALD'), ('SCALE'), ('SCALP'), ('SCALY'), ('SCAMP'), ('SCANT'),
  ('SCARE'), ('SCARF'), ('SCARY'), ('SCENE'), ('SCENT'), ('SCION'), ('SCOFF'), ('SCOLD'), ('SCONE'), ('SCOOP'), ('SCOPE'), ('SCORE'),
  ('SCORN'), ('SCOUR'), ('SCOUT'), ('SCOWL'), ('SCRAM'), ('SCRAP'), ('SCREE'), ('SCREW'), ('SCRUB'), ('SCRUM'), ('SCUBA'), ('SEDAN'),
  ('SEEDY'), ('SEGUE'), ('SEIZE'), ('SEMEN'), ('SENSE'), ('SEPIA'), ('SERIF'), ('SERUM'), ('SERVE'), ('SETUP'), ('SEVEN'), ('SEVER'),
  ('SEWER'), ('SHACK'), ('SHADE'), ('SHADY'), ('SHAFT'), ('SHAKE'), ('SHAKY'), ('SHALE'), ('SHALL'), ('SHALT'), ('SHAME'), ('SHANK'),
  ('SHAPE'), ('SHARD'), ('SHARE'), ('SHARK'), ('SHARP'), ('SHAVE'), ('SHAWL'), ('SHEAR'), ('SHEEN'), ('SHEEP'), ('SHEER'), ('SHEET'),
  ('SHEIK'), ('SHELF'), ('SHELL'), ('SHIED'), ('SHIFT'), ('SHINE'), ('SHINY'), ('SHIRE'), ('SHIRK'), ('SHIRT'), ('SHOAL'), ('SHOCK'),
  ('SHONE'), ('SHOOK'), ('SHOOT'), ('SHORE'), ('SHORN'), ('SHORT'), ('SHOUT'), ('SHOVE'), ('SHOWN'), ('SHOWY'), ('SHREW'), ('SHRUB'),
  ('SHRUG'), ('SHUCK'), ('SHUNT'), ('SHUSH'), ('SHYLY'), ('SIEGE'), ('SIEVE'), ('SIGHT'), ('SIGMA'), ('SILKY'), ('SILLY'), ('SINCE'),
  ('SINEW'), ('SINGE'), ('SIREN'), ('SISSY'), ('SIXTH'), ('SIXTY'), ('SKATE'), ('SKIER'), ('SKIFF'), ('SKILL'), ('SKIMP'), ('SKIRT'),
  ('SKULK'), ('SKULL'), ('SKUNK'), ('SLACK'), ('SLAIN'), ('SLANG'), ('SLANT'), ('SLASH'), ('SLATE'), ('SLEEK'), ('SLEEP'), ('SLEET'),
  ('SLEPT'), ('SLICE'), ('SLICK'), ('SLIDE'), ('SLIME'), ('SLIMY'), ('SLING'), ('SLINK'), ('SLOOP'), ('SLOPE'), ('SLOSH'), ('SLOTH'),
  ('SLUMP'), ('SLUNG'), ('SLUNK'), ('SLURP'), ('SLUSH'), ('SLYLY'), ('SMACK'), ('SMALL'), ('SMART'), ('SMASH'), ('SMEAR'), ('SMELL'),
  ('SMELT'), ('SMILE'), ('SMIRK'), ('SMITE'), ('SMITH'), ('SMOCK'), ('SMOKE'), ('SMOKY'), ('SMOTE'), ('SNACK'), ('SNAIL'), ('SNAKE'),
  ('SNAKY'), ('SNARE'), ('SNARL'), ('SNEAK'), ('SNEER'), ('SNIDE'), ('SNIFF'), ('SNIPE'), ('SNOOP'), ('SNORE'), ('SNORT'), ('SNOUT'),
  ('SNOWY'), ('SNUCK'), ('SNUFF'), ('SOAPY'), ('SOBER'), ('SOGGY'), ('SOLAR'), ('SOLID'), ('SOLVE'), ('SONAR'), ('SONIC'), ('SOOTH'),
  ('SOOTY'), ('SORRY'), ('SOUND'), ('SOUTH'), ('SOWER'), ('SPACE'), ('SPADE'), ('SPANK'), ('SPARE'), ('SPARK'), ('SPASM'), ('SPAWN'),
  ('SPEAK'), ('SPEAR'), ('SPECK'), ('SPEED'), ('SPELL'), ('SPELT'), ('SPEND'), ('SPENT'), ('SPICE'), ('SPICY'), ('SPIED'), ('SPIEL'),
  ('SPIKE'), ('SPIKY'), ('SPILL'), ('SPILT'), ('SPINE'), ('SPINY'), ('SPIRE'), ('SPITE'), ('SPLAT'), ('SPLIT'), ('SPOIL'), ('SPOKE'),
  ('SPOOF'), ('SPOOK'), ('SPOOL'), ('SPOON'), ('SPORE'), ('SPORT'), ('SPOUT'), ('SPRAY'), ('SPREE'), ('SPRIG'), ('SPUNK'), ('SPURN'),
  ('SPURT'), ('SQUAD'), ('SQUAT'), ('SQUIB'), ('STACK'), ('STAFF'), ('STAGE'), ('STAID'), ('STAIN'), ('STAIR'), ('STAKE'), ('STALE'),
  ('STALK'), ('STALL'), ('STAMP'), ('STAND'), ('STANK'), ('STARE'), ('STARK'), ('START'), ('STASH'), ('STATE'), ('STAVE'), ('STEAD'),
  ('STEAK'), ('STEAL'), ('STEAM'), ('STEED'), ('STEEL'), ('STEEP'), ('STEER'), ('STEIN'), ('STERN'), ('STICK'), ('STIFF'), ('STILL'),
  ('STILT'), ('STING'), ('STINK'), ('STINT'), ('STOCK'), ('STOIC'), ('STOKE'), ('STOLE'), ('STOMP'), ('STONE'), ('STONY'), ('STOOD'),
  ('STOOL'), ('STOOP'), ('STORE'), ('STORK'), ('STORM'), ('STORY'), ('STOUT'), ('STOVE'), ('STRAP'), ('STRAW'), ('STRAY'), ('STRIP'),
  ('STRUT'), ('STUCK'), ('STUDY'), ('STUFF'), ('STUMP'), ('STUNG'), ('STUNK'), ('STUNT'), ('STYLE'), ('SUAVE'), ('SUGAR'), ('SUING'),
  ('SUITE'), ('SULKY'), ('SULLY'), ('SUMAC'), ('SUNNY'), ('SUPER'), ('SURER'), ('SURGE'), ('SURLY'), ('SUSHI'), ('SWAMI'), ('SWAMP'),
  ('SWARM'), ('SWASH'), ('SWATH'), ('SWEAR'), ('SWEAT'), ('SWEEP'), ('SWEET'), ('SWELL'), ('SWEPT'), ('SWIFT'), ('SWILL'), ('SWINE'),
  ('SWING'), ('SWIRL'), ('SWISH'), ('SWOON'), ('SWOOP'), ('SWORD'), ('SWORE'), ('SWORN'), ('SWUNG'), ('SYNOD'), ('SYRUP'), ('TABBY'),
  ('TABLE'), ('TABOO'), ('TACIT'), ('TACKY'), ('TAFFY'), ('TAINT'), ('TAKEN'), ('TAKER'), ('TALLY'), ('TALON'), ('TAMER'), ('TANGO'),
  ('TANGY'), ('TAPER'), ('TAPIR'), ('TARDY'), ('TAROT'), ('TASTE'), ('TASTY'), ('TATTY'), ('TAUNT'), ('TAWNY'), ('TEACH'), ('TEARY'),
  ('TEASE'), ('TEDDY'), ('TEETH'), ('TEMPO'), ('TENET'), ('TENOR'), ('TENSE'), ('TENTH'), ('TEPEE'), ('TEPID'), ('TERRA'), ('TERSE'),
  ('TESTY'), ('THANK'), ('THEFT'), ('THEIR'), ('THEME'), ('THERE'), ('THESE'), ('THETA'), ('THICK'), ('THIEF'), ('THIGH'), ('THING'),
  ('THINK'), ('THIRD'), ('THONG'), ('THORN'), ('THOSE'), ('THREE'), ('THREW'), ('THROB'), ('THROW'), ('THRUM'), ('THUMB'), ('THUMP'),
  ('THYME'), ('TIARA'), ('TIBIA'), ('TIDAL'), ('TIGER'), ('TIGHT'), ('TILDE'), ('TIMER'), ('TIMID'), ('TIPSY'), ('TITAN'), ('TITHE'),
  ('TITLE'), ('TOAST'), ('TODAY'), ('TODDY'), ('TOKEN'), ('TONAL'), ('TONGA'), ('TONIC'), ('TOOTH'), ('TOPAZ'), ('TOPIC'), ('TORCH'),
  ('TORSO'), ('TORUS'), ('TOTAL'), ('TOTEM'), ('TOUCH'), ('TOUGH'), ('TOWEL'), ('TOWER'), ('TOXIC'), ('TOXIN'), ('TRACE'), ('TRACK'),
  ('TRACT'), ('TRADE'), ('TRAIL'), ('TRAIN'), ('TRAIT'), ('TRAMP'), ('TRASH'), ('TRAWL'), ('TREAD'), ('TREAT'), ('TREND'), ('TRIAD'),
  ('TRIAL'), ('TRIBE'), ('TRICE'), ('TRICK'), ('TRIED'), ('TRIPE'), ('TRITE'), ('TROLL'), ('TROOP'), ('TROPE'), ('TROUT'), ('TROVE'),
  ('TRUCE'), ('TRUCK'), ('TRUER'), ('TRULY'), ('TRUMP'), ('TRUNK'), ('TRUSS'), ('TRUST'), ('TRUTH'), ('TRYST'), ('TUBAL'), ('TUBER'),
  ('TULIP'), ('TULLE'), ('TUMOR'), ('TUNIC'), ('TURBO'), ('TUTOR'), ('TWANG'), ('TWEAK'), ('TWEED'), ('TWEET'), ('TWICE'), ('TWINE'),
  ('TWIRL'), ('TWIST'), ('TWIXT'), ('TYING'), ('UDDER'), ('ULCER'), ('ULTRA'), ('UMBRA'), ('UNCLE'), ('UNCUT'), ('UNDER'), ('UNDID'),
  ('UNDUE'), ('UNFED'), ('UNFIT'), ('UNIFY'), ('UNION'), ('UNITE'), ('UNITY'), ('UNLIT'), ('UNMET'), ('UNSET'), ('UNTIE'), ('UNTIL'),
  ('UNWED'), ('UNZIP'), ('UPPER'), ('UPSET'), ('URBAN'), ('URINE'), ('USAGE'), ('USHER'), ('USING'), ('USUAL'), ('USURP'), ('UTILE'),
  ('UTTER'), ('VAGUE'), ('VALET'), ('VALID'), ('VALOR'), ('VALUE'), ('VALVE'), ('VAPID'), ('VAPOR'), ('VAULT'), ('VAUNT'), ('VEGAN'),
  ('VENOM'), ('VENUE'), ('VERGE'), ('VERSE'), ('VERSO'), ('VERVE'), ('VICAR'), ('VIDEO'), ('VIGIL'), ('VIGOR'), ('VILLA'), ('VINYL'),
  ('VIOLA'), ('VIPER'), ('VIRAL'), ('VIRUS'), ('VISIT'), ('VISOR'), ('VISTA'), ('VITAL'), ('VIVID'), ('VIXEN'), ('VOCAL'), ('VODKA'),
  ('VOGUE'), ('VOICE'), ('VOILA'), ('VOMIT'), ('VOTER'), ('VOUCH'), ('VOWEL'), ('VYING'), ('WACKY'), ('WAFER'), ('WAGER'), ('WAGON'),
  ('WAIST'), ('WAIVE'), ('WALTZ'), ('WARTY'), ('WASTE'), ('WATCH'), ('WATER'), ('WAVER'), ('WAXEN'), ('WEARY'), ('WEAVE'), ('WEDGE'),
  ('WEEDY'), ('WEIGH'), ('WEIRD'), ('WELCH'), ('WELSH'), ('WHACK'), ('WHALE'), ('WHARF'), ('WHEAT'), ('WHEEL'), ('WHELP'), ('WHERE'),
  ('WHICH'), ('WHIFF'), ('WHILE'), ('WHINE'), ('WHINY'), ('WHIRL'), ('WHISK'), ('WHITE'), ('WHOLE'), ('WHOOP'), ('WHOSE'), ('WIDEN'),
  ('WIDER'), ('WIDOW'), ('WIDTH'), ('WIELD'), ('WIGHT'), ('WILLY'), ('WIMPY'), ('WINCE'), ('WINCH'), ('WINDY'), ('WISER'), ('WISPY'),
  ('WITCH'), ('WITTY'), ('WOKEN'), ('WOMAN'), ('WOMEN'), ('WOODY'), ('WOOER'), ('WOOLY'), ('WOOZY'), ('WORDY'), ('WORLD'), ('WORRY'),
  ('WORSE'), ('WORST'), ('WORTH'), ('WOULD'), ('WOUND'), ('WOVEN'), ('WRACK'), ('WRATH'), ('WREAK'), ('WRECK'), ('WREST'), ('WRING'),
  ('WRIST'), ('WRITE'), ('WRONG'), ('WROTE'), ('WRUNG'), ('WRYLY'), ('YACHT'), ('YEARN'), ('YEAST'), ('YIELD'), ('YOUNG'), ('YOUTH'),
  ('ZEBRA'), ('ZESTY'), ('ZONAL')
on conflict do nothing;

-- #####################################################################
-- TACTISCHE BATTLES
-- #####################################################################
create table if not exists public.tbattles (
  id bigserial primary key,
  mode text not null check (mode in ('pve', 'pvp')),
  difficulty text check (difficulty in ('easy', 'normal', 'hard')),
  player_a uuid not null references auth.users(id) on delete cascade,   -- speler / uitdager
  player_b uuid references auth.users(id) on delete cascade,            -- vriend (null = computer)
  status text not null default 'pending' check (status in ('pending', 'active', 'done', 'declined', 'cancelled')),
  state jsonb,                 -- publiek spelverloop (nooit geheime zetten)
  round int not null default 0,
  winner text check (winner in ('A', 'B')),
  forfeit boolean not null default false,
  coins_a int not null default 0,
  coins_b int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists tbattles_a_idx on public.tbattles (player_a, status);
create index if not exists tbattles_b_idx on public.tbattles (player_b, status);
alter table public.tbattles enable row level security;
drop policy if exists "eigen tactische battles lezen" on public.tbattles;
create policy "eigen tactische battles lezen" on public.tbattles
  for select to authenticated using (auth.uid() = player_a or auth.uid() = player_b);

-- Geheime gegevens: het team van de uitdager (tot de ander accepteert) en de gekozen zetten
create table if not exists public.tbattle_hidden (
  battle_id bigint not null references public.tbattles(id) on delete cascade,
  side text not null check (side in ('A', 'B')),
  cards int[],
  action text,
  target int,
  primary key (battle_id, side)
);
alter table public.tbattle_hidden enable row level security;
-- Bewust GEEN policies: niemand kan de zet van de tegenstander lezen.

-- 2. Hulpfuncties ----------------------------------------------------------------
create or replace function public._tb_team_ok(p_user uuid, p_cards int[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(array_length(p_cards, 1), 0) = 3
     and (select count(distinct x) from unnest(p_cards) x) = 3
     and not exists (select 1 from unnest(p_cards) x
                     where not exists (select 1 from public.user_cards uc where uc.user_id = p_user and uc.card_id = x));
$$;

-- Eén kant van het speelveld, met de stats van de kaarten
create or replace function public._tb_side(p_cards int[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cards', jsonb_agg(c.id order by u.ord),
    'hp', jsonb_agg(coalesce(c.hp, 50) order by u.ord),
    'max', jsonb_agg(coalesce(c.hp, 50) order by u.ord),
    'atk', jsonb_agg(coalesce(c.attack, 10) order by u.ord),
    'def', jsonb_agg(coalesce(c.defense, 0) order by u.ord),
    'sp', jsonb_agg(coalesce(c.special_power, 0) order by u.ord),
    'active', 0, 'energy', 1)
  from unnest(p_cards) with ordinality u(id, ord) join public.cards c on c.id = u.id;
$$;

create or replace function public._tb_pay(p_user uuid, p_amount int) returns void
language sql security definer set search_path = public as $$
  insert into public.user_wallet (user_id, polycoins) values (p_user, p_amount)
  on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
$$;

-- Aantal beloonde battles van vandaag (Belgische tijd) voor een gebruiker en modus
create or replace function public._tb_rewarded_today(p_user uuid, p_mode text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.tbattles b
  where b.mode = p_mode and b.status = 'done'
    and (b.finished_at at time zone 'Europe/Brussels')::date = (now() at time zone 'Europe/Brussels')::date
    and ((b.player_a = p_user and b.coins_a > 0) or (b.player_b = p_user and b.coins_b > 0));
$$;

-- Zet van de computer
create or replace function public._tb_ai(p_state jsonb, p_side text, p_diff text) returns jsonb
language plpgsql volatile as $$
declare
  me jsonb := p_state -> p_side;
  op jsonb := p_state -> (case p_side when 'A' then 'B' else 'A' end);
  a int := (me->>'active')::int;
  o int := (op->>'active')::int;
  en int := (me->>'energy')::int;
  sp int := (me->'sp'->>a)::int;
  hp_pct float8 := (me->'hp'->>a)::float8 / greatest(1, (me->'max'->>a)::float8);
  best int; best_pct float8 := 0; i int; r float8 := random();
begin
  if p_diff = 'easy' then
    if sp > 0 and en >= 4 and r < .5 then return '{"a":"special"}'; end if;
    if en >= 2 and r < .2 then return '{"a":"power"}'; end if;
    if r < .35 then return '{"a":"guard"}'; end if;
    return '{"a":"attack"}';
  end if;
  if sp > 0 and en >= 4 then return '{"a":"special"}'; end if;
  -- Zwakke kaart in veiligheid brengen
  for i in 0..jsonb_array_length(me->'hp') - 1 loop
    if i <> a and (me->'hp'->>i)::int > 0
       and (me->'hp'->>i)::float8 / (me->'max'->>i)::float8 > best_pct then
      best := i; best_pct := (me->'hp'->>i)::float8 / (me->'max'->>i)::float8;
    end if;
  end loop;
  if hp_pct < .3 and best is not null and best_pct > .6 and random() < (case p_diff when 'hard' then .6 else .35 end) then
    return jsonb_build_object('a', 'switch', 't', best);
  end if;
  -- Verdedigen als de tegenstander een special klaar heeft
  if (op->'sp'->>o)::int > 0 and (op->>'energy')::int >= 4 and random() < (case p_diff when 'hard' then .7 else .4 end) then
    return '{"a":"guard"}';
  end if;
  if en >= 2 and random() < .6 then return '{"a":"power"}'; end if;
  if p_diff = 'hard' and en < 2 and random() < .2 then return '{"a":"guard"}'; end if;
  return '{"a":"attack"}';
end $$;

-- Eén ronde afwikkelen zodra beide zetten gekend zijn
create or replace function public._tb_resolve(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  b public.tbattles;
  st jsonb; ev jsonb; r int;
  act jsonb;
  s text; d text; att text; kind text;
  order_ text[]; dmg int; base float8; crit boolean; guarded boolean;
  ai int; di int; nxt int; i int; w text;
  v_ca int := 0; v_cb int := 0; reward int;
begin
  select * into b from public.tbattles where id = p_id for update;
  st := b.state || '{"_act": {}}'::jsonb; ev := coalesce(st->'events', '[]'::jsonb); r := b.round + 1;
  -- Gekozen zetten ophalen: {"_act": {"A": {"a": .., "t": ..}, "B": {...}}}
  for s in select unnest(array['A', 'B']) loop
    select jsonb_build_object('a', h.action, 't', h.target) into act from public.tbattle_hidden h where h.battle_id = p_id and h.side = s;
    st := jsonb_set(st, array['_act', s], coalesce(act, '{"a": "attack"}'::jsonb));
  end loop;

  -- Opgeven
  for s in select unnest(array['A', 'B']) loop
    if st->'_act'->s->>'a' = 'forfeit' then
      w := case s when 'A' then 'B' else 'A' end;
      ev := ev || jsonb_build_object('r', r, 't', 'forfeit', 's', s);
    end if;
  end loop;

  if w is null then
    -- 1. Wissels
    for s in select unnest(array['A', 'B']) loop
      if st->'_act'->s->>'a' = 'switch' then
        st := jsonb_set(st, array[s, 'active'], to_jsonb((st->'_act'->s->>'t')::int));
        ev := ev || jsonb_build_object('r', r, 't', 'switch', 's', s, 'i', (st->'_act'->s->>'t')::int);
      elsif st->'_act'->s->>'a' = 'guard' then
        ev := ev || jsonb_build_object('r', r, 't', 'guard', 's', s);
      end if;
    end loop;
    -- 2. Energie betalen
    for s in select unnest(array['A', 'B']) loop
      if st->'_act'->s->>'a' = 'power' then
        st := jsonb_set(st, array[s, 'energy'], to_jsonb((st->s->>'energy')::int - 2));
      elsif st->'_act'->s->>'a' = 'special' then
        st := jsonb_set(st, array[s, 'energy'], to_jsonb((st->s->>'energy')::int - 4));
      end if;
    end loop;
    -- 3. Aanvallen: hoogste ATK eerst (gelijk = toeval)
    order_ := case
      when (st->'A'->'atk'->>((st->'A'->>'active')::int))::int + random() * .5 >=
           (st->'B'->'atk'->>((st->'B'->>'active')::int))::int + random() * .5
      then array['A', 'B'] else array['B', 'A'] end;
    foreach s in array order_ loop
      kind := st->'_act'->s->>'a';
      if kind not in ('attack', 'power', 'special') then continue; end if;
      d := case s when 'A' then 'B' else 'A' end;
      ai := (st->s->>'active')::int; di := (st->d->>'active')::int;
      if (st->s->'hp'->>ai)::int = 0 then continue; end if;          -- al uitgeschakeld deze ronde
      crit := false; guarded := false;
      if kind = 'special' then
        dmg := (st->s->'sp'->>ai)::int;
      else
        base := greatest((st->s->'atk'->>ai)::int * .25,
                         (st->s->'atk'->>ai)::int * (.85 + random() * .3) - (st->d->'def'->>di)::int * .5);
        if kind = 'power' then base := base * 1.7; end if;
        if random() < .1 then base := base * 1.5; crit := true; end if;
        if st->'_act'->d->>'a' = 'guard' then base := base * .5; guarded := true; end if;
        dmg := greatest(1, round(base))::int;
      end if;
      st := jsonb_set(st, array[d, 'hp', di::text], to_jsonb(greatest(0, (st->d->'hp'->>di)::int - dmg)));
      ev := ev || jsonb_build_object('r', r, 't', 'atk', 's', s, 'k', kind, 'd', dmg, 'crit', crit, 'guarded', guarded,
                                     'ai', ai, 'di', di, 'hp', (st->d->'hp'->>di)::int);
      if (st->d->'hp'->>di)::int = 0 then
        ev := ev || jsonb_build_object('r', r, 't', 'ko', 's', d, 'i', di);
      end if;
    end loop;
    -- 4. Energie bijtanken
    for s in select unnest(array['A', 'B']) loop
      st := jsonb_set(st, array[s, 'energy'], to_jsonb(least(5,
        (st->s->>'energy')::int + case st->'_act'->s->>'a' when 'guard' then 2 when 'attack' then 1 when 'switch' then 1 else 0 end)));
    end loop;
    -- 5. Uitgeschakelde kaarten vervangen, of einde
    for s in select unnest(array['A', 'B']) loop
      ai := (st->s->>'active')::int;
      if (st->s->'hp'->>ai)::int = 0 then
        nxt := null;
        for i in 0..jsonb_array_length(st->s->'hp') - 1 loop
          if (st->s->'hp'->>i)::int > 0 then nxt := i; exit; end if;
        end loop;
        if nxt is null then
          w := case s when 'A' then 'B' else 'A' end;
        else
          st := jsonb_set(st, array[s, 'active'], to_jsonb(nxt));
          ev := ev || jsonb_build_object('r', r, 't', 'enter', 's', s, 'i', nxt);
        end if;
      end if;
    end loop;
    -- Veiligheidsnet: na 60 rondes wint wie procentueel het meeste HP over heeft
    if w is null and r >= 60 then
      w := case when (select sum((h.v)::float8 / m.v::float8) from jsonb_array_elements_text(st->'A'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'A'->'max') with ordinality m(v, n) using (n))
                  >= (select sum((h.v)::float8 / m.v::float8) from jsonb_array_elements_text(st->'B'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'B'->'max') with ordinality m(v, n) using (n))
               then 'A' else 'B' end;
    end if;
  end if;

  st := st - '_act';
  st := jsonb_set(st, '{moved}', '{"A": false, "B": false}');
  update public.tbattle_hidden set action = null, target = null where battle_id = p_id;

  if w is not null then
    ev := ev || jsonb_build_object('r', r, 't', 'end', 'w', w);
    -- Beloningen
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
      -- Opgeven vóór ronde 3 levert niemand iets op (voorkomt coins "farmen" met een vriend)
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

revoke all on function public._tb_team_ok(uuid, int[]) from public, anon, authenticated;
revoke all on function public._tb_side(int[]) from public, anon, authenticated;
revoke all on function public._tb_pay(uuid, int) from public, anon, authenticated;
revoke all on function public._tb_rewarded_today(uuid, text) from public, anon, authenticated;
revoke all on function public._tb_ai(jsonb, text, text) from public, anon, authenticated;
revoke all on function public._tb_resolve(bigint) from public, anon, authenticated;

-- 3. Gevecht tegen de computer starten ------------------------------------------------
create or replace function public.tb_start_pve(p_cards int[], p_difficulty text) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  opp int[] := '{}'; c int; rar text; v_id bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_difficulty not in ('easy', 'normal', 'hard') then raise exception 'Onbekende moeilijkheid.'; end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  -- Een eventueel vorig, onafgewerkt oefengevecht vervalt
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
          jsonb_build_object('A', public._tb_side(p_cards), 'B', public._tb_side(opp), 'events', '[]'::jsonb,
                             'moved', '{"A": false, "B": false}'::jsonb))
  returning id into v_id;
  insert into public.tbattle_hidden (battle_id, side) values (v_id, 'A'), (v_id, 'B');
  return v_id;
end $$;

-- 4. Vriend uitdagen / reageren ----------------------------------------------------------
create or replace function public.tb_challenge(p_friend uuid, p_cards int[]) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_id bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if not exists (select 1 from public.friendships where user_id = me and friend_id = p_friend) then
    raise exception 'Jullie zijn geen vrienden.';
  end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  if exists (select 1 from public.tbattles where mode = 'pvp' and status in ('pending', 'active')
             and ((player_a = me and player_b = p_friend) or (player_a = p_friend and player_b = me))) then
    raise exception 'Er loopt al een battle tussen jullie.';
  end if;
  insert into public.tbattles (mode, player_a, player_b, status) values ('pvp', me, p_friend, 'pending') returning id into v_id;
  insert into public.tbattle_hidden (battle_id, side, cards) values (v_id, 'A', p_cards);
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
    state = jsonb_build_object('A', public._tb_side(a_cards), 'B', public._tb_side(p_cards), 'events', '[]'::jsonb,
                               'moved', '{"A": false, "B": false}'::jsonb)
  where id = p_id;
end $$;

-- 5. Een zet doen ------------------------------------------------------------------------
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
  -- Opgeven mag altijd, ook als je deze ronde al gekozen hebt
  if p_action <> 'forfeit' and (b.state->'moved'->>s)::boolean then
    raise exception 'Je hebt deze ronde al gekozen. Wacht op je tegenstander.';
  end if;

  v_side := b.state->s; a := (v_side->>'active')::int;
  if p_action = 'power' and (v_side->>'energy')::int < 2 then raise exception 'Niet genoeg energie (2 nodig).'; end if;
  if p_action = 'special' then
    if (v_side->'sp'->>a)::int <= 0 then raise exception 'Deze kaart heeft geen special.'; end if;
    if (v_side->>'energy')::int < 4 then raise exception 'Niet genoeg energie (4 nodig).'; end if;
  end if;
  if p_action = 'switch' then
    if p_target is null or p_target < 0 or p_target >= jsonb_array_length(v_side->'hp') or p_target = a
       or (v_side->'hp'->>p_target)::int <= 0 then
      raise exception 'Kies een andere kaart die nog kan vechten.';
    end if;
  end if;
  if p_action not in ('attack', 'power', 'guard', 'special', 'switch', 'forfeit') then raise exception 'Onbekende zet.'; end if;

  update public.tbattle_hidden h set action = p_action, target = case when p_action = 'switch' then p_target end
    where h.battle_id = p_id and h.side = s;
  update public.tbattles set state = jsonb_set(state, array['moved', s], 'true'), updated_at = now() where id = p_id;

  if b.mode = 'pve' then
    ai := public._tb_ai(b.state, o, b.difficulty);
    update public.tbattle_hidden h set action = ai->>'a', target = (ai->>'t')::int where h.battle_id = p_id and h.side = o;
    perform public._tb_resolve(p_id);
  elsif p_action = 'forfeit' or (b.state->'moved'->>o)::boolean then
    -- Opgeven geldt meteen; anders pas afwikkelen als beide spelers gekozen hebben
    perform public._tb_resolve(p_id);
  end if;

  select * into b from public.tbattles where id = p_id;
  return to_jsonb(b);
end $$;

-- 6. Ranglijst (oude + nieuwe gevechten tegen vrienden) ------------------------------------
create or replace function public.tb_leaderboard()
returns table (user_id uuid, display_name text, avatar_url text, wins bigint, losses bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  -- De oude gevechtentabel (schema-v6) telt enkel mee als die bestaat
  old_sql text := case when to_regclass('public.battles') is not null then
    'select winner_id as winner, challenger_id as p1, opponent_id as p2 from public.battles where status = ''done'' union all '
    else '' end;
begin
  if auth.uid() is null then return; end if;
  return query execute
    'with people as (
       select $1 as id
       union select f.friend_id from public.friendships f where f.user_id = $1
     ),
     results as (' || old_sql || '
       select case winner when ''A'' then player_a else player_b end as winner, player_a as p1, player_b as p2
       from public.tbattles where mode = ''pvp'' and status = ''done''
     )
     select p.id, pr.display_name, pr.avatar_url,
       (select count(*) from results r where r.winner = p.id),
       (select count(*) from results r where (r.p1 = p.id or r.p2 = p.id) and r.winner <> p.id)
     from people p join public.profiles pr on pr.id = p.id
     order by 4 desc, 5 asc, 2'
  using auth.uid();
end $$;

-- Hoeveel beloonde overwinningen heb ik vandaag nog?
create or replace function public.tb_rewards_today()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('pve', public._tb_rewarded_today(auth.uid(), 'pve'), 'pve_max', 5,
                            'pvp', public._tb_rewarded_today(auth.uid(), 'pvp'), 'pvp_max', 3);
$$;

grant execute on function public.tb_start_pve(int[], text) to authenticated;
grant execute on function public.tb_challenge(uuid, int[]) to authenticated;
grant execute on function public.tb_respond(bigint, text, int[]) to authenticated;
grant execute on function public.tb_act(bigint, text, int) to authenticated;
grant execute on function public.tb_leaderboard() to authenticated;
grant execute on function public.tb_rewards_today() to authenticated;

-- #####################################################################
-- SHOP
-- #####################################################################
revoke insert, update, delete on public.user_wallet from anon, authenticated;
revoke insert, update, delete on public.user_cards from anon, authenticated;
revoke insert, update, delete on public.daily_plays from anon, authenticated;

-- 1. Wordle-hulp: extra kolommen ------------------------------------------------------
alter table public.wordle_games add column if not exists hints jsonb not null default '[]'::jsonb;
alter table public.wordle_games add column if not exists extra_guess boolean not null default false;

-- 2. Logboek van aankopen (enkel je eigen rijen zichtbaar) ------------------------------
create table if not exists public.shop_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  amount int not null,            -- negatief = uitgegeven, positief = verdiend
  detail jsonb,
  created_at timestamptz not null default now()
);
create index if not exists shop_log_user_idx on public.shop_log (user_id, created_at desc);
alter table public.shop_log enable row level security;
drop policy if exists "eigen aankopen lezen" on public.shop_log;
create policy "eigen aankopen lezen" on public.shop_log for select to authenticated using (auth.uid() = user_id);

-- 3. Hulpfuncties ------------------------------------------------------------------------
-- Polycoins uitgeven: faalt als het saldo te laag is (geen negatief saldo mogelijk)
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

-- Eén kaart van een bepaalde zeldzaamheid toevoegen aan de collectie
create or replace function public._shop_give(p_user uuid, p_rarity text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_card public.cards; v_dup boolean;
begin
  select * into v_card from public.cards where rarity = p_rarity order by random() limit 1;
  if not found then raise exception 'Geen kaarten gevonden voor zeldzaamheid %.', p_rarity; end if;
  v_dup := exists (select 1 from public.user_cards where user_id = p_user and card_id = v_card.id);
  insert into public.user_cards (user_id, card_id) values (p_user, v_card.id);
  return to_jsonb(v_card) || jsonb_build_object('is_duplicate', v_dup);
end $$;

create or replace function public._shop_roll(p_legendary float8, p_epic float8) returns text
language sql volatile as $$
  select case when r < p_legendary then 'legendary' when r < p_legendary + p_epic then 'epic' else 'common' end
  from (select random() * 100 as r) x;
$$;

revoke all on function public._shop_spend(uuid, int, text, jsonb) from public, anon, authenticated;
revoke all on function public._shop_give(uuid, text) from public, anon, authenticated;

-- 4. Pakjes kopen --------------------------------------------------------------------------
create or replace function public.shop_buy_pack(p_kind text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_wallet int; v_cards jsonb := '[]'::jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_kind = 'basic' then
    v_wallet := public._shop_spend(me, 60, 'pack_basic');
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
  elsif p_kind = 'epic' then
    v_wallet := public._shop_spend(me, 200, 'pack_epic');
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(15, 85));
  else
    raise exception 'Onbekend pakje.';
  end if;
  update public.shop_log set detail = jsonb_build_object('cards', (select jsonb_agg(c->'id') from jsonb_array_elements(v_cards) c))
    where id = (select max(id) from public.shop_log where user_id = me);
  return jsonb_build_object('cards', v_cards, 'wallet', v_wallet);
end $$;

-- 5. Een ontbrekende kaart kopen -------------------------------------------------------------
create or replace function public.shop_buy_card(p_card_id int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_card public.cards; v_price int; v_wallet int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into v_card from public.cards where id = p_card_id;
  if not found then raise exception 'Kaart niet gevonden.'; end if;
  if v_card.rarity = 'cat' then raise exception 'Troostkatten zijn niet te koop.'; end if;
  if exists (select 1 from public.user_cards where user_id = me and card_id = p_card_id) then
    raise exception 'Je hebt deze kaart al.';
  end if;
  v_price := case v_card.rarity when 'common' then 150 when 'epic' then 400 else 1000 end;
  v_wallet := public._shop_spend(me, v_price, 'buy_card', jsonb_build_object('card', p_card_id));
  insert into public.user_cards (user_id, card_id) values (me, p_card_id);
  return jsonb_build_object('card', to_jsonb(v_card), 'wallet', v_wallet);
end $$;

-- 6. Dubbels verkopen (je houdt altijd minstens 1 exemplaar) -----------------------------------
create or replace function public.shop_sell_duplicates(p_card_id int, p_count int default 1) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_card public.cards; v_have int; v_price int; v_earned int; v_wallet int; i int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_count < 1 then raise exception 'Verkoop minstens 1 exemplaar.'; end if;
  select * into v_card from public.cards where id = p_card_id;
  if not found then raise exception 'Kaart niet gevonden.'; end if;
  select count(*) into v_have from public.user_cards where user_id = me and card_id = p_card_id;
  if v_have - p_count < 1 then raise exception 'Je kan enkel dubbels verkopen: je houdt altijd 1 exemplaar.'; end if;
  for i in 1..p_count loop
    delete from public.user_cards where id = (select id from public.user_cards where user_id = me and card_id = p_card_id order by id desc limit 1);
  end loop;
  v_price := case v_card.rarity when 'common' then 15 when 'epic' then 40 when 'legendary' then 100 else 5 end;
  v_earned := v_price * p_count;
  insert into public.user_wallet (user_id, polycoins) values (me, v_earned)
    on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins
    returning polycoins into v_wallet;
  insert into public.shop_log (user_id, kind, amount, detail) values (me, 'sell_duplicate', v_earned, jsonb_build_object('card', p_card_id, 'count', p_count));
  return jsonb_build_object('sold', p_count, 'earned', v_earned, 'wallet', v_wallet);
end $$;

-- 7. Wordle-hulp ---------------------------------------------------------------------------------
-- Onthult een letter op een plaats die je nog niet groen hebt (max 2 per ronde)
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

-- Koopt een 7e poging voor deze ronde (moet vóór je 6e gok)
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

-- 8. Bijgewerkte Wordle-functies (7e poging + onthulde letters) -----------------------------------
create or replace function public._wordle_draw(p_user uuid, p_attempts int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r float8 := random() * 100;
  leg float8; ep float8; v_rarity text;
  v_card public.cards; v_dup boolean; v_coins int;
begin
  if p_attempts is null then
    v_rarity := 'cat';
  else
    leg := (array[80, 30, 10, 3, 1, 0.5])[least(p_attempts, 6)];
    ep  := (array[20, 50, 35, 22, 11, 4.5])[least(p_attempts, 6)];
    v_rarity := case when r < leg then 'legendary' when r < leg + ep then 'epic' else 'common' end;
  end if;
  select * into v_card from public.cards where rarity = v_rarity order by random() limit 1;
  if not found then raise exception 'Geen kaarten gevonden voor zeldzaamheid %.', v_rarity; end if;
  v_dup := exists (select 1 from public.user_cards where user_id = p_user and card_id = v_card.id);
  insert into public.user_cards (user_id, card_id) values (p_user, v_card.id);  -- dubbels komen er ook bij
  v_coins := 0;
  if v_dup then
    v_coins := case v_rarity when 'common' then 10 when 'epic' then 25 when 'legendary' then 60 else 5 end;
    insert into public.user_wallet (user_id, polycoins) values (p_user, v_coins)
      on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
  end if;
  return jsonb_build_object('card', to_jsonb(v_card), 'dup', v_dup, 'coins', v_coins);
end $$;


revoke all on function public._wordle_draw(uuid, int) from public, anon, authenticated;

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


grant execute on function public.shop_buy_pack(text) to authenticated;
-- Gericht een kaart kopen is uitgeschakeld (zou tonen welke kaarten er bestaan)
revoke execute on function public.shop_buy_card(int) from public, anon, authenticated;
grant execute on function public.shop_sell_duplicates(int, int) to authenticated;
grant execute on function public.wordle_hint(int) to authenticated;
grant execute on function public.wordle_extra_guess(int) to authenticated;

-- #####################################################################
-- IDEEËNBUS
-- #####################################################################
create table if not exists public.suggestions (
  id bigserial primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 3 and 500),
  status text not null default 'open' check (status in ('open', 'planned', 'done', 'rejected')),
  created_at timestamptz not null default now()
);
create table if not exists public.suggestion_votes (
  suggestion_id bigint not null references public.suggestions(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (suggestion_id, user_id)
);
alter table public.suggestions enable row level security;
alter table public.suggestion_votes enable row level security;

-- Is de ingelogde gebruiker admin? (werkt ook als de admins-tabel nog niet bestaat)
create or replace function public.is_admin() returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if to_regclass('public.admins') is null then return false; end if;
  return exists (select 1 from public.admins where user_id = auth.uid());
end $$;
grant execute on function public.is_admin() to authenticated;

-- Ideeën
drop policy if exists "ideeen lezen" on public.suggestions;
create policy "ideeen lezen" on public.suggestions for select to authenticated using (true);
drop policy if exists "idee indienen" on public.suggestions;
create policy "idee indienen" on public.suggestions for insert to authenticated
  with check (user_id = auth.uid() and status = 'open');
drop policy if exists "idee verwijderen" on public.suggestions;
create policy "idee verwijderen" on public.suggestions for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists "status aanpassen (admin)" on public.suggestions;
create policy "status aanpassen (admin)" on public.suggestions for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Stemmen
drop policy if exists "stemmen lezen" on public.suggestion_votes;
create policy "stemmen lezen" on public.suggestion_votes for select to authenticated using (true);
drop policy if exists "stemmen" on public.suggestion_votes;
create policy "stemmen" on public.suggestion_votes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "stem intrekken" on public.suggestion_votes;
create policy "stem intrekken" on public.suggestion_votes for delete to authenticated using (user_id = auth.uid());

grant select, insert, delete on public.suggestions to authenticated;
grant update (status) on public.suggestions to authenticated;
grant select, insert, delete on public.suggestion_votes to authenticated;
grant usage on sequence public.suggestions_id_seq to authenticated;

-- =====================================================================
-- ADMIN: voer NA het aanmaken van je eigen account dit apart uit (met je eigen e-mailadres):
--   insert into public.admins (user_id)
--   select id from auth.users where lower(email) = 'jouw@email.be' on conflict do nothing;
-- =====================================================================

-- =====================================================================
-- CAMPUS-UPDATE (zelfde inhoud als update-04-campus.sql)
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

-- =====================================================================
-- FRAT HOUSE-UPDATE (zelfde inhoud als update-05-frathouse.sql)
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
drop function if exists public.house_members();
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

-- =====================================================================
-- LESSENROOSTER-UPDATE (zelfde inhoud als update-06-lessenrooster.sql)
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

-- =====================================================================
-- ROOSTER-ADMIN-UPDATE (zelfde inhoud als update-07-rooster-admin.sql)
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

-- =====================================================================
-- VRIENDEN-UPDATE (zelfde inhoud als update-08-vrienden.sql)
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

-- =====================================================================
-- MOEILIJKER-UPDATE (zelfde inhoud als update-09-moeilijker.sql)
-- =====================================================================
-- Grenzen per spel: [laagste score, hoogste score, minimum aantal seconden, A, B, C, D]
create or replace function public._exam_rules(p_game text) returns int[]
language sql immutable as $$
  select case p_game
    when 'math'      then array[0, 80, 55, 22, 17, 12, 7]      -- juiste sommen in 60 seconden
    when 'hoops'     then array[0, 10, 8, 8, 6, 4, 2]          -- raak uit 10 worpen
    when 'history'   then array[0, 10, 12, 9, 7, 5, 3]         -- juist uit 10 vragen
    when 'launch'    then array[0, 8, 8, 6, 5, 3, 1]           -- raak uit 8 schoten
    when 'darts'     then array[0, 360, 6, 190, 150, 110, 70]  -- punten met 6 pijlen
    when 'blackjack' then array[0, 400, 6, 160, 125, 100, 70]  -- chips na 10 handen (start 100)
    when 'pong'      then array[0, 6, 6, 6, 5, 4, 2]
    when 'pour'      then array[0, 500, 8, 440, 380, 300, 200]
  end;
$$;

-- =====================================================================
-- MELDINGEN-UPDATE (zelfde inhoud als update-11-meldingen.sql)
-- =====================================================================
-- 1. Tabellen voor de toestellen die meldingen willen, en voor de sleutels van de meldingen
--    (die maakt de functie rizz-push zelf aan; enkel de server kan ze lezen).
-- 2. Functies om je toestel in of uit te schrijven.
-- 3. Elk uur roept de database de functie rizz-push aan; die verstuurt enkel om 19u
--    (Belgische tijd) een herinnering naar wie zijn examen nog niet speelde, max. 1 per dag.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
-- =====================================================================

-- 1. Tabellen --------------------------------------------------------------------------------
create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now(),
  last_sent date
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
-- Bewust geen policies: alles verloopt via de functies hieronder (en de server).

create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  public_key text not null,
  private_key text not null
);
alter table public.push_config enable row level security;
revoke all on public.push_config from anon, authenticated;

-- 2. In- en uitschrijven ------------------------------------------------------------------------
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'Ongeldig toestel.'; end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;
grant execute on function public.save_push_subscription(text, text, text) to authenticated;

create or replace function public.delete_push_subscription(p_endpoint text) returns void
language sql volatile security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;
grant execute on function public.delete_push_subscription(text) to authenticated;

-- Wie krijgt vandaag een herinnering: ingeschreven, examen nog niet gespeeld, nog geen melding vandaag
create or replace function public.push_targets()
returns table (endpoint text, p256dh text, auth text, game text, today date)
language sql stable security definer set search_path = public as $$
  with d as (select (now() at time zone 'Europe/Brussels')::date as today)
  select s.endpoint, s.p256dh, s.auth, public._exam_game(d.today), d.today
  from public.push_subscriptions s, d
  where (s.last_sent is null or s.last_sent < d.today)
    and not exists (select 1 from public.exam_results e
                    where e.user_id = s.user_id and e.exam_date = d.today and e.status = 'done');
$$;
revoke all on function public.push_targets() from public, anon, authenticated;
grant execute on function public.push_targets() to service_role;

-- 3. Elk uur de functie aanroepen (ze verstuurt zelf enkel om 19u) ---------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule(jobid) from cron.job where jobname = 'rizz-herinnering';
select cron.schedule('rizz-herinnering', '0 * * * *', $cron$
  select net.http_post(
    url := 'https://njrqohhmlosvkandtkll.supabase.co/functions/v1/rizz-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5qcnFvaGhtbG9zdmthbmR0a2xsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExMDY1NTAsImV4cCI6MjEwNjY4MjU1MH0.c19_JTKlto6buo8jeekMBSwwjPa_Le_tKjDsimPwNZY'),
    body := '{"action":"remind"}'::jsonb
  );
$cron$);

-- =====================================================================
-- TEGENSTANDER-FOTOS-UPDATE (zelfde inhoud als update-12-tegenstander-fotos.sql)
-- =====================================================================
-- Hulpfunctie: zit deze kaart in een gevecht van de ingelogde speler?
create or replace function public._card_in_my_battle(p_card int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.tbattles b
    where (b.player_a = auth.uid() or b.player_b = auth.uid())
      and b.status in ('active', 'done')
      and (coalesce(b.state->'A'->'cards', '[]'::jsonb) @> to_jsonb(p_card)
        or coalesce(b.state->'B'->'cards', '[]'::jsonb) @> to_jsonb(p_card))
  );
$$;
grant execute on function public._card_in_my_battle(int) to authenticated;

drop policy if exists "kaartfoto's van eigen kaarten" on storage.objects;
create policy "kaartfoto's van eigen kaarten" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'card-photos'
    and (
      public.is_admin()
      or exists (
        select 1
        from public.user_cards uc
        join public.cards c on c.id = uc.card_id
        where uc.user_id = auth.uid()
          and c.image_url = 'cards/' || storage.objects.name
      )
      or exists (
        select 1 from public.cards c
        where c.image_url = 'cards/' || storage.objects.name
          and public._card_in_my_battle(c.id)
      )
    )
  );

-- =====================================================================
-- CASINO-UPDATE (zelfde inhoud als update-13-casino.sql)
-- =====================================================================
-- 1. Tabellen ---------------------------------------------------------------------------------
create table if not exists public.casino_plays (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  game text not null,
  bet int not null,
  payout int not null default 0,
  result jsonb,
  play_date date not null default (now() at time zone 'Europe/Brussels')::date,
  created_at timestamptz not null default now()
);
create index if not exists casino_plays_user_day_idx on public.casino_plays (user_id, play_date);
alter table public.casino_plays enable row level security;
drop policy if exists "eigen casinospelletjes lezen" on public.casino_plays;
create policy "eigen casinospelletjes lezen" on public.casino_plays for select to authenticated using (auth.uid() = user_id);

-- Lopende blackjack-hand (één per speler). Het kaartspel blijft op de server.
create table if not exists public.casino_bj (
  user_id uuid primary key references auth.users(id) on delete cascade,
  bet int not null,
  deck int[] not null,
  player int[] not null,
  dealer int[] not null,
  created_at timestamptz not null default now()
);
alter table public.casino_bj enable row level security; -- geen policies: enkel via de functies

-- 2. Hulpfuncties -----------------------------------------------------------------------------------
create or replace function public._casino_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Brussels')::date $$;

-- Netto verlies vandaag (inclusief de inzet van een lopende blackjack-hand)
create or replace function public._casino_lost_today(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(bet - payout) from public.casino_plays where user_id = p_user and play_date = public._casino_today()), 0)::int
       + coalesce((select bet from public.casino_bj where user_id = p_user), 0);
$$;

-- Inzet controleren en van de wallet halen
create or replace function public._casino_take(p_bet int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet is null or p_bet < 5 or p_bet > 50 or p_bet % 5 <> 0 then raise exception 'Inzet: 5 tot 50 credits, per 5.'; end if;
  if public._casino_lost_today(auth.uid()) + p_bet > 100 then
    raise exception 'Daglimiet bereikt: je kan vandaag niet meer dan 100 credits verliezen in het casino. Morgen weer open.';
  end if;
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid() for update;
  if coalesce(v_coins, 0) < p_bet then raise exception 'Niet genoeg credits.'; end if;
  update public.user_wallet set polycoins = polycoins - p_bet where user_id = auth.uid();
end $$;
revoke all on function public._casino_take(int) from public, anon, authenticated;

-- Uitbetalen en het spel bijhouden; geeft de nieuwe stand terug
create or replace function public._casino_pay(p_game text, p_bet int, p_payout int, p_result jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if p_payout > 0 then update public.user_wallet set polycoins = polycoins + p_payout where user_id = auth.uid(); end if;
  insert into public.casino_plays (user_id, game, bet, payout, result) values (auth.uid(), p_game, p_bet, p_payout, p_result);
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid();
  return p_result || jsonb_build_object('bet', p_bet, 'payout', p_payout, 'wallet', v_coins, 'lost_today', public._casino_lost_today(auth.uid()));
end $$;
revoke all on function public._casino_pay(text, int, int, jsonb) from public, anon, authenticated;

-- 3. Slotmachine -------------------------------------------------------------------------------------
-- Symbolen per rol (gewicht): C kers 30 · L citroen 25 · B bel 18 · D diamant 13 · K kroon 9 · R RIZZ 5
-- 3 gelijk: RIZZ 60× · kroon 25× · diamant 15× · bel 10× · citroen 6× · kers 5×
-- 2 kersen: 2× · 1 kers: 0,4× (afgerond naar beneden)
create or replace function public._casino_reel() returns text
language sql volatile as $$
  select case when r < 30 then 'C' when r < 55 then 'L' when r < 73 then 'B' when r < 86 then 'D' when r < 95 then 'K' else 'R' end
  from (select floor(random() * 100)::int as r) x;
$$;

create or replace function public.casino_slots(p_bet int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a text; b text; c text; n int; mult numeric := 0;
begin
  perform public._casino_take(p_bet);
  a := public._casino_reel(); b := public._casino_reel(); c := public._casino_reel();
  n := (a = 'C')::int + (b = 'C')::int + (c = 'C')::int;
  if a = b and b = c then
    mult := case a when 'R' then 60 when 'K' then 25 when 'D' then 15 when 'B' then 10 when 'L' then 6 else 5 end;
  elsif n = 2 then mult := 2;
  elsif n = 1 then mult := 0.4;
  end if;
  return public._casino_pay('slots', p_bet, floor(p_bet * mult)::int, jsonb_build_object('reels', jsonb_build_array(a, b, c), 'mult', mult));
end $$;
grant execute on function public.casino_slots(int) to authenticated;

-- 4. Roulette (Europees: 0 tot 36) --------------------------------------------------------------------
-- red/black/even/odd/low (1-18)/high (19-36): 2× terug · één getal: 36× terug · 0 = huis wint de rest
create or replace function public.casino_roulette(p_bet int, p_kind text, p_number int default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int; red boolean; win boolean; mult int;
begin
  if p_kind not in ('red', 'black', 'even', 'odd', 'low', 'high', 'number') then raise exception 'Onbekende inzet.'; end if;
  if p_kind = 'number' and (p_number is null or p_number < 0 or p_number > 36) then raise exception 'Kies een getal van 0 tot 36.'; end if;
  perform public._casino_take(p_bet);
  n := floor(random() * 37)::int;
  red := n = any (array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);
  win := case p_kind
    when 'red' then n > 0 and red when 'black' then n > 0 and not red
    when 'even' then n > 0 and n % 2 = 0 when 'odd' then n % 2 = 1
    when 'low' then n between 1 and 18 when 'high' then n between 19 and 36
    else n = p_number end;
  mult := case when not win then 0 when p_kind = 'number' then 36 else 2 end;
  return public._casino_pay('roulette', p_bet, p_bet * mult,
    jsonb_build_object('number', n, 'color', case when n = 0 then 'green' when red then 'red' else 'black' end, 'kind', p_kind, 'pick', p_number, 'win', win));
end $$;
grant execute on function public.casino_roulette(int, text, int) to authenticated;

-- 5. Paardenrace --------------------------------------------------------------------------------------
-- 5 paarden met vaste kansen; uitbetaling = inzet × quotering (afgerond naar beneden)
create or replace function public.casino_horses_odds() returns jsonb
language sql immutable as $$
  select '[{"n":1,"name":"Thunder Rizz","p":34,"x":2.7},{"n":2,"name":"Lucky Legend","p":25,"x":3.6},{"n":3,"name":"Midnight Aura","p":18,"x":5.1},{"n":4,"name":"Dean''s Pick","p":14,"x":6.5},{"n":5,"name":"Last Call","p":9,"x":10.2}]'::jsonb;
$$;
grant execute on function public.casino_horses_odds() to authenticated;

create or replace function public.casino_horses(p_bet int, p_horse int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r int; acc int := 0; h jsonb; winner int; mult numeric := 0; others int[];
begin
  if p_horse not between 1 and 5 then raise exception 'Kies een paard van 1 tot 5.'; end if;
  perform public._casino_take(p_bet);
  r := floor(random() * 100)::int;
  for h in select * from jsonb_array_elements(public.casino_horses_odds()) loop
    acc := acc + (h->>'p')::int;
    if winner is null and r < acc then winner := (h->>'n')::int; if winner = p_horse then mult := (h->>'x')::numeric; end if; end if;
  end loop;
  -- Volgorde van de rest willekeurig (voor de animatie)
  select array_agg(x order by random()) into others from generate_series(1, 5) x where x <> winner;
  return public._casino_pay('horses', p_bet, floor(p_bet * mult)::int,
    jsonb_build_object('winner', winner, 'order', to_jsonb(array[winner] || others), 'pick', p_horse, 'mult', mult));
end $$;
grant execute on function public.casino_horses(int, int) to authenticated;

-- 6. Blackjack ----------------------------------------------------------------------------------------
-- Kaarten 0..51: rang = kaart % 13 (0 = aas, 1..9 = 2..10, 10..12 = boer/dame/heer)
-- Dealer pakt tot 17. Winst 2× terug, blackjack 2,5× (naar beneden), gelijk = inzet terug.
create or replace function public._bj_value(p_cards int[]) returns int
language plpgsql immutable as $$
declare t int := 0; aces int := 0; r int; c int;
begin
  foreach c in array p_cards loop
    r := c % 13;
    if r = 0 then aces := aces + 1; t := t + 11;
    elsif r >= 9 then t := t + 10;
    else t := t + r + 1; end if;
  end loop;
  while t > 21 and aces > 0 loop t := t - 10; aces := aces - 1; end loop;
  return t;
end $$;

-- Wat de speler mag zien (de verborgen kaart van de dealer enkel na afloop)
create or replace function public._bj_view(h public.casino_bj, p_done boolean) returns jsonb
language sql immutable as $$
  select jsonb_build_object('bet', h.bet, 'player', to_jsonb(h.player), 'player_total', public._bj_value(h.player),
    'dealer', case when p_done then to_jsonb(h.dealer) else to_jsonb(array[h.dealer[1]]) end,
    'dealer_total', case when p_done then public._bj_value(h.dealer) else public._bj_value(array[h.dealer[1]]) end,
    'can_double', not p_done and array_length(h.player, 1) = 2, 'done', p_done);
$$;

-- Hand afronden: dealer speelt, uitbetalen, hand weg
create or replace function public._bj_finish(h public.casino_bj, p_dealer_plays boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare pt int; dt int; outcome text; pay int;
begin
  pt := public._bj_value(h.player);
  if p_dealer_plays and pt <= 21 then
    while public._bj_value(h.dealer) < 17 loop
      h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:];
    end loop;
  end if;
  dt := public._bj_value(h.dealer);
  if pt > 21 then outcome := 'bust';
  elsif pt = 21 and array_length(h.player, 1) = 2 and not (dt = 21 and array_length(h.dealer, 1) = 2) then outcome := 'blackjack';
  elsif dt > 21 or pt > dt then outcome := 'win';
  elsif pt = dt then outcome := 'push';
  else outcome := 'lose'; end if;
  pay := case outcome when 'blackjack' then floor(h.bet * 2.5)::int when 'win' then h.bet * 2 when 'push' then h.bet else 0 end;
  delete from public.casino_bj where user_id = h.user_id;
  return public._casino_pay('blackjack', h.bet, pay, public._bj_view(h, true) || jsonb_build_object('outcome', outcome));
end $$;
revoke all on function public._bj_finish(public.casino_bj, boolean) from public, anon, authenticated;

create or replace function public.casino_bj_start(p_bet int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h public.casino_bj; deck int[];
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  select * into h from public.casino_bj where user_id = auth.uid();
  if found then return public._bj_view(h, false) || jsonb_build_object('resumed', true); end if; -- verder met de lopende hand
  perform public._casino_take(p_bet);
  select array_agg(x order by random()) into deck from generate_series(0, 51) x;
  insert into public.casino_bj (user_id, bet, deck, player, dealer)
  values (auth.uid(), p_bet, deck[5:], array[deck[1], deck[3]], array[deck[2], deck[4]])
  returning * into h;
  if public._bj_value(h.player) = 21 or public._bj_value(h.dealer) = 21 then return public._bj_finish(h, false); end if;
  return public._bj_view(h, false);
end $$;
grant execute on function public.casino_bj_start(int) to authenticated;

create or replace function public.casino_bj_action(p_action text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h public.casino_bj;
begin
  select * into h from public.casino_bj where user_id = auth.uid() for update;
  if not found then raise exception 'Er loopt geen hand.'; end if;
  if p_action = 'hit' then
    h.player := h.player || h.deck[1]; h.deck := h.deck[2:];
    update public.casino_bj set player = h.player, deck = h.deck where user_id = h.user_id;
    if public._bj_value(h.player) >= 21 then return public._bj_finish(h, true); end if;
    return public._bj_view(h, false);
  elsif p_action = 'stand' then
    return public._bj_finish(h, true);
  elsif p_action = 'double' then
    if array_length(h.player, 1) <> 2 then raise exception 'Verdubbelen kan enkel met je eerste twee kaarten.'; end if;
    -- extra inzet: zelfde controle als een nieuwe inzet (de lopende inzet telt al mee in de daglimiet)
    perform public._casino_take(h.bet);
    h.bet := h.bet * 2;
    h.player := h.player || h.deck[1]; h.deck := h.deck[2:];
    update public.casino_bj set bet = h.bet, player = h.player, deck = h.deck where user_id = h.user_id;
    return public._bj_finish(h, true);
  end if;
  raise exception 'Onbekende actie.';
end $$;
grant execute on function public.casino_bj_action(text) to authenticated;

-- 7. Stand van zaken voor de casinopagina ---------------------------------------------------------------
create or replace function public.casino_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'wallet', (select polycoins from public.user_wallet where user_id = auth.uid()),
    'lost_today', public._casino_lost_today(auth.uid()),
    'limit', 100,
    'bj', (select public._bj_view(h, false) from public.casino_bj h where h.user_id = auth.uid()),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('game', game, 'bet', bet, 'payout', payout) order by id desc)
                        from (select * from public.casino_plays where user_id = auth.uid() order by id desc limit 8) r), '[]'::jsonb)
  ) end;
$$;
grant execute on function public.casino_status() to authenticated;

-- =====================================================================
-- CASINO-ZONDER-LIMIET-UPDATE (zelfde inhoud als update-14-casino-zonder-limiet.sql)
-- =====================================================================
-- Inzet controleren en van de wallet halen (geen daglimiet meer)
create or replace function public._casino_take(p_bet int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet is null or p_bet < 5 or p_bet > 50 or p_bet % 5 <> 0 then raise exception 'Inzet: 5 tot 50 credits, per 5.'; end if;
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid() for update;
  if coalesce(v_coins, 0) < p_bet then raise exception 'Niet genoeg credits.'; end if;
  update public.user_wallet set polycoins = polycoins - p_bet where user_id = auth.uid();
end $$;
revoke all on function public._casino_take(int) from public, anon, authenticated;

-- Stand van zaken: geen limiet meer
create or replace function public.casino_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else jsonb_build_object(
    'wallet', (select polycoins from public.user_wallet where user_id = auth.uid()),
    'lost_today', public._casino_lost_today(auth.uid()),
    'limit', null,
    'bj', (select public._bj_view(h, false) from public.casino_bj h where h.user_id = auth.uid()),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('game', game, 'bet', bet, 'payout', payout) order by id desc)
                        from (select * from public.casino_plays where user_id = auth.uid() order by id desc limit 8) r), '[]'::jsonb)
  ) end;
$$;
grant execute on function public.casino_status() to authenticated;

-- =====================================================================
-- IDEEEN-UPDATE (zelfde inhoud als update-15-ideeen.sql)
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

-- =====================================================================
-- VRIJ-RUILEN-UPDATE (zelfde inhoud als update-16-vrij-ruilen.sql)
-- =====================================================================
-- 4. create_trade: nieuw ruilvoorstel aanmaken -----------------------------
create or replace function public.create_trade(
  p_friend_id uuid,
  p_my_cards int[],
  p_their_cards int[]
) returns public.trade_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_row public.trade_requests;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if me = p_friend_id then raise exception 'Je kan niet met jezelf ruilen.'; end if;
  if not exists (select 1 from public.friendships where user_id = me and friend_id = p_friend_id) then
    raise exception 'Jullie zijn geen vrienden.';
  end if;
  if coalesce(array_length(p_my_cards,1),0) = 0 and coalesce(array_length(p_their_cards,1),0) = 0 then
    raise exception 'Selecteer minstens één kaart.';
  end if;

  if exists (
    select 1 from (select unnest(coalesce(p_my_cards,'{}')) as card_id) x
    group by x.card_id
    having count(*) > (select count(*) from public.user_cards uc where uc.user_id = me and uc.card_id = x.card_id)
  ) then
    raise exception 'Je hebt niet genoeg exemplaren van de aangeboden kaart(en).';
  end if;

  if exists (
    select 1 from (select unnest(coalesce(p_their_cards,'{}')) as card_id) x
    group by x.card_id
    having count(*) > (select count(*) from public.user_cards uc where uc.user_id = p_friend_id and uc.card_id = x.card_id)
  ) then
    raise exception 'Je vriend heeft niet genoeg exemplaren van de gevraagde kaart(en).';
  end if;

  insert into public.trade_requests (proposer_id, recipient_id, proposer_cards, recipient_cards, status, turn, last_action_by)
  values (me, p_friend_id, coalesce(p_my_cards,'{}'), coalesce(p_their_cards,'{}'), 'pending', p_friend_id, me)
  returning * into v_row;

  return v_row;
end;
$$;

-- 5. respond_trade: accepteren / tegenbod doen / annuleren -----------------
create or replace function public.respond_trade(
  p_trade_id bigint,
  p_action text,
  p_proposer_cards int[] default null,
  p_recipient_cards int[] default null
) returns public.trade_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  t public.trade_requests;
  v_card int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;

  select * into t from public.trade_requests where id = p_trade_id for update;
  if not found then raise exception 'Ruilvoorstel niet gevonden.'; end if;
  if me <> t.proposer_id and me <> t.recipient_id then
    raise exception 'Dit is niet jouw ruilvoorstel.';
  end if;
  if t.status <> 'pending' then
    raise exception 'Dit ruilvoorstel is al afgehandeld.';
  end if;

  if p_action = 'cancel' then
    update public.trade_requests set status = 'cancelled', updated_at = now(), last_action_by = me
      where id = p_trade_id returning * into t;
    return t;
  end if;

  if me <> t.turn then
    raise exception 'Het is niet jouw beurt.';
  end if;

  if p_action = 'counter' then
    if exists (
      select 1 from (select unnest(coalesce(p_proposer_cards, t.proposer_cards)) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.proposer_id and uc.card_id = x.card_id)
    ) then
      raise exception 'De aanbieder heeft niet genoeg exemplaren van de aangeboden kaart(en).';
    end if;
    if exists (
      select 1 from (select unnest(coalesce(p_recipient_cards, t.recipient_cards)) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.recipient_id and uc.card_id = x.card_id)
    ) then
      raise exception 'De ontvanger heeft niet genoeg exemplaren van de gevraagde kaart(en).';
    end if;

    update public.trade_requests set
      proposer_cards = coalesce(p_proposer_cards, t.proposer_cards),
      recipient_cards = coalesce(p_recipient_cards, t.recipient_cards),
      turn = case when me = t.proposer_id then t.recipient_id else t.proposer_id end,
      last_action_by = me,
      updated_at = now()
    where id = p_trade_id
    returning * into t;
    return t;
  end if;

  if p_action = 'accept' then
    if exists (
      select 1 from (select unnest(t.proposer_cards) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.proposer_id and uc.card_id = x.card_id)
    ) then
      raise exception 'De aanbieder bezit de aangeboden kaart(en) niet meer.';
    end if;
    if exists (
      select 1 from (select unnest(t.recipient_cards) as card_id) x
      group by x.card_id
      having count(*) > (select count(*) from public.user_cards uc where uc.user_id = t.recipient_id and uc.card_id = x.card_id)
    ) then
      raise exception 'De ontvanger bezit de gevraagde kaart(en) niet meer.';
    end if;

    foreach v_card in array t.proposer_cards loop
      delete from public.user_cards where id = (
        select id from public.user_cards where user_id = t.proposer_id and card_id = v_card limit 1
      );
      insert into public.user_cards (user_id, card_id) values (t.recipient_id, v_card);
    end loop;

    foreach v_card in array t.recipient_cards loop
      delete from public.user_cards where id = (
        select id from public.user_cards where user_id = t.recipient_id and card_id = v_card limit 1
      );
      insert into public.user_cards (user_id, card_id) values (t.proposer_id, v_card);
    end loop;

    update public.trade_requests set status = 'accepted', updated_at = now(), last_action_by = me
      where id = p_trade_id returning * into t;
    return t;
  end if;

  raise exception 'Onbekende actie.';
end;
$$;

grant execute on function public.create_trade(uuid, int[], int[]) to authenticated;
grant execute on function public.respond_trade(bigint, text, int[], int[]) to authenticated;

-- Inruilen in The Vault uitschakelen
do $$ begin
  if to_regprocedure('public.vault_tradeup(integer[], text)') is not null then
    revoke execute on function public.vault_tradeup(int[], text) from authenticated;
  end if;
end $$;

-- =====================================================================
-- ADMIN-TEST-UPDATE (zelfde inhoud als update-17-admin-test.sql)
-- =====================================================================
-- 1. Oneindig geld -------------------------------------------------------------------------
create or replace function public._admin_wallet() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public._is_admin_user(new.user_id) then new.polycoins := 1000000; end if;
  return new;
end $$;
drop trigger if exists admin_wallet on public.user_wallet;
create trigger admin_wallet before insert or update on public.user_wallet
  for each row execute function public._admin_wallet();
update public.user_wallet set polycoins = 1000000 where public._is_admin_user(user_id);

-- 2. Spel kiezen om te testen --------------------------------------------------------------
create table if not exists public.admin_exam_choice (
  user_id uuid primary key references auth.users(id) on delete cascade,
  game text not null
);
alter table public.admin_exam_choice enable row level security; -- geen policies: enkel via de functies

-- Het spel van de dag; voor een admin met een gekozen testspel is dat het gekozen spel
create or replace function public._exam_game(p_date date) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select a.game from public.admin_exam_choice a where a.user_id = auth.uid() and public._is_admin_user(a.user_id)),
    (array['wordle', 'math', 'hoops', 'history', 'launch', 'darts', 'blackjack'])[extract(isodow from p_date)::int]);
$$;

-- Admin: kies een spel en begin opnieuw (het examen van vandaag wordt gewist)
create or replace function public.admin_exam_test(p_game text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare d date := (now() at time zone 'Europe/Brussels')::date;
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor admins.'; end if;
  if p_game is null then
    delete from public.admin_exam_choice where user_id = auth.uid();
  else
    if p_game not in ('wordle', 'math', 'hoops', 'history', 'launch', 'darts', 'blackjack') then raise exception 'Onbekend spel.'; end if;
    insert into public.admin_exam_choice (user_id, game) values (auth.uid(), p_game)
      on conflict (user_id) do update set game = excluded.game;
  end if;
  delete from public.exam_results where user_id = auth.uid() and exam_date = d;
  delete from public.wordle_games where user_id = auth.uid() and round_date = d;
end $$;
grant execute on function public.admin_exam_test(text) to authenticated;

-- Supabase de nieuwe functies meteen laten zien
notify pgrst, 'reload schema';

-- =====================================================================
-- TESTLOGBOEK-UPDATE (zelfde inhoud als update-18-testlogboek.sql)
-- =====================================================================
-- 1. Testlogboek ---------------------------------------------------------------------------
create table if not exists public.admin_play_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  game text not null,
  score int,
  grade text,
  seconds int,
  created_at timestamptz not null default now()
);
alter table public.admin_play_log enable row level security; -- enkel leesbaar in de SQL Editor

create or replace function public._log_admin_play() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'done' and (tg_op = 'INSERT' or old.status is distinct from 'done') and public._is_admin_user(new.user_id) then
    insert into public.admin_play_log (user_id, game, score, grade, seconds)
    values (new.user_id, new.game, new.score, new.grade, extract(epoch from (coalesce(new.finished_at, now()) - new.started_at))::int);
  end if;
  return new;
end $$;
drop trigger if exists log_admin_play on public.exam_results;
create trigger log_admin_play after insert or update on public.exam_results
  for each row execute function public._log_admin_play();

-- 2. Rooster: zaterdag Beer Pong ---------------------------------------------------------------
create or replace function public._exam_game(p_date date) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select a.game from public.admin_exam_choice a where a.user_id = auth.uid() and public._is_admin_user(a.user_id)),
    (array['wordle', 'math', 'hoops', 'history', 'launch', 'pong', 'blackjack'])[extract(isodow from p_date)::int]);
$$;

create or replace function public.admin_exam_test(p_game text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare d date := (now() at time zone 'Europe/Brussels')::date;
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor admins.'; end if;
  if p_game is null then
    delete from public.admin_exam_choice where user_id = auth.uid();
  else
    if p_game not in ('wordle', 'math', 'hoops', 'history', 'launch', 'pong', 'darts', 'blackjack') then raise exception 'Onbekend spel.'; end if;
    insert into public.admin_exam_choice (user_id, game) values (auth.uid(), p_game)
      on conflict (user_id) do update set game = excluded.game;
  end if;
  delete from public.exam_results where user_id = auth.uid() and exam_date = d;
  delete from public.wordle_games where user_id = auth.uid() and round_date = d;
end $$;
grant execute on function public.admin_exam_test(text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- SPELLETJES-BIJGESTELD-UPDATE (zelfde inhoud als update-19-spelletjes-bijgesteld.sql)
-- =====================================================================
-- Grenzen per spel: [laagste score, hoogste score, minimum aantal seconden, A, B, C, D]
create or replace function public._exam_rules(p_game text) returns int[]
language sql immutable as $$
  select case p_game
    when 'math'      then array[0, 80, 55, 20, 15, 11, 7]      -- juiste sommen in 60 seconden
    when 'hoops'     then array[0, 10, 8, 8, 6, 4, 2]          -- raak uit 10 worpen
    when 'history'   then array[0, 10, 12, 9, 8, 6, 4]         -- juist uit 10 vragen
    when 'launch'    then array[0, 8, 8, 7, 5, 4, 2]           -- raak uit 8 schoten
    when 'darts'     then array[0, 360, 6, 190, 150, 110, 70]  -- (niet meer op het rooster)
    when 'blackjack' then array[0, 400, 6, 160, 125, 100, 70]  -- chips na 10 handen (start 100)
    when 'pong'      then array[0, 6, 6, 6, 5, 4, 2]           -- bekers met 10 ballen
    when 'pour'      then array[0, 500, 8, 440, 380, 300, 200]
  end;
$$;

-- =====================================================================
-- PINTJE-UPDATE (zelfde inhoud als update-20-pintje.sql)
-- =====================================================================
create table if not exists public.beer_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pints int not null default 0,
  total int not null default 0,
  drunk_until timestamptz
);
alter table public.beer_state enable row level security;
drop policy if exists "eigen pintjes lezen" on public.beer_state;
create policy "eigen pintjes lezen" on public.beer_state for select to authenticated using (auth.uid() = user_id);

create or replace function public.buy_beer() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_coins int; b public.beer_state;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select polycoins into v_coins from public.user_wallet where user_id = me for update;
  if coalesce(v_coins, 0) < 1 then raise exception 'Niet genoeg credits voor een pintje.'; end if;
  insert into public.beer_state (user_id) values (me) on conflict do nothing;
  select * into b from public.beer_state where user_id = me for update;
  if b.drunk_until > now() then raise exception 'Je bent al zat. Even wachten met het volgende pintje.'; end if;
  update public.user_wallet set polycoins = polycoins - 1 where user_id = me returning polycoins into v_coins;
  b.pints := b.pints + 1; b.total := b.total + 1;
  if b.pints >= 5 then b.pints := 0; b.drunk_until := now() + interval '1 minute'; end if;
  update public.beer_state set pints = b.pints, total = b.total, drunk_until = b.drunk_until where user_id = me;
  return jsonb_build_object('pints', b.pints, 'total', b.total, 'drunk_until', b.drunk_until,
    'drunk_ms', greatest(0, extract(epoch from (b.drunk_until - now())) * 1000)::int, 'wallet', v_coins);
end $$;
grant execute on function public.buy_beer() to authenticated;
notify pgrst, 'reload schema';

-- =====================================================================
-- PINTJE-RANDOM-UPDATE (zelfde inhoud als update-21-pintje-random.sql)
-- =====================================================================
alter table public.beer_state add column if not exists limit_n int;

-- De teller niet meer zelf kunnen lezen (anders weet je wanneer je zat wordt)
drop policy if exists "eigen pintjes lezen" on public.beer_state;

create or replace function public.buy_beer() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_coins int; b public.beer_state;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select polycoins into v_coins from public.user_wallet where user_id = me for update;
  if coalesce(v_coins, 0) < 1 then raise exception 'Niet genoeg credits voor een pintje.'; end if;
  insert into public.beer_state (user_id) values (me) on conflict do nothing;
  select * into b from public.beer_state where user_id = me for update;
  if b.drunk_until > now() then raise exception 'Je bent al sterrezat. Even wachten met het volgende pintje.'; end if;
  update public.user_wallet set polycoins = polycoins - 1 where user_id = me returning polycoins into v_coins;
  if b.limit_n is null then b.limit_n := 1 + floor(random() * 5)::int; end if;
  b.pints := b.pints + 1; b.total := b.total + 1;
  if b.pints >= b.limit_n then
    b.pints := 0; b.limit_n := 1 + floor(random() * 5)::int; b.drunk_until := now() + interval '1 minute';
  end if;
  update public.beer_state set pints = b.pints, total = b.total, limit_n = b.limit_n, drunk_until = b.drunk_until where user_id = me;
  return jsonb_build_object('total', b.total,
    'drunk_ms', greatest(0, extract(epoch from (b.drunk_until - now())) * 1000)::int, 'wallet', v_coins);
end $$;
grant execute on function public.buy_beer() to authenticated;
notify pgrst, 'reload schema';

-- =====================================================================
-- BLACKJACK-SPLIT-UPDATE (zelfde inhoud als update-22-blackjack-split.sql)
-- =====================================================================
-- Tweede hand bij een split
alter table public.casino_bj add column if not exists hand2 int[];
alter table public.casino_bj add column if not exists bet2 int;
alter table public.casino_bj add column if not exists active int not null default 1;

-- Waarde van één kaart (aas = 11, boer/dame/heer = 10)
create or replace function public._bj_card(p_card int) returns int
language sql immutable as $$
  select case when p_card % 13 = 0 then 11 when p_card % 13 >= 9 then 10 else p_card % 13 + 1 end;
$$;

-- Wat de speler mag zien (de verborgen kaart van de dealer enkel na afloop)
create or replace function public._bj_view(h public.casino_bj, p_done boolean) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'bet', h.bet + coalesce(h.bet2, 0), 'bet1', h.bet, 'bet2', h.bet2,
    'player', to_jsonb(h.player), 'player_total', public._bj_value(h.player),
    'player2', to_jsonb(h.hand2), 'player2_total', case when h.hand2 is null then null else public._bj_value(h.hand2) end,
    'active', h.active,
    'dealer', case when p_done then to_jsonb(h.dealer) else to_jsonb(array[h.dealer[1]]) end,
    'dealer_total', case when p_done then public._bj_value(h.dealer) else public._bj_value(array[h.dealer[1]]) end,
    'can_double', not p_done and array_length(case when h.active = 2 then h.hand2 else h.player end, 1) = 2,
    'can_split', not p_done and h.hand2 is null and array_length(h.player, 1) = 2
                 and public._bj_card(h.player[1]) = public._bj_card(h.player[2]),
    'done', p_done);
$$;

-- Uitkomst van één hand
create or replace function public._bj_outcome(p_cards int[], p_dealer int[], p_split boolean) returns text
language plpgsql immutable as $$
declare pt int := public._bj_value(p_cards); dt int := public._bj_value(p_dealer);
begin
  if pt > 21 then return 'bust'; end if;
  if pt = 21 and array_length(p_cards, 1) = 2 and not p_split
     and not (dt = 21 and array_length(p_dealer, 1) = 2) then return 'blackjack'; end if;
  if dt > 21 or pt > dt then return 'win'; end if;
  if pt = dt then return 'push'; end if;
  return 'lose';
end $$;

create or replace function public._bj_payout(p_outcome text, p_bet int) returns int
language sql immutable as $$
  select case p_outcome when 'blackjack' then floor(p_bet * 2.5)::int when 'win' then p_bet * 2 when 'push' then p_bet else 0 end;
$$;

-- Hand afronden: dealer speelt, uitbetalen, hand weg
create or replace function public._bj_finish(h public.casino_bj, p_dealer_plays boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare o1 text; o2 text; pay int; split boolean := h.hand2 is not null;
begin
  if p_dealer_plays and (public._bj_value(h.player) <= 21 or (split and public._bj_value(h.hand2) <= 21)) then
    while public._bj_value(h.dealer) < 17 loop
      h.dealer := h.dealer || h.deck[1]; h.deck := h.deck[2:];
    end loop;
  end if;
  o1 := public._bj_outcome(h.player, h.dealer, split);
  pay := public._bj_payout(o1, h.bet);
  if split then
    o2 := public._bj_outcome(h.hand2, h.dealer, true);
    pay := pay + public._bj_payout(o2, h.bet2);
  end if;
  delete from public.casino_bj where user_id = h.user_id;
  return public._casino_pay('blackjack', h.bet + coalesce(h.bet2, 0), pay,
    public._bj_view(h, true) || jsonb_build_object('outcome', o1, 'outcome2', o2));
end $$;
revoke all on function public._bj_finish(public.casino_bj, boolean) from public, anon, authenticated;

-- Naar de volgende hand, of de dealer laten spelen
create or replace function public._bj_next(h public.casino_bj) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if h.active = 1 and h.hand2 is not null then
    h.active := 2;
    update public.casino_bj set active = 2 where user_id = h.user_id;
    if public._bj_value(h.hand2) >= 21 then return public._bj_finish(h, true); end if;
    return public._bj_view(h, false);
  end if;
  return public._bj_finish(h, true);
end $$;
revoke all on function public._bj_next(public.casino_bj) from public, anon, authenticated;

create or replace function public.casino_bj_action(p_action text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h public.casino_bj; cur int[];
begin
  select * into h from public.casino_bj where user_id = auth.uid() for update;
  if not found then raise exception 'Er loopt geen hand.'; end if;
  cur := case when h.active = 2 then h.hand2 else h.player end;

  if p_action = 'hit' then
    cur := cur || h.deck[1]; h.deck := h.deck[2:];
    if h.active = 2 then h.hand2 := cur; else h.player := cur; end if;
    update public.casino_bj set player = h.player, hand2 = h.hand2, deck = h.deck where user_id = h.user_id;
    if public._bj_value(cur) >= 21 then return public._bj_next(h); end if;
    return public._bj_view(h, false);

  elsif p_action = 'stand' then
    return public._bj_next(h);

  elsif p_action = 'double' then
    if array_length(cur, 1) <> 2 then raise exception 'Verdubbelen kan enkel met je eerste twee kaarten.'; end if;
    if h.active = 2 then
      perform public._casino_take(h.bet2); h.bet2 := h.bet2 * 2;
      h.hand2 := h.hand2 || h.deck[1];
    else
      perform public._casino_take(h.bet); h.bet := h.bet * 2;
      h.player := h.player || h.deck[1];
    end if;
    h.deck := h.deck[2:];
    update public.casino_bj set bet = h.bet, bet2 = h.bet2, player = h.player, hand2 = h.hand2, deck = h.deck where user_id = h.user_id;
    return public._bj_next(h);

  elsif p_action = 'split' then
    if h.hand2 is not null or array_length(h.player, 1) <> 2
       or public._bj_card(h.player[1]) <> public._bj_card(h.player[2]) then
      raise exception 'Splitsen kan enkel met twee kaarten van dezelfde waarde.';
    end if;
    perform public._casino_take(h.bet);
    h.bet2 := h.bet;
    h.hand2 := array[h.player[2], h.deck[2]];
    h.player := array[h.player[1], h.deck[1]];
    h.deck := h.deck[3:];
    h.active := 1;
    update public.casino_bj set bet2 = h.bet2, player = h.player, hand2 = h.hand2, deck = h.deck, active = 1 where user_id = h.user_id;
    if h.player[1] % 13 = 0 then return public._bj_finish(h, true); end if; -- twee azen: elk één kaart
    if public._bj_value(h.player) = 21 then return public._bj_next(h); end if;
    return public._bj_view(h, false);
  end if;
  raise exception 'Onbekende actie.';
end $$;
grant execute on function public.casino_bj_action(text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- SPLIT-AZEN-UPDATE (zelfde inhoud als update-23-split-azen.sql)
-- =====================================================================
create or replace function public.casino_bj_action(p_action text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h public.casino_bj; cur int[];
begin
  select * into h from public.casino_bj where user_id = auth.uid() for update;
  if not found then raise exception 'Er loopt geen hand.'; end if;
  cur := case when h.active = 2 then h.hand2 else h.player end;

  if p_action = 'hit' then
    cur := cur || h.deck[1]; h.deck := h.deck[2:];
    if h.active = 2 then h.hand2 := cur; else h.player := cur; end if;
    update public.casino_bj set player = h.player, hand2 = h.hand2, deck = h.deck where user_id = h.user_id;
    if public._bj_value(cur) >= 21 then return public._bj_next(h); end if;
    return public._bj_view(h, false);

  elsif p_action = 'stand' then
    return public._bj_next(h);

  elsif p_action = 'double' then
    if array_length(cur, 1) <> 2 then raise exception 'Verdubbelen kan enkel met je eerste twee kaarten.'; end if;
    if h.active = 2 then
      perform public._casino_take(h.bet2); h.bet2 := h.bet2 * 2;
      h.hand2 := h.hand2 || h.deck[1];
    else
      perform public._casino_take(h.bet); h.bet := h.bet * 2;
      h.player := h.player || h.deck[1];
    end if;
    h.deck := h.deck[2:];
    update public.casino_bj set bet = h.bet, bet2 = h.bet2, player = h.player, hand2 = h.hand2, deck = h.deck where user_id = h.user_id;
    return public._bj_next(h);

  elsif p_action = 'split' then
    if h.hand2 is not null or array_length(h.player, 1) <> 2
       or public._bj_card(h.player[1]) <> public._bj_card(h.player[2]) then
      raise exception 'Splitsen kan enkel met twee kaarten van dezelfde waarde.';
    end if;
    perform public._casino_take(h.bet);
    h.bet2 := h.bet;
    h.hand2 := array[h.player[2], h.deck[2]];
    h.player := array[h.player[1], h.deck[1]];
    h.deck := h.deck[3:];
    h.active := 1;
    update public.casino_bj set bet2 = h.bet2, player = h.player, hand2 = h.hand2, deck = h.deck, active = 1 where user_id = h.user_id;
    if public._bj_value(h.player) = 21 then return public._bj_next(h); end if;
    return public._bj_view(h, false);
  end if;
  raise exception 'Onbekende actie.';
end $$;
grant execute on function public.casino_bj_action(text) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- OPGEVEN-UPDATE (zelfde inhoud als update-24-opgeven.sql)
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

-- =====================================================================
-- FOODTRUCK-UPDATE (zelfde inhoud als update-25-foodtruck.sql)
-- =====================================================================

create table if not exists public.feature_flags (
  key text primary key,
  released boolean not null default false,
  note text
);
alter table public.feature_flags enable row level security; -- enkel via feature_list()
insert into public.feature_flags (key, note) values
  ('foodmenu', 'Food Truck: shotje, Red Bull, kapsalon, Rizz-poeder'),
  ('sportsbook', 'Casino: inzetten op voetbal'),
  ('secrets', 'Geheime trofeeën'),
  ('sound', 'Muziek en geluidseffecten'),
  ('smallbets', 'Casino: inzetten van 1 en 2 credits')
on conflict (key) do nothing;

create or replace function public._feature_on(p_key text, p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select released from public.feature_flags where key = p_key), true)
      or coalesce(public._is_admin_user(p_user), false);
$$;
revoke all on function public._feature_on(text, uuid) from public, anon, authenticated;

-- Welke nieuwe dingen staan aan voor mij? {"sportsbook": true, ...}
create or replace function public.feature_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(key, public._feature_on(key)), '{}'::jsonb) from public.feature_flags;
$$;
grant execute on function public.feature_list() to authenticated;

create table if not exists public.food_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  item text not null,            -- pintje, shotje, redbull, kapsalon, poeder, of 'zat' (werd sterrezat)
  card_id int references public.cards(id) on delete set null,   -- gevonden kaart (Rizz-poeder)
  created_at timestamptz not null default now()
);
create index if not exists food_log_user_idx on public.food_log (user_id, created_at);
alter table public.food_log enable row level security;
drop policy if exists "eigen food log lezen" on public.food_log;
create policy "eigen food log lezen" on public.food_log for select to authenticated using (auth.uid() = user_id);

create or replace function public.buy_food(p_item text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid(); v_coins int; b public.beer_state;
  price int; points int := 0; v_find int; v_rarity text; r float8;
  became_drunk boolean := false; sober boolean := false;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  price := case p_item when 'pintje' then 1 when 'shotje' then 2 when 'redbull' then 2 when 'kapsalon' then 4 when 'poeder' then 8 end;
  if price is null or (p_item <> 'pintje' and not public._feature_on('foodmenu')) then raise exception 'Dat staat niet op de kaart.'; end if;

  select polycoins into v_coins from public.user_wallet where user_id = me for update;
  if coalesce(v_coins, 0) < price then raise exception 'Niet genoeg credits.'; end if;
  insert into public.beer_state (user_id) values (me) on conflict do nothing;
  select * into b from public.beer_state where user_id = me for update;

  if p_item in ('pintje', 'shotje') and b.drunk_until > now() then
    raise exception 'Je bent al sterrezat. Even wachten, of eet een kapsalon.';
  end if;
  if p_item = 'poeder' and (select count(*) from public.food_log where user_id = me and item = 'poeder'
        and (created_at at time zone 'Europe/Brussels')::date = (now() at time zone 'Europe/Brussels')::date) >= 3 then
    raise exception 'Genoeg Rizz-poeder voor vandaag. Morgen terug.';
  end if;

  update public.user_wallet set polycoins = polycoins - price where user_id = me returning polycoins into v_coins;

  if p_item in ('pintje', 'shotje') then
    points := case p_item when 'shotje' then 2 else 1 end;
    if b.limit_n is null then b.limit_n := 1 + floor(random() * 5)::int; end if;
    b.pints := b.pints + points;
    if p_item = 'pintje' then b.total := b.total + 1; end if;
    if b.pints >= b.limit_n then
      b.pints := 0; b.limit_n := 1 + floor(random() * 5)::int; b.drunk_until := now() + interval '1 minute';
      became_drunk := true;
    end if;
  elsif p_item = 'kapsalon' then
    sober := b.drunk_until > now() or b.pints > 0;
    b.pints := 0; b.drunk_until := null; b.limit_n := 1 + floor(random() * 5)::int;
  elsif p_item = 'poeder' and random() < 0.125 then
    r := random();
    v_rarity := case when r < 0.05 then 'legendary' when r < 0.30 then 'epic' else 'common' end;
    select id into v_find from public.cards where rarity = v_rarity order by random() limit 1;
    if v_find is not null then insert into public.user_cards (user_id, card_id) values (me, v_find); end if;
  end if;

  update public.beer_state set pints = b.pints, total = b.total, limit_n = b.limit_n, drunk_until = b.drunk_until where user_id = me;
  insert into public.food_log (user_id, item, card_id) values (me, p_item, v_find);
  if became_drunk then insert into public.food_log (user_id, item) values (me, 'zat'); end if;

  return jsonb_build_object('item', p_item, 'wallet', v_coins, 'total', b.total, 'sober', sober,
    'drunk_ms', case when b.drunk_until > now() then (extract(epoch from (b.drunk_until - now())) * 1000)::int else 0 end,
    'find', v_find);
end $$;
grant execute on function public.buy_food(text) to authenticated;

-- Het oude pintje gaat voortaan via dezelfde kaart
create or replace function public.buy_beer() returns jsonb
language sql volatile security definer set search_path = public as $$ select public.buy_food('pintje') $$;
grant execute on function public.buy_beer() to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- INZET-UPDATE (zelfde inhoud als update-28-inzet.sql)
-- =====================================================================

create or replace function public._casino_take(p_bet int) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_coins int;
begin
  if auth.uid() is null then raise exception 'Niet ingelogd.'; end if;
  if p_bet is null or p_bet < 1 or p_bet > 50 or (p_bet > 2 and p_bet % 5 <> 0)
     or (p_bet < 5 and not public._feature_on('smallbets')) then
    raise exception '%', case when public._feature_on('smallbets') then 'Inzet: 1, 2, of 5 tot 50 credits per 5.' else 'Inzet: 5 tot 50 credits, per 5.' end;
  end if;
  select polycoins into v_coins from public.user_wallet where user_id = auth.uid() for update;
  if coalesce(v_coins, 0) < p_bet then raise exception 'Niet genoeg credits.'; end if;
  update public.user_wallet set polycoins = polycoins - p_bet where user_id = auth.uid();
end $$;
revoke all on function public._casino_take(int) from public, anon, authenticated;

-- Uitbetaling afronden: vanaf 5 credits naar beneden, bij 1 of 2 credits eerlijk (kans = het stukje na de komma)
create or replace function public._casino_round(p_bet int, p_amount numeric) returns int
language sql volatile as $$
  select case when p_bet >= 5 then floor(p_amount)::int else floor(p_amount + random())::int end;
$$;
revoke all on function public._casino_round(int, numeric) from public, anon, authenticated;

create or replace function public.casino_slots(p_bet int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a text; b text; c text; n int; mult numeric := 0;
begin
  perform public._casino_take(p_bet);
  a := public._casino_reel(); b := public._casino_reel(); c := public._casino_reel();
  n := (a = 'C')::int + (b = 'C')::int + (c = 'C')::int;
  if a = b and b = c then
    mult := case a when 'R' then 60 when 'K' then 25 when 'D' then 15 when 'B' then 10 when 'L' then 6 else 5 end;
  elsif n = 2 then mult := 2;
  elsif n = 1 then mult := 0.4;
  end if;
  return public._casino_pay('slots', p_bet, public._casino_round(p_bet, p_bet * mult), jsonb_build_object('reels', jsonb_build_array(a, b, c), 'mult', mult));
end $$;
grant execute on function public.casino_slots(int) to authenticated;

create or replace function public.casino_horses(p_bet int, p_horse int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r int; acc int := 0; h jsonb; winner int; mult numeric := 0; others int[];
begin
  if p_horse not between 1 and 5 then raise exception 'Kies een paard van 1 tot 5.'; end if;
  perform public._casino_take(p_bet);
  r := floor(random() * 100)::int;
  for h in select * from jsonb_array_elements(public.casino_horses_odds()) loop
    acc := acc + (h->>'p')::int;
    if winner is null and r < acc then winner := (h->>'n')::int; if winner = p_horse then mult := (h->>'x')::numeric; end if; end if;
  end loop;
  select array_agg(x order by random()) into others from generate_series(1, 5) x where x <> winner;
  return public._casino_pay('horses', p_bet, public._casino_round(p_bet, p_bet * mult),
    jsonb_build_object('winner', winner, 'order', to_jsonb(array[winner] || others), 'pick', p_horse, 'mult', mult));
end $$;
grant execute on function public.casino_horses(int, int) to authenticated;

-- Blackjack: 3 tegen 2 (2,5× terug) bij 1 credit = 2 of 3, eerlijk afgerond
create or replace function public._bj_payout(p_outcome text, p_bet int) returns int
language sql volatile as $$
  select case p_outcome when 'blackjack' then public._casino_round(p_bet, p_bet * 2.5) when 'win' then p_bet * 2 when 'push' then p_bet else 0 end;
$$;

notify pgrst, 'reload schema';

-- =====================================================================
-- VOETBAL-UPDATE (zelfde inhoud als update-26-voetbal.sql)
-- =====================================================================

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
-- Quoteringen van de bookmakers (the-odds-api.com) of van de admin
alter table public.fb_matches add column if not exists odds_1 numeric(6, 2);
alter table public.fb_matches add column if not exists odds_x numeric(6, 2);
alter table public.fb_matches add column if not exists odds_2 numeric(6, 2);
alter table public.fb_matches add column if not exists odds_books int;          -- aantal bookmakers (0 = door de admin)
alter table public.fb_matches add column if not exists odds_at timestamptz;
alter table public.fb_matches add column if not exists odds_id text unique;     -- id bij the-odds-api.com
alter table public.fb_matches add column if not exists home_alt text;           -- volledige ploegnaam (om te koppelen)
alter table public.fb_matches add column if not exists away_alt text;
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
alter table public.fb_config add column if not exists last_odds timestamptz;
alter table public.fb_config add column if not exists last_scores timestamptz;
alter table public.fb_config add column if not exists odds_msg text;
alter table public.fb_config enable row level security; -- enkel de server
insert into public.fb_config (id) values (1) on conflict do nothing;

-- 2. Quoteringen --------------------------------------------------------------------------------------
-- De quotering komt van de bookmakers (of de admin). De stemmen tonen enkel wat de groep denkt.
create or replace function public._fb_odds(p_match bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    '1', m.odds_1, 'X', m.odds_x, '2', m.odds_2, 'books', m.odds_books, 'at', m.odds_at,
    'votes', (select jsonb_build_object('1', count(*) filter (where pick = '1'), 'X', count(*) filter (where pick = 'X'),
                                        '2', count(*) filter (where pick = '2'))
              from public.fb_votes where match_id = p_match))
  from public.fb_matches m where m.id = p_match;
$$;
revoke all on function public._fb_odds(bigint) from public, anon, authenticated;

-- Ploegnamen vergelijken: "Man United" = "Manchester United FC", "Barça" = "FC Barcelona", "België" = "Belgium", ...
-- Een wedstrijd wordt enkel gekoppeld als BEIDE ploegen overeenkomen (en de competitie en het uur).
create or replace function public._fb_words(p_name text) returns text[]
language sql immutable as $$
  select coalesce(array_agg(coalesce(nl.en, w)), '{}') from regexp_split_to_table(
    regexp_replace(lower(translate(coalesce(p_name, ''), 'áàâäãåçéèêëíìîïñóòôöõøúùûüýÁÀÂÄÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕØÚÙÛÜÝ',
                                                           'aaaaaaceeeeiiiinoooooouuuuyaaaaaaceeeeiiiinoooooouuuuy')),
                   '[^a-z0-9]+', ' ', 'g'), ' ') w
  -- Nederlandse landnamen (Nations League) -> Engels, zoals bij de bookmakers
  left join (values ('belgie', 'belgium'), ('frankrijk', 'france'), ('duitsland', 'germany'), ('nederland', 'netherlands'),
    ('engeland', 'england'), ('spanje', 'spain'), ('italie', 'italy'), ('zwitserland', 'switzerland'), ('oostenrijk', 'austria'),
    ('denemarken', 'denmark'), ('zweden', 'sweden'), ('noorwegen', 'norway'), ('kroatie', 'croatia'), ('polen', 'poland'),
    ('turkije', 'turkey'), ('schotland', 'scotland'), ('griekenland', 'greece'), ('hongarije', 'hungary'), ('tsjechie', 'czech'),
    ('ierland', 'ireland'), ('oekraine', 'ukraine'), ('servie', 'serbia'), ('roemenie', 'romania'), ('slovenie', 'slovenia'),
    ('slowakije', 'slovakia'), ('ijsland', 'iceland'), ('georgie', 'georgia'), ('noord', 'northern'), ('bosnie', 'bosnia'),
    ('wit', 'belarus')) nl(nl, en) on nl.nl = w
  where length(w) >= 3 and w not in ('the', 'and', 'club', 'united', 'city', 'real', 'sporting', 'athletic', 'atletico',
    'olympique', 'stade', 'calcio', 'football', 'futbol', 'town', 'hotspur', 'albion', 'wanderers', 'rovers', 'county',
    'royal', 'koninklijke', 'racing', 'saint', 'sint', 'afc', 'cfc', 'ssc', 'rsc', 'krc', 'kaa', 'kvc', 'rcd', 'vfl', 'vfb', 'tsg',
    'bsc', 'deportivo');
$$;

create or replace function public._fb_same_team(p_a text, p_a2 text, p_b text) returns boolean
language sql immutable as $$
  select exists (
    select 1 from unnest(public._fb_words(p_a) || public._fb_words(p_a2)) x, unnest(public._fb_words(p_b)) y
    where x = y or x like y || '%' or y like x || '%' or (length(x) >= 5 and length(y) >= 5 and left(x, 4) = left(y, 4)));
$$;

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
    elsif bt.pick = res then pay := public._casino_round(bt.stake, bt.stake * bt.odds);
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
  select case when auth.uid() is null or not public._feature_on('sportsbook') then null else jsonb_build_object(
    'is_admin', public._is_admin_user(auth.uid()),
    'last_sync', (select last_sync from public.fb_config where id = 1),
    'last_odds', (select last_odds from public.fb_config where id = 1),
    'odds_msg', (select odds_msg from public.fb_config where id = 1),
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
  if not public._feature_on('sportsbook') then raise exception 'Het Sportsbook is nog niet open.'; end if;
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
  if not public._feature_on('sportsbook') then raise exception 'Het Sportsbook is nog niet open.'; end if;
  if p_pick not in ('1', 'X', '2') then raise exception 'Kies 1, X of 2.'; end if;
  select * into m from public.fb_matches where id = p_match for update;
  if not found then raise exception 'Wedstrijd niet gevonden.'; end if;
  if m.kickoff <= now() or m.status <> 'scheduled' then raise exception 'Inzetten kan enkel tot aan de aftrap.'; end if;
  if exists (select 1 from public.fb_bets where match_id = p_match and user_id = auth.uid()) then
    raise exception 'Je hebt al ingezet op deze wedstrijd.';
  end if;
  o := case p_pick when '1' then m.odds_1 when 'X' then m.odds_x else m.odds_2 end;
  if o is null then raise exception 'Er is nog geen quotering voor deze wedstrijd.'; end if;
  perform public._casino_take(p_stake);
  -- je stem volgt je inzet
  insert into public.fb_votes (match_id, user_id, pick) values (p_match, auth.uid(), p_pick)
  on conflict (match_id, user_id) do update set pick = excluded.pick;
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

-- Quotering zelf invullen (bv. als de bookmakers een wedstrijd niet hebben)
create or replace function public.fb_admin_odds(p_match bigint, p_1 numeric, p_x numeric, p_2 numeric) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  if least(p_1, p_x, p_2) < 1.01 or greatest(p_1, p_x, p_2) > 50 or p_1 is null or p_x is null or p_2 is null then
    raise exception 'Quoteringen: tussen 1,01 en 50.';
  end if;
  update public.fb_matches set odds_1 = round(p_1, 2), odds_x = round(p_x, 2), odds_2 = round(p_2, 2), odds_books = 0, odds_at = now()
  where id = p_match and status = 'scheduled' and kickoff > now();
  if not found then raise exception 'Kan niet meer: de wedstrijd is al begonnen.'; end if;
end $$;
grant execute on function public.fb_admin_odds(bigint, numeric, numeric, numeric) to authenticated;

-- 7. Binnenkomende wedstrijden van de functie rizz-voetbal (enkel de server) ---------------------------
-- p_matches: [{ext_id, competition, home, away, kickoff, status, home_goals, away_goals}]
create or replace function public.fb_sync(p_matches jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x jsonb; v_id bigint; n int := 0; s int := 0;
begin
  for x in select * from jsonb_array_elements(p_matches) loop
    insert into public.fb_matches (ext_id, competition, home, away, home_alt, away_alt, kickoff, status, home_goals, away_goals)
    values ((x->>'ext_id')::bigint, x->>'competition', x->>'home', x->>'away', x->>'home_alt', x->>'away_alt', (x->>'kickoff')::timestamptz,
            x->>'status', (x->>'home_goals')::int, (x->>'away_goals')::int)
    on conflict (ext_id) do update set
      home = excluded.home, away = excluded.away, home_alt = excluded.home_alt, away_alt = excluded.away_alt, kickoff = excluded.kickoff,
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

-- Quoteringen van the-odds-api.com (enkel de server)
-- p_events: [{odds_id, competition, home, away, kickoff, o1, ox, o2, books}]
-- Elke wedstrijd wordt gekoppeld op competitie + aftrap (max. 3 uur verschil) + beide ploegnamen.
-- Pro League en Nations League: niet gevonden = nieuwe wedstrijd.
create or replace function public.fb_sync_odds(p_events jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x jsonb; v_id bigint; k timestamptz; n int := 0; nnew int := 0; nmiss int := 0;
begin
  for x in select * from jsonb_array_elements(p_events) loop
    k := (x->>'kickoff')::timestamptz;
    if k <= now() then continue; end if;
    select id into v_id from public.fb_matches where odds_id = x->>'odds_id';
    if v_id is null then
      select m.id into v_id from public.fb_matches m
      where m.competition = x->>'competition' and m.status = 'scheduled' and not m.settled
        and abs(extract(epoch from m.kickoff - k)) <= 3 * 3600
        and (m.odds_id is null or m.odds_id = x->>'odds_id')
        and public._fb_same_team(m.home, m.home_alt, x->>'home') and public._fb_same_team(m.away, m.away_alt, x->>'away')
      order by abs(extract(epoch from m.kickoff - k)) limit 1;
    end if;
    if v_id is null and x->>'competition' in ('BPL', 'UNL') then
      insert into public.fb_matches (competition, home, away, kickoff, odds_id)
      values (x->>'competition', x->>'home', x->>'away', k, x->>'odds_id') returning id into v_id;
      nnew := nnew + 1; n := n - 1;
    end if;
    if v_id is null then nmiss := nmiss + 1; continue; end if;
    update public.fb_matches set odds_id = x->>'odds_id',
      kickoff = case when ext_id is null then k else kickoff end,
      odds_1 = least(50, greatest(1.01, round((x->>'o1')::numeric, 2))),
      odds_x = least(50, greatest(1.01, round((x->>'ox')::numeric, 2))),
      odds_2 = least(50, greatest(1.01, round((x->>'o2')::numeric, 2))),
      odds_books = (x->>'books')::int, odds_at = now()
    where id = v_id and status = 'scheduled' and kickoff > now() and coalesce(odds_books, 1) <> 0; -- de admin heeft voorrang
    n := n + 1;
    v_id := null;
  end loop;
  update public.fb_config set last_odds = now(), odds_msg = format('%s gekoppeld, %s nieuw, %s niet gevonden', n, nnew, nmiss) where id = 1;
  return jsonb_build_object('linked', n, 'new', nnew, 'missing', nmiss);
end $$;
revoke all on function public.fb_sync_odds(jsonb) from public, anon, authenticated;
grant execute on function public.fb_sync_odds(jsonb) to service_role;

-- Uitslagen van the-odds-api.com, voor wedstrijden die niet uit football-data.org komen (Pro League, Nations League)
-- p_scores: [{odds_id, home_goals, away_goals}]
create or replace function public.fb_sync_scores(p_scores jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x jsonb; v_id bigint; n int := 0;
begin
  for x in select * from jsonb_array_elements(p_scores) loop
    update public.fb_matches set status = 'finished', home_goals = (x->>'home_goals')::int, away_goals = (x->>'away_goals')::int
    where odds_id = x->>'odds_id' and ext_id is null and not settled and kickoff <= now()
    returning id into v_id;
    if v_id is not null then perform public._fb_settle(v_id); n := n + 1; v_id := null; end if;
  end loop;
  update public.fb_config set last_scores = now() where id = 1;
  return jsonb_build_object('finished', n);
end $$;
revoke all on function public.fb_sync_scores(jsonb) from public, anon, authenticated;
grant execute on function public.fb_sync_scores(jsonb) to service_role;

-- Wat moet de functie ophalen bij the-odds-api.com? (zuinig: 500 gratis vragen per maand)
-- odds: elke 12 uur, voor de competities met wedstrijden in de komende 8 dagen (+ Pro League en Nations League)
-- scores: elke 6 uur, enkel als er een Pro League- of Nations League-wedstrijd op een uitslag wacht
create or replace function public.fb_odds_plan() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'odds', coalesce((select last_odds < now() - interval '12 hours' from public.fb_config where id = 1), true),
    'comps', coalesce((select jsonb_agg(distinct competition) from public.fb_matches
                       where status = 'scheduled' and kickoff between now() and now() + interval '8 days'), '[]'::jsonb),
    'scores', coalesce((select last_scores is null or last_scores < now() - interval '6 hours' from public.fb_config where id = 1), true)
              and exists (select 1 from public.fb_matches where ext_id is null and odds_id is not null and not settled
                          and status = 'scheduled' and kickoff < now() - interval '150 minutes' and kickoff > now() - interval '3 days'),
    'score_comps', coalesce((select jsonb_agg(distinct competition) from public.fb_matches where ext_id is null and odds_id is not null
                       and not settled and status = 'scheduled' and kickoff < now() - interval '150 minutes'), '[]'::jsonb));
$$;
revoke all on function public.fb_odds_plan() from public, anon, authenticated;
grant execute on function public.fb_odds_plan() to service_role;

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

-- =====================================================================
-- GEHEIME-TROFEEEN-UPDATE (zelfde inhoud als update-27-geheime-trofeeen.sql)
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

-- =====================================================================
-- BOSS-UPDATE (zelfde inhoud als update-29-boss.sql)
-- =====================================================================

insert into public.feature_flags (key, note) values ('boss', 'Boss Battle op zondag') on conflict (key) do nothing;

-- 1. Tabellen ---------------------------------------------------------------------------------------
create table if not exists public.boss_events (
  id bigserial primary key,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  name text not null,
  title text,                                    -- uitspraak of bijnaam
  image_path text,                               -- bestand in de opslagmap boss-images
  weakness_kind text check (weakness_kind in ('person', 'rarity')),
  weakness_value text,
  hp_override int,
  hp_max int,                                    -- vastgelegd bij het eerste gevecht
  defeated_at timestamptz,
  last_hit uuid references auth.users(id) on delete set null,
  paid boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists boss_events_time_idx on public.boss_events (ends_at);
alter table public.boss_events enable row level security; -- enkel via de functies

create table if not exists public.boss_fights (
  id bigserial primary key,
  event_id bigint not null references public.boss_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  cards int[] not null,
  started_at timestamptz not null default now(),
  taps int not null default 0,
  supers int not null default 0,
  damage int not null default 0,
  ended boolean not null default false
);
create index if not exists boss_fights_event_idx on public.boss_fights (event_id, user_id);
alter table public.boss_fights enable row level security;

create table if not exists public.boss_hits (
  id bigserial primary key,
  event_id bigint not null references public.boss_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  damage int not null,
  super boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists boss_hits_event_idx on public.boss_hits (event_id, id desc);
alter table public.boss_hits enable row level security;

create table if not exists public.boss_rewards (
  event_id bigint not null references public.boss_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  damage int not null,
  credits int not null,
  primary key (event_id, user_id)
);
alter table public.boss_rewards enable row level security;

-- 2. Foto's van de bosses: privé, enkel voor ingelogde spelers; enkel de admin kan uploaden ---------------
insert into storage.buckets (id, name, public) values ('boss-images', 'boss-images', false)
on conflict (id) do update set public = false;
drop policy if exists "boss-foto's lezen" on storage.objects;
create policy "boss-foto's lezen" on storage.objects for select to authenticated using (bucket_id = 'boss-images');
drop policy if exists "boss-foto's uploaden" on storage.objects;
create policy "boss-foto's uploaden" on storage.objects for insert to authenticated with check (bucket_id = 'boss-images' and public.is_admin());
drop policy if exists "boss-foto's wijzigen" on storage.objects;
create policy "boss-foto's wijzigen" on storage.objects for update to authenticated using (bucket_id = 'boss-images' and public.is_admin());
drop policy if exists "boss-foto's verwijderen" on storage.objects;
create policy "boss-foto's verwijderen" on storage.objects for delete to authenticated using (bucket_id = 'boss-images' and public.is_admin());

-- 3. Hulpfuncties -----------------------------------------------------------------------------------
-- Huidige boss: de eerste die nog niet (langer dan 12 uur) voorbij is
create or replace function public._boss_current() returns public.boss_events
language sql stable security definer set search_path = public as $$
  select * from public.boss_events where ends_at > now() - interval '12 hours' order by starts_at limit 1;
$$;
revoke all on function public._boss_current() from public, anon, authenticated;

-- Schade per tik en per superaanval van een kaart (zwakte = ×1,5)
create or replace function public._boss_card_power(e public.boss_events, c public.cards) returns jsonb
language sql stable as $$
  select jsonb_build_object('id', c.id, 'name', c.name, 'person', c.person, 'rarity', c.rarity, 'hp', c.hp,
    'weak', w > 1,
    'tap', round(c.attack * m * w)::int,
    'super', round(coalesce(c.special_power, c.attack * 1.6) * 6 * m * w)::int)
  from (select case c.rarity when 'legendary' then 1.6 when 'epic' then 1.25 when 'cat' then .7 else 1 end as m,
               case when (e.weakness_kind = 'person' and lower(c.person) = lower(e.weakness_value))
                      or (e.weakness_kind = 'rarity' and c.rarity = e.weakness_value) then 1.5 else 1 end as w) x;
$$;

-- Hoeveel HP? Vastgelegd bij het eerste gevecht
create or replace function public._boss_hp(p_event bigint) returns int
language plpgsql volatile security definer set search_path = public as $$
declare e public.boss_events; n int;
begin
  select * into e from public.boss_events where id = p_event for update;
  if e.hp_max is not null then return e.hp_max; end if;
  -- spelers die de afgelopen 7 dagen de app open hadden (zonder admin)
  select count(*) into n from public.profiles where last_active > now() - interval '7 days' and not public._is_admin_user(id);
  update public.boss_events set hp_max = coalesce(hp_override, greatest(33000, 11000 * coalesce(n, 0))) where id = p_event
  returning hp_max into n;
  return n;
end $$;
revoke all on function public._boss_hp(bigint) from public, anon, authenticated;

-- Verslagen: iedereen die meedeed krijgt zijn beloning (één keer)
create or replace function public._boss_pay(p_event bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare e public.boss_events; tot int; top uuid; r record; cr int;
begin
  select * into e from public.boss_events where id = p_event for update;
  if e.paid or e.defeated_at is null then return; end if;
  select coalesce(sum(damage), 0) into tot from public.boss_fights where event_id = p_event;
  select user_id into top from public.boss_fights where event_id = p_event group by user_id order by sum(damage) desc limit 1;
  for r in select user_id, sum(damage)::int as dmg from public.boss_fights where event_id = p_event group by user_id having sum(damage) > 0 loop
    cr := 50 + floor(500.0 * r.dmg / greatest(tot, 1))::int + case when r.user_id = top then 50 else 0 end
          + case when r.user_id = e.last_hit then 25 else 0 end;
    insert into public.boss_rewards (event_id, user_id, damage, credits) values (p_event, r.user_id, r.dmg, cr) on conflict do nothing;
    update public.user_wallet set polycoins = polycoins + cr where user_id = r.user_id;
  end loop;
  update public.boss_events set paid = true where id = p_event;
end $$;
revoke all on function public._boss_pay(bigint) from public, anon, authenticated;

-- 4. Alles voor het scherm --------------------------------------------------------------------------
create or replace function public.boss_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e public.boss_events; me uuid := auth.uid(); adm boolean; phase text; dmg int; hp int; reveal boolean;
begin
  if me is null or not public._feature_on('boss') then return null; end if;
  adm := public._is_admin_user(me);
  e := public._boss_current();
  if e.id is null then return jsonb_build_object('now', now(), 'is_admin', adm, 'event', null); end if;
  phase := case when e.defeated_at is not null then 'defeated' when now() < e.starts_at then 'upcoming'
                when now() < e.ends_at then 'live' else 'ended' end;
  reveal := phase <> 'upcoming' or adm;
  select coalesce(sum(damage), 0) into dmg from public.boss_fights where event_id = e.id;
  hp := coalesce(e.hp_max, e.hp_override);
  return jsonb_build_object('now', now(), 'is_admin', adm, 'event', jsonb_build_object(
    'id', e.id, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'phase', phase, 'defeated_at', e.defeated_at,
    'name', case when reveal then e.name end, 'title', case when reveal then e.title end, 'image_path', e.image_path,
    'weakness_kind', e.weakness_kind, 'weakness_value', e.weakness_value,
    'hp_max', hp, 'damage', dmg,
    'players', (select count(distinct user_id) from public.boss_fights f where f.event_id = e.id),
    'last_hit', (select display_name from public.profiles where id = e.last_hit),
    'top', coalesce((select jsonb_agg(x order by x.dmg desc) from (
       select coalesce(p.display_name, '?') as name, sum(f.damage)::int as dmg, f.user_id = me as me from public.boss_fights f
       left join public.profiles p on p.id = f.user_id
       where f.event_id = e.id and (adm or not public._is_admin_user(f.user_id)) group by f.user_id, p.display_name
       having sum(f.damage) > 0 order by sum(f.damage) desc limit 5) x), '[]'::jsonb),
    'my', jsonb_build_object(
      'fights', (select count(*) from public.boss_fights where event_id = e.id and user_id = me),
      'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id and user_id = me),
      'used', coalesce((select jsonb_agg(distinct c) from public.boss_fights f, unnest(f.cards) c where f.event_id = e.id and f.user_id = me), '[]'::jsonb),
      'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me))));
end $$;
grant execute on function public.boss_status() to authenticated;

-- 5. Een gevecht starten (3 kaarten; vanaf het tweede gevecht hetzelfde team) ---------------------------
create or replace function public.boss_fight_start(p_cards int[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); e public.boss_events; fid bigint; hp int; team jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if not public._feature_on('boss') then raise exception 'De Boss Battle is nog niet open.'; end if;
  e := public._boss_current();
  if e.id is null or now() < e.starts_at or now() >= e.ends_at then raise exception 'Er is nu geen Boss Battle bezig.'; end if;
  if e.defeated_at is not null then raise exception 'De boss is al verslagen!'; end if;
  if (select count(*) from public.boss_fights where event_id = e.id and user_id = me) >= 3 then
    raise exception 'Je hebt je 3 gevechten van vanavond al gespeeld.';
  end if;
  if p_cards is null or array_length(p_cards, 1) <> 3 or (select count(distinct c) from unnest(p_cards) c) <> 3 then
    raise exception 'Kies 3 verschillende kaarten.';
  end if;
  if not public._is_admin_user(me) and exists (select 1 from unnest(p_cards) c
       where not exists (select 1 from public.user_cards uc where uc.user_id = me and uc.card_id = c)) then
    raise exception 'Je kan enkel kaarten gebruiken die je hebt.';
  end if;
  if exists (select 1 from public.boss_fights f where f.event_id = e.id and f.user_id = me
             and not (f.cards @> p_cards and p_cards @> f.cards)) then
    raise exception 'Je team ligt vast voor vanavond: vecht met dezelfde 3 kaarten.';
  end if;
  update public.boss_fights set ended = true where event_id = e.id and user_id = me and not ended;
  hp := public._boss_hp(e.id);
  insert into public.boss_fights (event_id, user_id, cards) values (e.id, me, p_cards) returning id into fid;
  select jsonb_agg(public._boss_card_power(e, c) order by array_position(p_cards, c.id)) into team
  from public.cards c where c.id = any (p_cards);
  return jsonb_build_object('fight', fid, 'team', team, 'hp_max', hp, 'seconds', 30,
    'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id));
end $$;
grant execute on function public.boss_fight_start(int[]) to authenticated;

-- 6. Schade doorsturen (elke paar seconden tijdens het gevecht) --------------------------------------------
-- p_hits: {"<kaart-id>": [tikken, superaanvallen], ...}
create or replace function public.boss_hit(p_fight bigint, p_hits jsonb, p_final boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); f public.boss_fights; e public.boss_events; k text; t int; s int; pw jsonb;
        dmg int := 0; v_taps int := 0; v_sups int := 0; secs numeric; tot int; hp int; killed boolean := false;
begin
  select * into f from public.boss_fights where id = p_fight and user_id = me for update;
  if not found then raise exception 'Gevecht niet gevonden.'; end if;
  select * into e from public.boss_events where id = f.event_id for update;
  if f.ended or e.defeated_at is not null or now() > e.ends_at + interval '1 minute' then
    update public.boss_fights set ended = true where id = f.id;
    return jsonb_build_object('damage', 0, 'total', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id),
      'hp_max', e.hp_max, 'defeated', e.defeated_at is not null, 'ended', true);
  end if;
  for k, t, s in select key, coalesce((value->>0)::int, 0), coalesce((value->>1)::int, 0) from jsonb_each(coalesce(p_hits, '{}'::jsonb)) loop
    if not (k::int = any (f.cards)) or t < 0 or s < 0 then raise exception 'Ongeldige aanval.'; end if;
    select public._boss_card_power(e, c) into pw from public.cards c where c.id = k::int;
    v_taps := v_taps + t; v_sups := v_sups + s;
    dmg := dmg + t * (pw->>'tap')::int + s * (pw->>'super')::int;
  end loop;
  -- niet sneller dan een mens: max. 8 tikken per seconde, één superaanval per 10 tikken, 30 seconden
  secs := least(35, extract(epoch from now() - f.started_at));
  if f.taps + v_taps > secs * 8 + 10 or f.supers + v_sups > floor((f.taps + v_taps) / 10.0) + 1 then
    raise exception 'Te snel getikt.';
  end if;
  update public.boss_fights set taps = taps + v_taps, supers = supers + v_sups, damage = damage + dmg,
    ended = p_final or secs >= 34 where id = f.id;
  if dmg > 0 then insert into public.boss_hits (event_id, user_id, damage, super) values (e.id, me, dmg, v_sups > 0); end if;
  hp := coalesce(e.hp_max, public._boss_hp(e.id));
  select coalesce(sum(damage), 0) into tot from public.boss_fights where event_id = e.id;
  if tot >= hp then
    update public.boss_events set defeated_at = now(), last_hit = me where id = e.id;
    update public.boss_fights set ended = true where event_id = e.id;
    perform public._boss_pay(e.id);
    killed := true;
  end if;
  return jsonb_build_object('damage', dmg, 'total', tot, 'hp_max', hp, 'defeated', killed, 'last_hit', killed,
    'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me),
    'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;
grant execute on function public.boss_hit(bigint, jsonb, boolean) to authenticated;

-- 7. Admin: bosses beheren -------------------------------------------------------------------------
create or replace function public.boss_admin_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public._is_admin_user(auth.uid()) then coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'starts_at', starts_at, 'ends_at', ends_at, 'name', name, 'title', title, 'image_path', image_path,
    'weakness_kind', weakness_kind, 'weakness_value', weakness_value, 'hp_override', hp_override, 'hp_max', hp_max,
    'defeated_at', defeated_at, 'damage', (select coalesce(sum(damage), 0) from public.boss_fights f where f.event_id = b.id))
    order by starts_at desc) from public.boss_events b where ends_at > now() - interval '30 days'), '[]'::jsonb) end;
$$;
grant execute on function public.boss_admin_list() to authenticated;

-- Namen en uitspraken: de server verzint er zelf een (zelden twee keer dezelfde)
create or replace function public._boss_names() returns table (name text, title text)
language sql immutable as $$
  values
    ('Madame Mayhem', 'Kom dichterbij… als je durft.'),
    ('Lady Lust', 'Ik breek harten. En kaarten.'),
    ('De Verleidster', 'Eén knipoog en je bent je credits kwijt.'),
    ('Miss Chief', 'Ik ben het probleem waar je mama je voor waarschuwde.'),
    ('Barones Booty Call', 'Om 3u ''s nachts bel ik jou.'),
    ('Queen of Tease', 'Kijken mag. Winnen niet.'),
    ('De Nachtvlinder', 'Na 20u ben ik niet meer te stoppen.'),
    ('Lady Lingerie', 'Kant en klaar om je te slopen.'),
    ('Señorita Spicy', 'Te heet om te verslaan.'),
    ('De Rizz Duchess', 'Jouw rizz is schattig. Die van mij is dodelijk.'),
    ('Mistress of Mischief', 'Brave jongens verliezen eerst.'),
    ('De Heartbreaker', 'Je eerste aanval? Lief. Je laatste? Ook.'),
    ('Lady Lipstick', 'Ik laat altijd een afdruk achter.'),
    ('Femme Fatale', 'Mijn naam zegt genoeg.'),
    ('De OnlyFoe', 'Abonneer je op pijn.'),
    ('Hot Mess Express', 'Ik kom, ik zie, ik sloop.'),
    ('Lady Leather', 'Ik draag leer. Jij draagt verlies.'),
    ('Miss Thirst Trap', 'Je kon niet wegkijken. Dat was je fout.'),
    ('De Swipe Queen', 'Links geswiped. Voor altijd.'),
    ('Princess Plot Twist', 'Je dacht dat ik lief was.'),
    ('De Kusjesmachine', 'Elke kus kost 100 HP.'),
    ('Lady Late Night', 'Wie slaapt, verliest.'),
    ('Madame Flirt', 'Ik flirt. Jullie sterven.'),
    ('Hottie Hurricane', 'Opgelet: zware stormschade.'),
    ('De Spicy Sirene', 'Volg mijn stem… naar je ondergang.'),
    ('Miss Red Flag', 'Je zag alle signalen. En toch kwam je.'),
    ('Countess Crush', 'Iedereen heeft een crush op mij. Ook je kaarten.'),
    ('De DM-Duivelin', 'Nieuw bericht: je bent verslagen.'),
    ('Lady Afterhours', 'Het feest begint pas als jullie verliezen.'),
    ('Queen Situationship', 'Wat zijn we? Vijanden.');
$$;

-- Volgende vrije zondag 20u (Belgische tijd) zonder boss
create or replace function public._boss_next_sunday() returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare d date := (now() at time zone 'Europe/Brussels')::date; t timestamptz;
begin
  d := d + ((7 - extract(dow from d)::int) % 7);
  loop
    t := (d + time '20:00') at time zone 'Europe/Brussels';
    if t > now() and not exists (select 1 from public.boss_events where starts_at::date between d - 1 and d + 1
                                 and abs(extract(epoch from starts_at - t)) < 86400) then return t; end if;
    d := d + 7;
  end loop;
end $$;
revoke all on function public._boss_next_sunday() from public, anon, authenticated;

-- Opslaan. Leeg laten = de server kiest: naam en uitspraak, willekeurige zwakte, eerstvolgende vrije zondag 20u.
create or replace function public.boss_admin_save(p_id bigint, p_starts_at timestamptz, p_name text, p_title text, p_image_path text,
  p_weakness_kind text, p_weakness_value text, p_hp_override int) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare v_id bigint; nm record; old public.boss_events;
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  if p_id is not null then select * into old from public.boss_events where id = p_id; end if;
  -- naam en uitspraak verzinnen (eentje die de laatste tijd niet gebruikt werd)
  if coalesce(trim(p_name), '') = '' then
    select n.name, n.title into nm from public._boss_names() n
    where n.name not in (select name from public.boss_events where id is distinct from p_id order by starts_at desc limit 20)
    order by random() limit 1;
    if nm.name is null then select n.name, n.title into nm from public._boss_names() n order by random() limit 1; end if;
    p_name := nm.name;
    if coalesce(trim(p_title), '') = '' then p_title := nm.title; end if;
  end if;
  -- willekeurige zwakte: een zeldzaamheid of de kaarten van één persoon (niet dezelfde als vorige week)
  if p_weakness_kind is null or p_weakness_kind not in ('person', 'rarity') then
    if random() < .5 then
      p_weakness_kind := 'rarity';
      p_weakness_value := (array['common', 'common', 'epic', 'epic', 'legendary'])[1 + floor(random() * 5)::int];
    else
      p_weakness_kind := 'person';
      select person into p_weakness_value from (select distinct person from public.cards where rarity <> 'cat') x
      where person is distinct from (select weakness_value from public.boss_events where weakness_kind = 'person' order by starts_at desc limit 1)
      order by random() limit 1;
    end if;
  end if;
  p_starts_at := coalesce(p_starts_at, old.starts_at, public._boss_next_sunday());
  if p_id is null then
    insert into public.boss_events (starts_at, ends_at, name, title, image_path, weakness_kind, weakness_value, hp_override)
    values (p_starts_at, p_starts_at + interval '1 hour', trim(p_name), nullif(trim(p_title), ''), p_image_path,
            p_weakness_kind, nullif(trim(p_weakness_value), ''), nullif(p_hp_override, 0))
    returning id into v_id;
  else
    update public.boss_events set starts_at = p_starts_at, ends_at = p_starts_at + interval '1 hour', name = trim(p_name),
      title = nullif(trim(p_title), ''), image_path = coalesce(p_image_path, image_path), weakness_kind = p_weakness_kind,
      weakness_value = nullif(trim(p_weakness_value), ''), hp_override = nullif(p_hp_override, 0),
      hp_max = case when defeated_at is null and not exists (select 1 from public.boss_fights where event_id = p_id) then null else hp_max end
    where id = p_id returning id into v_id;
  end if;
  return v_id;
end $$;
grant execute on function public.boss_admin_save(bigint, timestamptz, text, text, text, text, text, int) to authenticated;

create or replace function public.boss_admin_delete(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  if exists (select 1 from public.boss_events where id = p_id and paid) then raise exception 'Deze boss is al uitbetaald.'; end if;
  delete from public.boss_events where id = p_id;
end $$;
grant execute on function public.boss_admin_delete(bigint) to authenticated;

-- Test: de boss nu meteen starten (1 uur), alles van eerdere tests gewist
create or replace function public.boss_admin_test(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  if exists (select 1 from public.boss_events where id = p_id and paid
             and exists (select 1 from public.boss_rewards r where r.event_id = p_id and not public._is_admin_user(r.user_id))) then
    raise exception 'Deze boss is al echt gespeeld en uitbetaald.';
  end if;
  delete from public.boss_fights where event_id = p_id;
  delete from public.boss_hits where event_id = p_id;
  delete from public.boss_rewards where event_id = p_id;
  update public.boss_events set starts_at = now(), ends_at = now() + interval '1 hour', hp_max = null,
    defeated_at = null, last_hit = null, paid = false where id = p_id;
end $$;
grant execute on function public.boss_admin_test(bigint) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- FOTO-UPDATE (zelfde inhoud als update-30-fotos-kleiner.sql)
-- =====================================================================

drop policy if exists "kaartfoto's uploaden (admin)" on storage.objects;
create policy "kaartfoto's uploaden (admin)" on storage.objects
  for insert to authenticated with check (bucket_id = 'card-photos' and public.is_admin());

drop policy if exists "kaartfoto's vervangen (admin)" on storage.objects;
create policy "kaartfoto's vervangen (admin)" on storage.objects
  for update to authenticated using (bucket_id = 'card-photos' and public.is_admin())
  with check (bucket_id = 'card-photos' and public.is_admin());

-- =====================================================================
-- BOSS-SILHOUET-UPDATE (zelfde inhoud als update-31-boss-silhouet.sql)
-- =====================================================================

alter table public.boss_events add column if not exists sil_path text;

-- Welke boss-bestanden mag een speler zien? Silhouetten altijd, de echte foto pas vanaf de start.
create or replace function public._boss_img_visible(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from public.boss_events
    where sil_path = p_name or (image_path = p_name and starts_at <= now()));
$$;
grant execute on function public._boss_img_visible(text) to authenticated;

drop policy if exists "boss-foto's lezen" on storage.objects;
create policy "boss-foto's lezen" on storage.objects for select to authenticated
  using (bucket_id = 'boss-images' and public._boss_img_visible(name));

-- Silhouet koppelen (de site maakt het bestand bij het uploaden)
create or replace function public.boss_admin_set_sil(p_id bigint, p_path text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  update public.boss_events set sil_path = p_path where id = p_id;
end $$;
grant execute on function public.boss_admin_set_sil(bigint, text) to authenticated;

create or replace function public.boss_admin_list() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public._is_admin_user(auth.uid()) then coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'starts_at', starts_at, 'ends_at', ends_at, 'name', name, 'title', title, 'image_path', image_path, 'sil_path', sil_path,
    'weakness_kind', weakness_kind, 'weakness_value', weakness_value, 'hp_override', hp_override, 'hp_max', hp_max,
    'defeated_at', defeated_at, 'damage', (select coalesce(sum(damage), 0) from public.boss_fights f where f.event_id = b.id))
    order by starts_at desc) from public.boss_events b where ends_at > now() - interval '30 days'), '[]'::jsonb) end;
$$;
grant execute on function public.boss_admin_list() to authenticated;

-- Status: voor de start geen naam en geen echte foto (ook niet voor de admin), wel het silhouet.
-- teaser_from = woensdag 00u van die week: vanaf dan staat de boss op het plein.
create or replace function public.boss_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e public.boss_events; me uuid := auth.uid(); adm boolean; phase text; dmg int; hp int; reveal boolean;
begin
  if me is null or not public._feature_on('boss') then return null; end if;
  adm := public._is_admin_user(me);
  e := public._boss_current();
  if e.id is null then return jsonb_build_object('now', now(), 'is_admin', adm, 'event', null); end if;
  phase := case when e.defeated_at is not null then 'defeated' when now() < e.starts_at then 'upcoming'
                when now() < e.ends_at then 'live' else 'ended' end;
  reveal := phase <> 'upcoming';
  select coalesce(sum(damage), 0) into dmg from public.boss_fights where event_id = e.id;
  hp := coalesce(e.hp_max, e.hp_override);
  return jsonb_build_object('now', now(), 'is_admin', adm, 'event', jsonb_build_object(
    'id', e.id, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'phase', phase, 'defeated_at', e.defeated_at,
    'teaser_from', ((e.starts_at at time zone 'Europe/Brussels')::date - 4)::timestamp at time zone 'Europe/Brussels',
    'name', case when reveal then e.name end, 'title', case when reveal then e.title end,
    'image_path', case when reveal then e.image_path end, 'sil_path', e.sil_path,
    'weakness_kind', e.weakness_kind, 'weakness_value', e.weakness_value,
    'hp_max', hp, 'damage', dmg,
    'players', (select count(distinct user_id) from public.boss_fights f where f.event_id = e.id),
    'last_hit', (select display_name from public.profiles where id = e.last_hit),
    'top', coalesce((select jsonb_agg(x order by x.dmg desc) from (
       select coalesce(p.display_name, '?') as name, sum(f.damage)::int as dmg, f.user_id = me as me from public.boss_fights f
       left join public.profiles p on p.id = f.user_id
       where f.event_id = e.id and (adm or not public._is_admin_user(f.user_id)) group by f.user_id, p.display_name
       having sum(f.damage) > 0 order by sum(f.damage) desc limit 5) x), '[]'::jsonb),
    'my', jsonb_build_object(
      'fights', (select count(*) from public.boss_fights where event_id = e.id and user_id = me),
      'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id and user_id = me),
      'used', coalesce((select jsonb_agg(distinct c) from public.boss_fights f, unnest(f.cards) c where f.event_id = e.id and f.user_id = me), '[]'::jsonb),
      'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me))));
end $$;
grant execute on function public.boss_status() to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- BOSS-30S-UPDATE (zelfde inhoud als update-32-boss-30s.sql)
-- =====================================================================

create or replace function public._boss_hp(p_event bigint) returns int
language plpgsql volatile security definer set search_path = public as $$
declare e public.boss_events; n int;
begin
  select * into e from public.boss_events where id = p_event for update;
  if e.hp_max is not null then return e.hp_max; end if;
  -- spelers die de afgelopen 7 dagen de app open hadden (zonder admin)
  select count(*) into n from public.profiles where last_active > now() - interval '7 days' and not public._is_admin_user(id);
  update public.boss_events set hp_max = coalesce(hp_override, greatest(33000, 11000 * coalesce(n, 0))) where id = p_event
  returning hp_max into n;
  return n;
end $$;
revoke all on function public._boss_hp(bigint) from public, anon, authenticated;

create or replace function public.boss_fight_start(p_cards int[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); e public.boss_events; fid bigint; hp int; team jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if not public._feature_on('boss') then raise exception 'De Boss Battle is nog niet open.'; end if;
  e := public._boss_current();
  if e.id is null or now() < e.starts_at or now() >= e.ends_at then raise exception 'Er is nu geen Boss Battle bezig.'; end if;
  if e.defeated_at is not null then raise exception 'De boss is al verslagen!'; end if;
  if (select count(*) from public.boss_fights where event_id = e.id and user_id = me) >= 3 then
    raise exception 'Je hebt je 3 gevechten van vanavond al gespeeld.';
  end if;
  if p_cards is null or array_length(p_cards, 1) <> 3 or (select count(distinct c) from unnest(p_cards) c) <> 3 then
    raise exception 'Kies 3 verschillende kaarten.';
  end if;
  if not public._is_admin_user(me) and exists (select 1 from unnest(p_cards) c
       where not exists (select 1 from public.user_cards uc where uc.user_id = me and uc.card_id = c)) then
    raise exception 'Je kan enkel kaarten gebruiken die je hebt.';
  end if;
  if exists (select 1 from public.boss_fights f where f.event_id = e.id and f.user_id = me
             and not (f.cards @> p_cards and p_cards @> f.cards)) then
    raise exception 'Je team ligt vast voor vanavond: vecht met dezelfde 3 kaarten.';
  end if;
  update public.boss_fights set ended = true where event_id = e.id and user_id = me and not ended;
  hp := public._boss_hp(e.id);
  insert into public.boss_fights (event_id, user_id, cards) values (e.id, me, p_cards) returning id into fid;
  select jsonb_agg(public._boss_card_power(e, c) order by array_position(p_cards, c.id)) into team
  from public.cards c where c.id = any (p_cards);
  return jsonb_build_object('fight', fid, 'team', team, 'hp_max', hp, 'seconds', 30,
    'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id));
end $$;
grant execute on function public.boss_fight_start(int[]) to authenticated;

create or replace function public.boss_hit(p_fight bigint, p_hits jsonb, p_final boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); f public.boss_fights; e public.boss_events; k text; t int; s int; pw jsonb;
        dmg int := 0; v_taps int := 0; v_sups int := 0; secs numeric; tot int; hp int; killed boolean := false;
begin
  select * into f from public.boss_fights where id = p_fight and user_id = me for update;
  if not found then raise exception 'Gevecht niet gevonden.'; end if;
  select * into e from public.boss_events where id = f.event_id for update;
  if f.ended or e.defeated_at is not null or now() > e.ends_at + interval '1 minute' then
    update public.boss_fights set ended = true where id = f.id;
    return jsonb_build_object('damage', 0, 'total', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id),
      'hp_max', e.hp_max, 'defeated', e.defeated_at is not null, 'ended', true);
  end if;
  for k, t, s in select key, coalesce((value->>0)::int, 0), coalesce((value->>1)::int, 0) from jsonb_each(coalesce(p_hits, '{}'::jsonb)) loop
    if not (k::int = any (f.cards)) or t < 0 or s < 0 then raise exception 'Ongeldige aanval.'; end if;
    select public._boss_card_power(e, c) into pw from public.cards c where c.id = k::int;
    v_taps := v_taps + t; v_sups := v_sups + s;
    dmg := dmg + t * (pw->>'tap')::int + s * (pw->>'super')::int;
  end loop;
  -- niet sneller dan een mens: max. 8 tikken per seconde, één superaanval per 10 tikken, 30 seconden
  secs := least(35, extract(epoch from now() - f.started_at));
  if f.taps + v_taps > secs * 8 + 10 or f.supers + v_sups > floor((f.taps + v_taps) / 10.0) + 1 then
    raise exception 'Te snel getikt.';
  end if;
  update public.boss_fights set taps = taps + v_taps, supers = supers + v_sups, damage = damage + dmg,
    ended = p_final or secs >= 34 where id = f.id;
  if dmg > 0 then insert into public.boss_hits (event_id, user_id, damage, super) values (e.id, me, dmg, v_sups > 0); end if;
  hp := coalesce(e.hp_max, public._boss_hp(e.id));
  select coalesce(sum(damage), 0) into tot from public.boss_fights where event_id = e.id;
  if tot >= hp then
    update public.boss_events set defeated_at = now(), last_hit = me where id = e.id;
    update public.boss_fights set ended = true where event_id = e.id;
    perform public._boss_pay(e.id);
    killed := true;
  end if;
  return jsonb_build_object('damage', dmg, 'total', tot, 'hp_max', hp, 'defeated', killed, 'last_hit', killed,
    'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me),
    'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;
grant execute on function public.boss_hit(bigint, jsonb, boolean) to authenticated;

-- Bosses die nog niet gestart zijn: HP opnieuw laten berekenen bij het eerste gevecht
update public.boss_events b set hp_max = null
where b.starts_at > now() and not exists (select 1 from public.boss_fights f where f.event_id = b.id);

notify pgrst, 'reload schema';

-- =====================================================================
-- BOSS-TEAM-HP-UPDATE (zelfde inhoud als update-33-boss-hp-team.sql)
-- =====================================================================

alter table public.boss_fights add column if not exists card_hp jsonb;   -- {"<kaart-id>": resterende HP}
drop function if exists public.boss_hit(bigint, jsonb, boolean);

create or replace function public._boss_hp(p_event bigint) returns int
language plpgsql volatile security definer set search_path = public as $$
declare e public.boss_events; n int;
begin
  select * into e from public.boss_events where id = p_event for update;
  if e.hp_max is not null then return e.hp_max; end if;
  -- spelers die de afgelopen 7 dagen de app open hadden (zonder admin)
  select count(*) into n from public.profiles where last_active > now() - interval '7 days' and not public._is_admin_user(id);
  update public.boss_events set hp_max = coalesce(hp_override, greatest(27000, 9000 * coalesce(n, 0))) where id = p_event
  returning hp_max into n;
  return n;
end $$;
revoke all on function public._boss_hp(bigint) from public, anon, authenticated;

create or replace function public.boss_fight_start(p_cards int[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); e public.boss_events; fid bigint; hp int; team jsonb; prev jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if not public._feature_on('boss') then raise exception 'De Boss Battle is nog niet open.'; end if;
  e := public._boss_current();
  if e.id is null or now() < e.starts_at or now() >= e.ends_at then raise exception 'Er is nu geen Boss Battle bezig.'; end if;
  if e.defeated_at is not null then raise exception 'De boss is al verslagen!'; end if;
  if (select count(*) from public.boss_fights where event_id = e.id and user_id = me) >= 3 then
    raise exception 'Je hebt je 3 gevechten van vanavond al gespeeld.';
  end if;
  if p_cards is null or array_length(p_cards, 1) <> 3 or (select count(distinct c) from unnest(p_cards) c) <> 3 then
    raise exception 'Kies 3 verschillende kaarten.';
  end if;
  if not public._is_admin_user(me) and exists (select 1 from unnest(p_cards) c
       where not exists (select 1 from public.user_cards uc where uc.user_id = me and uc.card_id = c)) then
    raise exception 'Je kan enkel kaarten gebruiken die je hebt.';
  end if;
  if exists (select 1 from public.boss_fights f where f.event_id = e.id and f.user_id = me
             and not (f.cards @> p_cards and p_cards @> f.cards)) then
    raise exception 'Je team ligt vast voor vanavond: vecht met dezelfde 3 kaarten.';
  end if;
  update public.boss_fights set ended = true where event_id = e.id and user_id = me and not ended;
  -- HP van je kaarten blijft behouden over je gevechten van de avond
  select card_hp into prev from public.boss_fights where event_id = e.id and user_id = me and card_hp is not null order by id desc limit 1;
  if prev is not null and not exists (select 1 from jsonb_each_text(prev) where value::int > 0) then
    raise exception 'Je team is uitgeteld voor vanavond. Volgende week beter!';
  end if;
  hp := public._boss_hp(e.id);
  select jsonb_object_agg(c.id::text, coalesce((prev->>c.id::text)::int, c.hp)) into prev from public.cards c where c.id = any (p_cards);
  insert into public.boss_fights (event_id, user_id, cards, card_hp) values (e.id, me, p_cards, prev) returning id into fid;
  select jsonb_agg(public._boss_card_power(e, c) || jsonb_build_object('left', (prev->>c.id::text)::int) order by array_position(p_cards, c.id)) into team
  from public.cards c where c.id = any (p_cards);
  return jsonb_build_object('fight', fid, 'team', team, 'hp_max', hp, 'seconds', 30,
    'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id));
end $$;
grant execute on function public.boss_fight_start(int[]) to authenticated;

create or replace function public.boss_hit(p_fight bigint, p_hits jsonb, p_final boolean default false, p_hp jsonb default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); f public.boss_fights; e public.boss_events; k text; t int; s int; pw jsonb;
        dmg int := 0; v_taps int := 0; v_sups int := 0; secs numeric; tot int; hp int; killed boolean := false;
begin
  select * into f from public.boss_fights where id = p_fight and user_id = me for update;
  if not found then raise exception 'Gevecht niet gevonden.'; end if;
  select * into e from public.boss_events where id = f.event_id for update;
  if f.ended or e.defeated_at is not null or now() > e.ends_at + interval '1 minute' then
    update public.boss_fights set ended = true where id = f.id;
    return jsonb_build_object('damage', 0, 'total', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id),
      'hp_max', e.hp_max, 'defeated', e.defeated_at is not null, 'ended', true);
  end if;
  for k, t, s in select key, coalesce((value->>0)::int, 0), coalesce((value->>1)::int, 0) from jsonb_each(coalesce(p_hits, '{}'::jsonb)) loop
    if not (k::int = any (f.cards)) or t < 0 or s < 0 then raise exception 'Ongeldige aanval.'; end if;
    select public._boss_card_power(e, c) into pw from public.cards c where c.id = k::int;
    v_taps := v_taps + t; v_sups := v_sups + s;
    dmg := dmg + t * (pw->>'tap')::int + s * (pw->>'super')::int;
  end loop;
  -- niet sneller dan een mens: max. 8 tikken per seconde, één superaanval per 10 tikken, 30 seconden
  secs := least(35, extract(epoch from now() - f.started_at));
  if f.taps + v_taps > secs * 8 + 10 or f.supers + v_sups > floor((f.taps + v_taps) / 10.0) + 1 then
    raise exception 'Te snel getikt.';
  end if;
  -- HP van de kaarten: kan enkel dalen
  if p_hp is not null then
    update public.boss_fights set card_hp = (select jsonb_object_agg(k2, least(v2::int, greatest(0, coalesce((p_hp->>k2)::int, v2::int))))
                                             from jsonb_each_text(card_hp) x(k2, v2))
    where id = f.id;
  end if;
  update public.boss_fights set taps = taps + v_taps, supers = supers + v_sups, damage = damage + dmg,
    ended = p_final or secs >= 34 where id = f.id;
  if dmg > 0 then insert into public.boss_hits (event_id, user_id, damage, super) values (e.id, me, dmg, v_sups > 0); end if;
  hp := coalesce(e.hp_max, public._boss_hp(e.id));
  select coalesce(sum(damage), 0) into tot from public.boss_fights where event_id = e.id;
  if tot >= hp then
    update public.boss_events set defeated_at = now(), last_hit = me where id = e.id;
    update public.boss_fights set ended = true where event_id = e.id;
    perform public._boss_pay(e.id);
    killed := true;
  end if;
  return jsonb_build_object('damage', dmg, 'total', tot, 'hp_max', hp, 'defeated', killed, 'last_hit', killed,
    'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me),
    'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;
grant execute on function public.boss_hit(bigint, jsonb, boolean, jsonb) to authenticated;

create or replace function public.boss_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e public.boss_events; me uuid := auth.uid(); adm boolean; phase text; dmg int; hp int; reveal boolean;
begin
  if me is null or not public._feature_on('boss') then return null; end if;
  adm := public._is_admin_user(me);
  e := public._boss_current();
  if e.id is null then return jsonb_build_object('now', now(), 'is_admin', adm, 'event', null); end if;
  phase := case when e.defeated_at is not null then 'defeated' when now() < e.starts_at then 'upcoming'
                when now() < e.ends_at then 'live' else 'ended' end;
  reveal := phase <> 'upcoming';
  select coalesce(sum(damage), 0) into dmg from public.boss_fights where event_id = e.id;
  hp := coalesce(e.hp_max, e.hp_override);
  return jsonb_build_object('now', now(), 'is_admin', adm, 'event', jsonb_build_object(
    'id', e.id, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'phase', phase, 'defeated_at', e.defeated_at,
    'teaser_from', ((e.starts_at at time zone 'Europe/Brussels')::date - 4)::timestamp at time zone 'Europe/Brussels',
    'name', case when reveal then e.name end, 'title', case when reveal then e.title end,
    'image_path', case when reveal then e.image_path end, 'sil_path', e.sil_path,
    'weakness_kind', e.weakness_kind, 'weakness_value', e.weakness_value,
    'hp_max', hp, 'damage', dmg,
    'players', (select count(distinct user_id) from public.boss_fights f where f.event_id = e.id),
    'last_hit', (select display_name from public.profiles where id = e.last_hit),
    'top', coalesce((select jsonb_agg(x order by x.dmg desc) from (
       select coalesce(p.display_name, '?') as name, sum(f.damage)::int as dmg, f.user_id = me as me from public.boss_fights f
       left join public.profiles p on p.id = f.user_id
       where f.event_id = e.id and (adm or not public._is_admin_user(f.user_id)) group by f.user_id, p.display_name
       having sum(f.damage) > 0 order by sum(f.damage) desc limit 5) x), '[]'::jsonb),
    'my', jsonb_build_object(
      'fights', (select count(*) from public.boss_fights where event_id = e.id and user_id = me),
      'damage', (select coalesce(sum(damage), 0) from public.boss_fights where event_id = e.id and user_id = me),
      'used', coalesce((select jsonb_agg(distinct c) from public.boss_fights f, unnest(f.cards) c where f.event_id = e.id and f.user_id = me), '[]'::jsonb),
      'reward', (select credits from public.boss_rewards where event_id = e.id and user_id = me),
      'team_hp', (select card_hp from public.boss_fights where event_id = e.id and user_id = me and card_hp is not null order by id desc limit 1))));
end $$;
grant execute on function public.boss_status() to authenticated;

-- Bosses die nog niet gestart zijn: HP opnieuw laten berekenen bij het eerste gevecht
update public.boss_events b set hp_max = null
where b.starts_at > now() and not exists (select 1 from public.boss_fights f where f.event_id = b.id);

notify pgrst, 'reload schema';
