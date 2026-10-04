-- =====================================================================
-- RIZZ ACADEMY — update 03: Seppe wordt admin
-- Voer dit uit NADAT seppe.cottenie@outlook.com een account heeft gemaakt op de site.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> plakken -> Run ("Run without RLS").
-- Veilig om opnieuw uit te voeren. Onderaan zie je of het gelukt is.
-- =====================================================================
insert into public.admins (user_id)
select id from auth.users where lower(email) = 'seppe.cottenie@outlook.com'
on conflict do nothing;

-- Controle: hier hoort 1 rij met je e-mailadres te verschijnen
select u.email, 'admin' as rol
from public.admins a join auth.users u on u.id = a.user_id;
