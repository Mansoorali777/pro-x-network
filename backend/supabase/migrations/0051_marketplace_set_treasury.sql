-- Pro-X Network — Marketplace treasury admin setter.
--
-- WHY THIS EXISTS
-- 0032_marketplace_tables.sql seeds public.marketplace_config with
-- fee_recipient_user_id = NULL and states that "an admin path in a later
-- migration is expected to set it". No later migration (0033–0050) does.
-- marketplace_buy_listing and marketplace_accept_offer (0034) therefore
-- raise PXN44 on every call, which marketplace/index.ts maps to
-- MARKETPLACE_MISCONFIGURED.
--
-- WHAT THIS DOES
-- Adds ONE service-role-only function that sets the treasury after
-- validating that the supplied account is usable as a treasury.
-- It contains NO treasury value: the id must be supplied by the
-- operator at call time. It does NOT touch marketplace_buy_listing,
-- marketplace_accept_offer, the PXN44 checks, fee logic, escrow,
-- RLS, or any existing function/table.
--
-- USAGE (Supabase SQL editor, or service_role):
--   select public.admin_set_marketplace_treasury('<TREASURY_USER_ID>');
--
-- The account must already exist in public.users AND have a
-- public.mining_state row (the settlement RPCs lock and credit that
-- row; without it they would fail with PXN25 instead of PXN44).

create or replace function public.admin_set_marketplace_treasury(
  p_treasury_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_banned boolean;
begin
  if p_treasury_user_id is null then
    raise exception 'admin_set_marketplace_treasury: p_treasury_user_id is required'
      using errcode = 'PXN30';
  end if;

  select u.is_banned
    into v_banned
    from public.users as u
   where u.id = p_treasury_user_id;

  if not found then
    raise exception 'admin_set_marketplace_treasury: no users row for %', p_treasury_user_id
      using errcode = 'PXN30';
  end if;

  if v_banned then
    raise exception 'admin_set_marketplace_treasury: user % is banned and cannot be the treasury', p_treasury_user_id
      using errcode = 'PXN30';
  end if;

  perform 1
     from public.mining_state as ms
    where ms.user_id = p_treasury_user_id;

  if not found then
    raise exception 'admin_set_marketplace_treasury: no mining_state row for %', p_treasury_user_id
      using errcode = 'PXN25';
  end if;

  update public.marketplace_config as c
     set fee_recipient_user_id = p_treasury_user_id
   where c.id = true;

  if not found then
    raise exception 'admin_set_marketplace_treasury: marketplace_config is not seeded'
      using errcode = 'PXN44';
  end if;

  return p_treasury_user_id;
end;
$$;

comment on function public.admin_set_marketplace_treasury(uuid) is
  'Service-role-only: sets marketplace_config.fee_recipient_user_id after verifying the user exists, is not banned, and has a mining_state row. Contains no hard-coded id. Not callable by anon/authenticated.';

revoke all on function public.admin_set_marketplace_treasury(uuid) from public;
revoke all on function public.admin_set_marketplace_treasury(uuid) from anon;
revoke all on function public.admin_set_marketplace_treasury(uuid) from authenticated;
grant execute on function public.admin_set_marketplace_treasury(uuid) to service_role;
