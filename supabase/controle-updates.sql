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
select 'Edge Function rizz-push (werkt zodra iemand meldingen aanzette)',
       case when to_regclass('public.push_config') is null then false
            else (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.push_config', false, true, '')))[1]::text <> '0' end;
