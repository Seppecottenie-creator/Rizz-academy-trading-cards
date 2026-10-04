-- =====================================================================
-- SETUP: volledige database voor een NIEUW, LEEG Supabase-project
-- Verzamelkaarten-site: accounts, kaarten, vrienden, ruilen, welkomstpakket,
-- dagelijks spel (Wordle, 1 ronde per dag), tactische battles, shop en ideeënbus.
--
-- Gebruik: Supabase → SQL Editor → nieuwe query → dit VOLLEDIGE bestand plakken → Run.
-- Kies bij de waarschuwing "Run without RLS": het script zet RLS zelf aan.
-- Veilig om opnieuw uit te voeren.
--
-- Bevat GEEN kaarten: die voeg je daarna toe in public.cards (9 per persoon:
-- slot 1-6 common, 7-8 epic, 9 legendary; troostkaarten met rarity 'cat').
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
