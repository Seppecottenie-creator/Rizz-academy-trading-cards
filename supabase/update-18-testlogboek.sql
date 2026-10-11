-- =====================================================================
-- RIZZ ACADEMY — update 18: testlogboek voor de admin + Beer Pong op zaterdag
--
-- 1. Elke keer dat een admin een examen afwerkt, wordt de score bewaard in admin_play_log
--    (ook als je daarna opnieuw begint). Bekijk ze met controle-spelletjes.sql.
-- 2. Zaterdag: Darts wordt Beer Pong.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren. Voer eerst update-17-admin-test.sql uit.
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
