-- Pro-X Network — Secure Claim m.PXN.
--
-- Function: public.claim_mining(p_user_id uuid).
--
-- Context: 0013_mining_state.sql created pending_claim / claimed_total
-- / claim_count as schema-only columns; accrue-mining/index.ts (later
-- step) is the only place that increments pending_claim. This
-- migration is the write path that moves an already-accrued
-- pending_claim into claimed_total ("claiming"). It does NOT touch
-- mining_config, mining_inventory, or any column of mining_state
-- other than pending_claim, claimed_total, claim_count, and
-- updated_at (via the existing trigger). It does NOT alter the
-- mining_state schema, does NOT create a new table or balance
-- column, does NOT touch pxn_balance (the separate, future
-- blockchain-token ledger), and does NOT implement swap, marketplace,
-- or blockchain functionality of any kind.
--
-- Ledger semantics (unchanged by this migration — see architecture
-- report / 0013_mining_state.sql):
--   mined_balance_total — lifetime total ever mined. NEVER decreased.
--   pending_claim        — accrued m.PXN waiting to be claimed.
--   claimed_total         — spendable m.PXN after claiming.
--   pxn_balance            — separate PXN token balance. NEVER touched here.
--   claim_count             — number of successful claims.
--
-- Trust model: p_user_id is the ONLY input. It is never trusted as a
-- client-authenticated identity by this function in isolation — it
-- is the Edge Function's job (claim-mining/index.ts) to obtain it
-- from the caller's verified Supabase access token (auth.getUser())
-- and pass it through, never to read it from the request body. This
-- RPC additionally scopes every read/lock/update to
-- `user_id = p_user_id`, so even a caller who somehow supplied a
-- mismatched p_user_id can never touch another player's row — the
-- same belt-and-suspenders pattern used by purchase_miner
-- (0016/0017) and set_miner_applied (0018).
--
-- Concurrency: the player's mining_state row is locked (SELECT ...
-- FOR UPDATE) before pending_claim/claimed_total/claim_count are
-- read, for the entire remainder of the transaction. Two simultaneous
-- claim_mining calls for the same p_user_id therefore serialize
-- behind that lock — the second call only proceeds once the first
-- has committed pending_claim = 0, so it observes pending_claim <= 0
-- and is rejected rather than claiming the same amount twice.
--
-- Custom SQLSTATEs (5-char, distinguishable by the calling Edge
-- Function so it can return the right HTTP status without parsing
-- error text):
--   PXN22 — invalid input (null p_user_id)                  -> 400
--   PXN23 — no mining_state row for this user, or nothing
--           available to claim (pending_claim <= 0)          -> 409

create or replace function public.claim_mining(
  p_user_id uuid
)
returns table (
  user_id         uuid,
  claimed_amount  numeric(20,8),
  pending_claim   numeric(20,8),
  claimed_total   numeric(20,8),
  claim_count     integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pending_claim  numeric(20,8);
  v_claimed_total  numeric(20,8);
  v_claim_count    integer;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate input. Defense in depth even though the (future)
  --    Edge Function also validates before calling this RPC.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'claim_mining: p_user_id is required'
      using errcode = 'PXN22';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the player's mining_state row and read the current
  --    claim-related balances. This lock is held for the rest of
  --    the transaction, so a second concurrent claim_mining call
  --    for this same p_user_id queues behind this one instead of
  --    racing it — the same pattern purchase_miner (0016/0017) and
  --    set_miner_applied (0018) use to guard their own balances.
  -- ---------------------------------------------------------------
  select ms.pending_claim, ms.claimed_total, ms.claim_count
    into v_pending_claim, v_claimed_total, v_claim_count
    from public.mining_state as ms
   where ms.user_id = p_user_id
     for update;

  if not found then
    raise exception 'claim_mining: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN23';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Nothing to claim.
  -- ---------------------------------------------------------------
  if v_pending_claim <= 0 then
    raise exception 'claim_mining: nothing to claim for user_id %', p_user_id
      using errcode = 'PXN23';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Move the entire pending amount into claimed_total, zero out
  --    pending_claim, and increment claim_count. mined_balance_total
  --    and pxn_balance are never read or written here. updated_at is
  --    advanced by the existing mining_state_set_updated_at trigger
  --    (0013_mining_state.sql) — no duplicate trigger is created.
  -- ---------------------------------------------------------------
  update public.mining_state as ms
     set claimed_total = ms.claimed_total + ms.pending_claim,
         pending_claim = 0,
         claim_count   = ms.claim_count + 1
   where ms.user_id = p_user_id;

  -- ---------------------------------------------------------------
  -- 5. Return the server-authoritative result. claimed_amount is the
  --    amount just moved (the pending_claim value read/locked in
  --    step 2, before it was zeroed), independent of any rounding
  --    concerns since numeric(20,8) is used throughout.
  -- ---------------------------------------------------------------
  return query
    select
      p_user_id,
      v_pending_claim,
      0::numeric(20,8),
      v_claimed_total + v_pending_claim,
      v_claim_count + 1;
end;
$$;

comment on function public.claim_mining(uuid) is
  'Service-role-only claim of a player''s accrued pending_claim into claimed_total. Locks the player''s mining_state row for the duration of the transaction to prevent double-claiming from concurrent requests. Rejects with PXN23 when pending_claim <= 0 or no mining_state row exists. Never reads or writes mined_balance_total or pxn_balance. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Same pattern as
-- 0015_pxn_balance_security.sql / 0016_secure_miner_purchase.sql /
-- 0018_secure_miner_apply_remove.sql.
revoke all on function public.claim_mining(uuid) from public;
revoke all on function public.claim_mining(uuid) from anon;
revoke all on function public.claim_mining(uuid) from authenticated;
grant execute on function public.claim_mining(uuid) to service_role;

-- No table schema (mining_state or any other table) is altered by
-- this migration. No RLS policy is added, removed, or modified. No
-- existing function (purchase_miner, set_miner_applied,
-- adjust_pxn_balance, set_updated_at) is touched. No new table, no
-- new balance column, no new Edge Function migration, and no grant
-- to anon/authenticated is introduced.
