-- =====================================================================
-- RIZZ ACADEMY — update 37: cadeaupakjes die de speler zelf opent
--
-- - De admin kan een speler gratis pakjes (en credits) geven. De pakjes staan ongeopend klaar
--   in The Vault ("Cadeaus") en de speler opent ze zelf, met de gewone animatie.
-- - Elk pakje is willekeurig een Basic (1 kaart) of een Epic (3 kaarten, de laatste minstens epic),
--   met hetzelfde geluk als in de shop. De kaarten worden pas getrokken bij het openen.
--
-- Geven (in de SQL Editor):
--   select public.admin_give_gift('casper', 10, 500, 'Cadeautje van Seppe');
--   -> speler met "casper" in de naam, 10 pakjes, 500 credits, en een berichtje.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS". Veilig om opnieuw uit te voeren.
-- =====================================================================

create table if not exists public.gift_packs (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('basic', 'epic')),
  note text,
  created_at timestamptz not null default now(),
  opened_at timestamptz,
  cards jsonb
);
create index if not exists gift_packs_user_idx on public.gift_packs (user_id) where opened_at is null;
alter table public.gift_packs enable row level security;
drop policy if exists "eigen cadeaus lezen" on public.gift_packs;
create policy "eigen cadeaus lezen" on public.gift_packs for select to authenticated using (auth.uid() = user_id);

-- Een cadeaupakje openen: nu pas worden de kaarten getrokken
create or replace function public.gift_pack_open(p_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); g public.gift_packs; v_cards jsonb := '[]'::jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into g from public.gift_packs where id = p_id and user_id = me for update;
  if not found then raise exception 'Cadeau niet gevonden.'; end if;
  if g.opened_at is not null then raise exception 'Dit pakje is al open.'; end if;
  if g.kind = 'basic' then
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
  else
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(15, 85));
  end if;
  update public.gift_packs set opened_at = now(), cards = (select jsonb_agg(c->'id') from jsonb_array_elements(v_cards) c) where id = p_id;
  return jsonb_build_object('kind', g.kind, 'note', g.note, 'cards', v_cards,
    'left', (select count(*) from public.gift_packs where user_id = me and opened_at is null));
end $$;
grant execute on function public.gift_pack_open(bigint) to authenticated;

-- Admin (vanuit de SQL Editor): pakjes en credits geven aan een speler op naam
create or replace function public.admin_give_gift(p_name text, p_packs int, p_credits int default 0, p_note text default null) returns text
language plpgsql volatile security definer set search_path = public as $$
declare v_user uuid; v_name text; n int;
begin
  -- enkel vanuit de SQL Editor (geen ingelogde speler) of door de admin
  if auth.uid() is not null and not public._is_admin_user(auth.uid()) then raise exception 'Enkel voor de admin.'; end if;
  select count(*) into n from public.profiles where display_name ilike '%' || p_name || '%';
  if n <> 1 then raise exception 'Ik vond % spelers met "%" in de naam. Maak de naam preciezer.', n, p_name; end if;
  select id, display_name into v_user, v_name from public.profiles where display_name ilike '%' || p_name || '%';
  insert into public.gift_packs (user_id, kind, note)
  select v_user, case when random() < .5 then 'basic' else 'epic' end, p_note from generate_series(1, greatest(0, coalesce(p_packs, 0)));
  if coalesce(p_credits, 0) <> 0 then update public.user_wallet set polycoins = polycoins + p_credits where user_id = v_user; end if;
  return format('%s kreeg %s pakje(s) en %s credits.', v_name, coalesce(p_packs, 0), coalesce(p_credits, 0));
end $$;
revoke all on function public.admin_give_gift(text, int, int, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
