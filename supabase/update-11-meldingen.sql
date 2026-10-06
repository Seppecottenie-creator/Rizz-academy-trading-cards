-- =====================================================================
-- RIZZ ACADEMY — update 11: pushmeldingen (herinnering voor het dagelijkse examen)
--
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
