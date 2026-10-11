-- =====================================================================
-- RIZZ ACADEMY — update 17: admin-account om te testen
--
-- 1. Een admin heeft altijd 1.000.000 credits (wordt na elke aankoop of inzet bijgevuld).
-- 2. Een admin kan in de Exam Hall elk spel van het rooster kiezen en zo vaak spelen als hij wil.
--    Voor gewone spelers verandert er niets.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
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
