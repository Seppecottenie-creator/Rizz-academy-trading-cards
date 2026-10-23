-- =====================================================================
-- RIZZ ACADEMY — update 29: Boss Battle (elke zondag 20u–21u)
--
-- - Elke week een andere boss (iemand die we kennen). De admin uploadt enkel een foto op de Boss-pagina;
--   naam, uitspraak, zwakte en de eerstvolgende vrije zondag 20u kiest de server zelf (aanpassen kan).
-- - Tot de start zie je enkel een silhouet en een aftelklok. Om 20u verschijnt de boss.
-- - Tijdens het uur vecht iedereen tegelijk: kies 3 kaarten (je team voor de hele avond),
--   30 seconden tikken op de boss, superaanval als je energie vol is, en ontwijk zijn aanvallen.
--   Met dat team speel je max. 3 gevechten; bij elk gevecht staan je kaarten weer recht.
-- - Eén gedeelde HP-balk voor iedereen. HP = 11.000 × aantal spelers die de afgelopen 7 dagen actief waren
--   (minstens 33.000), tenzij de admin zelf een aantal invult. Een gemiddelde speler doet ±6.000 schade
--   per gevecht: ongeveer twee op de drie spelers moeten hun 3 gevechten spelen om te winnen.
-- - Verslagen? Iedereen die meedeed krijgt credits: 50 + een deel van 500 naar verhouding van je schade,
--   +50 voor wie de meeste schade deed en +25 voor de laatste klap. Niet verslagen: niets.
-- - Alle schade wordt op de server berekend uit de kaarten en de tijd (max. 8 tikken per seconde).
-- - TESTFASE: enkel de admin ziet het (feature_flags 'boss'). Voor iedereen: release-boss.sql.
--
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-33-boss-hp-team.sql opnieuw uit.
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-25-foodtruck.sql uit (feature_flags).
-- LET OP: voer je dit bestand later opnieuw uit, voer daarna ook update-31-boss-silhouet.sql opnieuw uit.
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
