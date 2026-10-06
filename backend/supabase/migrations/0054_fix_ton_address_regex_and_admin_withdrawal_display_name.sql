-- Pro-X Network — fix TON raw-address regex + add display_name to the
-- admin pending-withdrawals listing.
--
-- This migration touches only two existing functions from
-- 0052_player_wallet_and_withdrawals.sql. It does not add any table,
-- does not change withdrawals_paused / mpxn_to_pxn_rate / any other
-- withdrawal_config value, and does not touch referrals, marketplace,
-- leaderboard, or authentication.
--
-- =====================================================================
-- 1. is_valid_ton_address — the raw-address branch of the regex was
--    `^-?[0-9]:[0-9a-fA-F]{64}$`, which (despite the function's own
--    comment saying "workchain is -1 or 0") actually accepted ANY
--    single digit workchain, negative or not: 1:, 2:, ..., 9:, -0:,
--    -2:, etc. This replaces it with the exact intended set: only
--    "-1:" or "0:". The user-friendly (48-char base64url) branch is
--    unchanged.
-- =====================================================================

create or replace function public.is_valid_ton_address(p_address text)
returns boolean
language sql
immutable
as $$
  -- Two TON address encodings are accepted, format-only:
  --   raw:           <workchain>:<64 hex chars>, workchain is EXACTLY
  --                   -1 or 0 (TON has no other workchains in
  --                   practice) — e.g.
  --                   0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a
  --   user-friendly:  48 base64url characters (with or without -/_ safe
  --                   alphabet), e.g. EQD...48 chars total. This is a
  --                   plain charset+length check, NOT a base64 CRC/
  --                   checksum validation and NOT bounceable-flag
  --                   parsing — sufficient to reject obviously-wrong
  --                   input (wrong chain's address, random text,
  --                   empty string) without claiming more than that.
  select
    p_address is not null
    and (
      p_address ~ '^(?:-1|0):[0-9a-fA-F]{64}$'
      or p_address ~ '^[A-Za-z0-9_-]{48}$'
    );
$$;

comment on function public.is_valid_ton_address(text) is
  'Format-only validation of a TON wallet address (raw -1:<64 hex> or 0:<64 hex>, or 48-char user-friendly base64url). Does NOT verify checksum/CRC and does NOT prove wallet ownership — no signature verification exists in this project (see connect_wallet). Rejects anything that is not shaped like a TON address; does not guarantee the address is live/fundable.';

-- =====================================================================
-- 2. admin_list_pending_withdrawals — adds a canonical display_name
--    column for the admin UI, computed the SAME way as the
--    leaderboard's display_name (0053_leaderboard_display_name.sql):
--    prefer public.user_profiles.display_name, else
--    telegram_username, else telegram_first_name, else 'Player'.
--    Every other column and the admin-authorization check are
--    unchanged from 0052.
-- =====================================================================

create or replace function public.admin_list_pending_withdrawals(
  p_admin_user_id uuid
)
returns table (
  id             uuid,
  user_id        uuid,
  display_name   text,
  wallet_address text,
  wallet_network  text,
  amount_mpxn    numeric(20,8),
  amount_pxn     numeric(20,8),
  status         text,
  created_at      timestamptz
)
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
begin
  if p_admin_user_id is null or not exists (select 1 from public.admin_users where user_id = p_admin_user_id) then
    raise exception 'admin_list_pending_withdrawals: caller is not an admin'
      using errcode = 'PXN61';
  end if;

  return query
    select
      w.id, w.user_id,
      coalesce(
        nullif(up.display_name, ''),
        nullif(u.telegram_username, ''),
        nullif(u.telegram_first_name, ''),
        'Player'
      ) as display_name,
      w.wallet_address, w.wallet_network,
      w.amount_mpxn, w.amount_pxn, w.status, w.created_at
      from public.withdrawals w
      join public.users u on u.id = w.user_id
      left join public.user_profiles up on up.user_id = w.user_id
     where w.status = 'pending'
     order by w.created_at asc;
end;
$$;

revoke all on function public.admin_list_pending_withdrawals(uuid) from public;
revoke all on function public.admin_list_pending_withdrawals(uuid) from anon;
revoke all on function public.admin_list_pending_withdrawals(uuid) from authenticated;
grant execute on function public.admin_list_pending_withdrawals(uuid) to service_role;
