-- Pro-X Network — Server-Authoritative Mining Level Up.
--
-- Function: public.level_up_mining(p_user_id uuid, p_request_id uuid).
--
-- Context: Mining Level ("mining_state.level") already drives a real
-- server-side effect — accrue-mining/index.ts (levelBoostMultiplier(),
-- lines ~163-200) already reads it to compute mining rate, and
-- set_miner_applied (0018_secure_miner_apply_remove.sql) already
-- reads it to size the applied-miner slot limit. Only the INCREMENT
-- has been client-only until now: index.html's levelUp() (frontend
-- step, not this migration) locally does `state.level += 1` and
-- locally deducted state.pxnBalance -= cost, with nothing server-side
-- ever validating or recording either change. This migration closes
-- that gap by making the increment (and its cost) a single atomic,
-- server-side operation — the same trust model claim_mining
-- (0027), purchase_miner (0028), and upgrade_miner (0029) already
-- apply to their own balance changes.
--
-- Currency: costs and deducts m.PXN (mining_state.claimed_total),
-- via adjust_claimed_total() (0030_mpxn_ledger_primitive.sql). NEVER
-- reads or writes pxn_balance — that ledger is untouched by this
-- migration and by everything built on top of it.
--
-- Cost source: mining_config.level_up_cost_pxn (already exists —
-- 0003_mining_config.sql — and already matches index.html's
-- REWARDS_CONFIG.levelUpCostPxn = 100). This migration does not add,
-- rename, or alter that column; it only reads it, the same read-only
-- relationship accrue-mining already has with mining_config.
--
-- Max level: 200, fixed. mining_state.level has no upper CHECK
-- constraint today (0013_mining_state.sql only enforces `>= 1`) — this
-- migration does not add one at the table level (a table-level CHECK
-- would also have to account for any future admin-granted level, and
-- there is no such path today) and instead enforces the cap here, in
-- the single function that is allowed to increment level. A player
-- already at level 200 is rejected with PXN28 BEFORE any m.PXN is
-- read or deducted — the balance check and the deduction never run
-- for a maxed-out player.
--
-- Idempotency: p_request_id is a client-generated uuid (index.html
-- generates one per level-up attempt — see the frontend wiring step).
-- This function records it as the mpxn_ledger idempotency key
-- (reason='level_up', ref_type='level_up_request', ref_id=p_request_id
-- — see mpxn_ledger_idempotency_key, 0030_mpxn_ledger_primitive.sql).
-- Before doing any work, this function checks for a ledger row already
-- matching that key:
--   - If one exists, this call is a retry of an already-completed
--     level-up (e.g. a dropped response after the server-side commit
--     succeeded). Nothing is deducted or incremented again — the
--     function returns the player's CURRENT level/claimed_total
--     as a success response, so a retrying client always gets back a
--     valid, honest snapshot rather than an error for work that
--     already happened.
--   - If none exists, this is treated as a new attempt, and
--     adjust_claimed_total()'s own unique-index enforcement is the
--     final, race-free backstop if two requests with the same
--     p_request_id somehow reach the database concurrently (the
--     up-front check above is an optimization to avoid unnecessary
--     work on the common retry case, not the sole safety mechanism).
--
-- Concurrency: the player's mining_state row is locked (SELECT ... FOR
-- UPDATE) before level/claimed_total are read, for the remainder of
-- the transaction — same pattern as every other mining_state writer.
-- adjust_claimed_total() re-acquires the same row lock internally
-- (already held by this same transaction, so this does not deadlock
-- or block on itself) before it applies the deduction, so the level
-- increment and the m.PXN deduction below are part of one atomic
-- transaction: either both happen, or neither does.
--
-- Trust model: p_user_id is the Edge Function's job (level-up-mining/
-- index.ts, later step) to obtain from the caller's verified Supabase
-- access token (auth.getUser()) and pass through — never read from
-- the request body. p_request_id is the only other input, and is
-- opaque (never interpreted as anything other than an idempotency
-- key) — it carries no balance, level, or cost information; those are
-- always read from mining_config/mining_state server-side.
--
-- Custom SQLSTATEs used by this function (continuing the existing
-- PXN01-PXN26 sequence):
--   PXN25 — no mining_state row for this user_id (reused from 0030;
--           same meaning)                                          -> 404
--   PXN26 — invalid input, OR this exact (user_id, request_id) was
--           already processed and raced past the up-front idempotency
--           check into adjust_claimed_total() itself (reused from
--           0030; same meaning — see the note above on why the
--           up-front check handles the common case and this is the
--           race-free backstop)                                    -> 409
--   PXN24 — insufficient m.PXN for the configured cost (reused from
--           0030; raised by adjust_claimed_total())                 -> 400
--   PXN27 — no active mining_config row                             -> 500
--   PXN28 — player is already at the maximum level (200)            -> 400

create or replace function public.level_up_mining(
  p_user_id    uuid,
  p_request_id uuid
)
returns table (
  new_level      integer,
  mpxn_cost      numeric(20,8),
  claimed_total  numeric(20,8)
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_level          integer;
  v_claimed_total  numeric(20,8);
  v_cost           numeric(12,2);
  v_existing       public.mpxn_ledger%rowtype;
  v_new_balance    numeric(20,8);
begin
  -- ---------------------------------------------------------------
  -- 1. Validate input. Defense in depth even though the (later)
  --    level-up-mining Edge Function also validates before calling
  --    this RPC.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'level_up_mining: p_user_id is required'
      using errcode = 'PXN26';
  end if;

  if p_request_id is null then
    raise exception 'level_up_mining: p_request_id is required'
      using errcode = 'PXN26';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Idempotency fast path. If this exact request_id already
  --    produced a level_up ledger row for this user, this call is a
  --    retry — return the player's current state without touching
  --    level or claimed_total again. See the header note above for
  --    why this is an optimization, not the sole guard.
  -- ---------------------------------------------------------------
  select *
    into v_existing
    from public.mpxn_ledger
   where user_id  = p_user_id
     and reason    = 'level_up'
     and ref_type  = 'level_up_request'
     and ref_id    = p_request_id;

  if found then
    select ms.level, ms.claimed_total
      into v_level, v_claimed_total
      from public.mining_state as ms
     where ms.user_id = p_user_id;

    if not found then
      raise exception 'level_up_mining: no mining_state row for user_id %', p_user_id
        using errcode = 'PXN25';
    end if;

    return query
      select v_level, abs(v_existing.delta), v_claimed_total;
    return;
  end if;

  -- ---------------------------------------------------------------
  -- 3. Lock the player's mining_state row for the remainder of the
  --    transaction, and read the current level/claimed_total under
  --    that lock.
  -- ---------------------------------------------------------------
  select ms.level, ms.claimed_total
    into v_level, v_claimed_total
    from public.mining_state as ms
   where ms.user_id = p_user_id
     for update;

  if not found then
    raise exception 'level_up_mining: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN25';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Enforce the fixed level cap BEFORE reading cost or deducting
  --    anything. A maxed-out player's m.PXN is never touched.
  -- ---------------------------------------------------------------
  if v_level >= 200 then
    raise exception 'level_up_mining: user_id % is already at the maximum level (200)', p_user_id
      using errcode = 'PXN28';
  end if;

  -- ---------------------------------------------------------------
  -- 5. Read the configured cost from the single active mining_config
  --    row. Read-only — this function never writes mining_config,
  --    same relationship accrue-mining already has with it.
  -- ---------------------------------------------------------------
  select mc.level_up_cost_pxn
    into v_cost
    from public.mining_config as mc
   where mc.is_active;

  if not found then
    raise exception 'level_up_mining: no active mining_config row'
      using errcode = 'PXN27';
  end if;

  -- ---------------------------------------------------------------
  -- 6. Deduct the cost atomically via the shared m.PXN primitive.
  --    This call:
  --      - re-locks the same, already-locked mining_state row (safe,
  --        same transaction — does not block or deadlock on itself),
  --      - rejects with PXN24 if claimed_total < v_cost, leaving
  --        level and claimed_total both untouched,
  --      - records the mpxn_ledger row keyed to (user_id,
  --        'level_up', 'level_up_request', p_request_id), which is
  --        both this function's audit trail AND the race-free
  --        idempotency backstop referenced in step 2's comment,
  --      - rejects with PXN26 if that ledger row already exists
  --        (a request that raced past step 2's check).
  -- ---------------------------------------------------------------
  v_new_balance := public.adjust_claimed_total(
    p_user_id,
    -v_cost,
    'level_up',
    'level_up_request',
    p_request_id
  );

  -- ---------------------------------------------------------------
  -- 7. Increment level. Only reached if step 6 succeeded, so the
  --    deduction and the increment are both part of this single
  --    transaction — either both commit, or (on any exception above)
  --    neither does. updated_at is advanced by the existing
  --    mining_state_set_updated_at trigger (0013_mining_state.sql) —
  --    no duplicate trigger is created.
  -- ---------------------------------------------------------------
  update public.mining_state as ms
     set level = ms.level + 1
   where ms.user_id = p_user_id;

  return query
    select v_level + 1, v_cost::numeric(20,8), v_new_balance;
end;
$$;

comment on function public.level_up_mining(uuid, uuid) is
  'Service-role-only, atomic Mining Level Up. Locks mining_state, rejects at the fixed level cap of 200 before touching any balance (PXN28), reads the configured cost from the active mining_config row (PXN27 if none), deducts m.PXN (mining_state.claimed_total) via adjust_claimed_total() (PXN24 if insufficient), and increments mining_state.level — all in one transaction. Idempotent on (user_id, p_request_id): a retried call for a request_id that already succeeded returns the current level/claimed_total without deducting or incrementing again, backstopped by mpxn_ledger''s unique index for the race case. Never reads or writes pxn_balance, pending_claim, mined_balance_total, or any mining_inventory row. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Same pattern as every other
-- service-role-only function in this schema.
revoke all on function public.level_up_mining(uuid, uuid) from public;
revoke all on function public.level_up_mining(uuid, uuid) from anon;
revoke all on function public.level_up_mining(uuid, uuid) from authenticated;
grant execute on function public.level_up_mining(uuid, uuid) to service_role;

-- ---------------------------------------------------------------
-- No table schema (mining_state, mining_config, mpxn_ledger, or any
-- other table) is altered by this migration. No RLS policy is added,
-- removed, or modified. No existing function (claim_mining,
-- purchase_miner, upgrade_miner, set_miner_applied,
-- adjust_pxn_balance, adjust_claimed_total, set_updated_at) is
-- touched — adjust_claimed_total is called, not redefined. Nothing
-- calls level_up_mining yet; the level-up-mining Edge Function
-- (later step) is the first caller. index.html's levelUp() continues
-- to work exactly as it does today (locally, against pxnBalance)
-- until that Edge Function and its frontend wiring are deployed —
-- see the plan's deployment-order step 4.
-- ---------------------------------------------------------------
