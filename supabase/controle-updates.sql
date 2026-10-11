-- =====================================================================
-- RIZZ ACADEMY — controle: welke updates heb je al uitgevoerd?
-- Verandert niets, leest enkel. Supabase -> SQL Editor -> plakken -> Run.
-- In de kolom "gedaan": true = in orde, false = dit nog doen.
-- =====================================================================
select 'update-07-rooster-admin.sql' as stap,
       to_regprocedure('public._is_admin_user(uuid)') is not null as gedaan
union all
select 'update-08-vrienden.sql',
       to_regprocedure('public.friends_overview()') is not null
union all
select 'update-09-moeilijker.sql',
       coalesce((public._exam_rules('darts'))[2] = 360, false)
union all
select 'update-10-accounts-vrijgeven.sql (niemand wacht nog op een bevestigingsmail)',
       case when exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'email_confirmed_at')
            then (xpath('/row/c/text()', query_to_xml('select count(*) as c from auth.users where email_confirmed_at is null', false, true, '')))[1]::text = '0'
            else false end
union all
select 'update-11-meldingen.sql',
       to_regclass('public.push_subscriptions') is not null and exists (select 1 from pg_extension where extname = 'pg_cron')
union all
select 'update-12-tegenstander-fotos.sql',
       to_regprocedure('public._card_in_my_battle(integer)') is not null
union all
select 'update-13-casino.sql',
       to_regprocedure('public.casino_status()') is not null
union all
select 'update-14-casino-zonder-limiet.sql',
       coalesce((select prosrc not like '%lost_today%' from pg_proc where oid = to_regprocedure('public._casino_take(integer)')), false)
union all
select 'update-15-ideeen.sql',
       to_regprocedure('public.touch_presence(boolean)') is not null
union all
select 'update-16-vrij-ruilen.sql',
       coalesce((select prosrc like '%niet genoeg exemplaren%' from pg_proc where oid = to_regprocedure('public.create_trade(uuid,integer[],integer[])')), false)
union all
select 'update-17-admin-test.sql',
       to_regclass('public.admin_exam_choice') is not null
union all
select 'update-18-testlogboek.sql',
       to_regclass('public.admin_play_log') is not null
union all
select 'update-19-spelletjes-bijgesteld.sql',
       coalesce((public._exam_rules('math'))[4] = 20, false)
union all
select 'update-20-pintje.sql',
       to_regprocedure('public.buy_beer()') is not null
union all
select 'update-21-pintje-random.sql',
       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'beer_state' and column_name = 'limit_n')
union all
select 'update-22-blackjack-split.sql',
       to_regprocedure('public._bj_next(public.casino_bj)') is not null
union all
select 'Edge Function rizz-push (werkt zodra iemand meldingen aanzette)',
       case when to_regclass('public.push_config') is null then false
            else (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.push_config', false, true, '')))[1]::text <> '0' end;
