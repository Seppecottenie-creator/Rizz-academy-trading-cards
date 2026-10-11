-- =====================================================================
-- RIZZ ACADEMY — update 16: vrij ruilen in de Black Market
--
-- Je kiest zelf wat je aanbiedt en vraagt, ook kaarten waarvan je er maar één hebt
-- (bv. 2 commons voor 1 epic). De andere moet het voorstel nog altijd accepteren.
-- Het inruilen in The Vault (commons voor een epic) verdwijnt weer.
--
-- Gebruik: Supabase -> SQL Editor -> nieuwe query -> dit VOLLEDIGE bestand plakken -> Run.
-- Kies bij de waarschuwing "Run without RLS".
-- Veilig om opnieuw uit te voeren.
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
