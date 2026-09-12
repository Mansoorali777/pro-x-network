-- Pro-X Network — Switch purchase_miner() from PXN to m.PXN.
--
-- Function: public.purchase_miner(p_user_id uuid, p_miner_tier integer)
-- (signature UNCHANGED from 0016_secure_miner_purchase.sql /
-- 0017_fix_purchase_miner_created_at.sql / 0022_miner_catalog_purchase_source.sql).
--
-- Context: the game's pre-launch economy is migrating spending from
-- PXN (the future blockchain token, held in
-- public.mining_state.pxn_balance) to m.PXN (the in-game currency).
-- m.PXN's spendable balance is public.mining_state.claimed_total —
-- the amount a player has already claimed via public.claim_mining
-- (see 0027_secure_mpxn_claim.sql). PXN itself is locked/Coming Soon
-- until token launch. This migration is the purchase-side half of
-- that migration: it changes WHICH mining_state column
-- purchase_miner reads and deducts from. It changes nothing else.
--
-- ONLY the balance column changes, from pxn_balance to claimed_total.
-- Every other piece of 0022's purchase_miner is carried over
-- unchanged:
--   - Input validation (p_user_id / p_miner_tier null/range checks,
--     PXN04) — unchanged.
--   - The live public.miner_catalog lookup by miner_tier, requiring
--     the row to exist AND be is_active (PXN01 otherwise) —
--     unchanged. miner_name, miner_icon, mining_speed, and
--     price_pxn are still read from miner_catalog exactly as in
--     0022; price_pxn is still the source of v_cost (miner_catalog's
--     own column name is untouched by this migration — only what
--     mining_state column that cost is deducted FROM changes).
--   - The mining_state existence check + `for update` row lock
--     (PXN03), taken BEFORE any deduction — unchanged. This is also
--     the sole purchase-side duplicate/ownership protection: the
--     lock is scoped to `user_id = p_user_id`, so a purchase can only
--     ever read or deduct the caller's own row, and two concurrent
--     purchase_miner calls for the same player serialize behind this
--     lock rather than racing each other.
--   - The balance-deducting UPDATE's WHERE-clause re-check against
--     the CURRENT locked row value (not a value read earlier) — same
--     lost-update protection as before (PXN02 on insufficient
--     balance) — unchanged in structure, only the column changes.
--   - The mining_inventory INSERT ... RETURNING, in the SAME
--     transaction/single rollback boundary as the deduction — a
--     failure here still unwinds the balance UPDATE too. Multiple
--     units of the same tier remain explicitly allowed (no
--     uniqueness check against p_miner_tier), consistent with
--     0014_mining_inventory.sql.
--   - The `returns table (...)` shape, including every output column
--     name — unchanged, byte-for-byte, from 0022. Only what VALUE is
--     placed into `new_pxn_balance` changes (see below).
--   - `language plpgsql security definer set search_path = public,
--     pg_temp` — unchanged.
--   - The `revoke ... from public/anon/authenticated` +
--     `grant execute ... to service_role` lines — unchanged;
--     re-asserted below purely for idempotency/defense-in-depth,
--     exactly as 0017 and 0022 already did (CREATE OR REPLACE
--     FUNCTION does not by itself reset previously granted/revoked
--     privileges).
--
-- What's different:
--   - OLD (0022): `update public.mining_state as ms set pxn_balance =
--     ms.pxn_balance - v_cost where ms.user_id = p_user_id and
--     ms.pxn_balance >= v_cost returning ms.pxn_balance into
--     v_new_balance;` — checked and deducted PXN.
--   - NEW: the identical statement shape, but against
--     `claimed_total` instead of `pxn_balance` — checks and deducts
--     m.PXN instead.
--   - IMPORTANT — the `returns table (...)` shape, including the
--     output column name `new_pxn_balance`, is left EXACTLY as it
--     was in 0022. `CREATE OR REPLACE FUNCTION` cannot change an
--     existing function's return type / OUT-parameter list without
--     dropping and recreating the function (which would require
--     coordinating a DROP across every caller), so this migration
--     deliberately keeps that column name unchanged. As of this
--     migration, `new_pxn_balance` is a legacy name only: the value
--     it carries is the player's new `claimed_total` (m.PXN) after
--     this purchase, NOT `pxn_balance`, which this function no
--     longer reads or writes at all. Any future migration that finally
--     renames this column would need to DROP FUNCTION first (a
--     breaking, coordinated change) — out of scope here.
--
-- Untouched by this migration:
--   - public.mining_state.pxn_balance — no longer read or written by
--     purchase_miner at all after this migration. Column, its
--     `>= 0` CHECK constraint, and every other function/Edge
--     Function that touches it (adjust_pxn_balance,
--     0015_pxn_balance_security.sql) are unaffected.
--   - public.mining_state.mined_balance_total — never read or
--     written by purchase_miner, before or after this migration.
--   - public.mining_state.pending_claim — never read or written by
--     purchase_miner, before or after this migration. (It is
--     exclusively written by accrue-mining and zeroed by
--     public.claim_mining — see 0027_secure_mpxn_claim.sql — neither
--     of which this migration touches.)
--   - public.mining_state schema — no ALTER TABLE of any kind. No
--     new column, no new constraint, no new trigger.
--   - public.miner_catalog — table, schema, RLS, and seed data
--     untouched. purchase_miner still reads it exactly as 0022 left
--     it (miner_name, miner_icon, mining_speed, price_pxn, is_active
--     gating).
--   - public.mining_inventory — schema untouched. Same columns
--     written, in the same way, as 0022.
--   - public.mining_config — already unread by purchase_miner since
--     0022; still untouched here.
--   - 0016, 0017, 0021, and 0022 — none of those migration files are
--     modified. This migration only adds a new CREATE OR REPLACE of
--     the same function, which supersedes 0022's function body at
--     the database level going forward.
--   - claim-mining, accrue-mining, set-miner-applied,
--     admin-set-mining-speed, admin-miner-catalog, auth-telegram, and
--     every frontend file (index.html, admin.html) — none referenced
--     or modified by this migration.
--
-- Error codes: no new SQLSTATE is introduced and none change meaning.
--   PXN01 — unknown/inactive miner tier in miner_catalog   -> 404
--   PXN02 — insufficient m.PXN (claimed_total) balance for
--           this purchase                                  -> 400
--   PXN03 — no mining_state row exists for this user yet   -> 404
--   PXN04 — invalid input (null user id, or miner tier not
--           an integer >= 1)                                -> 400
--   PXN05 — malformed miner_catalog row (server
--           misconfiguration)                                -> 500

create or replace function public.purchase_miner(
  p_user_id     uuid,
  p_miner_tier  integer
)
returns table (
  inventory_id     uuid,
  miner_tier       integer,
  miner_name       text,
  miner_icon       text,
  miner_level      integer,
  miner_speed      numeric(20,8),
  is_applied       boolean,
  created_at       timestamptz,
  updated_at       timestamptz,
  new_pxn_balance  numeric(20,8)
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_catalog_id    uuid;
  v_is_active     boolean;
  v_name          text;
  v_icon          text;
  v_speed         numeric(20,8);
  v_cost          numeric(20,8);
  v_new_balance   numeric(20,8);
  v_inventory_id  uuid;
  v_created_at    timestamptz;
  v_updated_at    timestamptz;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate inputs. Never trust p_miner_tier's shape — this is
  --    a defense-in-depth check even though the Edge Function also
  --    validates it before calling this RPC. UNCHANGED from
  --    0016/0017/0022.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'purchase_miner: p_user_id is required'
      using errcode = 'PXN04';
  end if;

  if p_miner_tier is null or p_miner_tier < 1 then
    raise exception 'purchase_miner: p_miner_tier must be an integer >= 1'
      using errcode = 'PXN04';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Load the requested tier directly from public.miner_catalog
  --    (see 0021_miner_catalog.sql) — one row per tier, unique on
  --    miner_tier. UNCHANGED from 0022: still the live catalog
  --    source for miner_name, miner_icon, mining_speed, and
  --    price_pxn. This function is SECURITY DEFINER, so it can read
  --    miner_catalog regardless of that table's RLS policy.
  -- ---------------------------------------------------------------
  select mc.id, mc.is_active, mc.miner_name, mc.miner_icon, mc.mining_speed, mc.price_pxn
    into v_catalog_id, v_is_active, v_name, v_icon, v_speed, v_cost
    from public.miner_catalog mc
   where mc.miner_tier = p_miner_tier
   limit 1;

  -- A miner must exist for this tier AND be currently active.
  -- UNCHANGED from 0022.
  if not found or v_is_active is not true then
    raise exception 'purchase_miner: unknown or inactive miner tier %', p_miner_tier
      using errcode = 'PXN01';
  end if;

  -- Defense in depth: miner_catalog's miner_name/miner_icon/
  -- price_pxn/mining_speed columns are all NOT NULL by constraint
  -- (0021_miner_catalog.sql), so this should be unreachable for a
  -- row that was just found — kept as a loud failure instead of a
  -- silent wrong charge if that ever stops being true. UNCHANGED
  -- from 0022.
  if v_name is null or v_icon is null or v_speed is null or v_cost is null then
    raise exception 'purchase_miner: catalog entry for tier % is malformed (miner_catalog id %)', p_miner_tier, v_catalog_id
      using errcode = 'PXN05';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Verify the player's mining_state row exists BEFORE
  --    attempting any deduction, and take a row lock on it for the
  --    remainder of this transaction so a concurrent purchase_miner
  --    call for the same player queues behind this one rather than
  --    racing it. This lock — scoped to `user_id = p_user_id` — is
  --    also what guarantees a purchase can only ever affect the
  --    caller's own row (ownership protection). UNCHANGED from
  --    0016/0017/0022.
  -- ---------------------------------------------------------------
  perform 1
    from public.mining_state ms
   where ms.user_id = p_user_id
     for update;

  if not found then
    raise exception 'purchase_miner: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN03';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Atomically deduct m.PXN (public.mining_state.claimed_total),
  --    but ONLY if the (now row-locked) current balance covers the
  --    cost. If it doesn't, zero rows match and `not found` below is
  --    raised — no partial deduction is possible.
  --
  --    THE CHANGE: this statement targets `claimed_total` instead of
  --    `pxn_balance` (0016/0017/0022). Everything else about this
  --    statement — the row lock already held, the live re-check of
  --    the current balance in the WHERE clause (not a value read
  --    earlier, so no lost-update race is possible), and the
  --    `returning ... into v_new_balance` capture — is unchanged in
  --    structure.
  --
  --    mined_balance_total and pending_claim are not referenced by
  --    this statement or anywhere else in this function.
  --    pxn_balance is likewise not referenced anywhere in this
  --    function after this migration.
  -- ---------------------------------------------------------------
  --    v_new_balance is named generically because it is returned
  --    below under the RETURNS TABLE's legacy `new_pxn_balance`
  --    column — its actual contents are the player's new
  --    claimed_total (m.PXN), never pxn_balance.
  update public.mining_state as ms
     set claimed_total = ms.claimed_total - v_cost
   where ms.user_id = p_user_id
     and ms.claimed_total >= v_cost
  returning ms.claimed_total into v_new_balance;

  if not found then
    raise exception 'purchase_miner: insufficient m.PXN balance for user_id % (miner tier %, cost %)',
      p_user_id, p_miner_tier, v_cost
      using errcode = 'PXN02';
  end if;

  -- ---------------------------------------------------------------
  -- 5. Insert the purchased unit in the SAME transaction. Any
  --    failure here (e.g. a future constraint violation) raises an
  --    exception that unwinds this entire function, rolling back the
  --    m.PXN deduction above along with it — the single-transaction/
  --    single-rollback-boundary atomicity guarantee is preserved
  --    exactly as in 0016/0017/0022. UNCHANGED, including the `mi`
  --    alias + qualified RETURNING list from 0017's ambiguity fix.
  -- ---------------------------------------------------------------
  insert into public.mining_inventory as mi (
    user_id, miner_tier, miner_name, miner_icon, miner_level, miner_speed, is_applied
  ) values (
    p_user_id, p_miner_tier, v_name, v_icon, 1, v_speed, false
  )
  returning mi.id, mi.created_at, mi.updated_at
    into v_inventory_id, v_created_at, v_updated_at;

  return query
    select
      v_inventory_id,
      p_miner_tier,
      v_name,
      v_icon,
      1,
      v_speed,
      false,
      v_created_at,
      v_updated_at,
      v_new_balance;
end;
$$;

comment on function public.purchase_miner(uuid, integer) is
  'Atomic, service-role-only miner purchase: looks up the requested tier in public.miner_catalog (must exist and be is_active), deducts m.PXN (mining_state.claimed_total) only if sufficient, and inserts the purchased unit into mining_inventory — all in one transaction. Never trusts price/speed/name/icon from the caller. Never reads or writes pxn_balance, mined_balance_total, or pending_claim. Not callable by anon/authenticated. (0028: purchase currency switched from PXN (pxn_balance) to m.PXN (claimed_total); the RETURNS TABLE output column is still named new_pxn_balance for signature compatibility, but its value is now the new claimed_total, not pxn_balance. Catalog source, locking, atomicity, validation, and error codes unchanged from 0022.)';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Re-asserted here — unchanged from
-- 0016/0017/0022 — so this migration is correct and self-contained
-- even if read in isolation.
revoke all on function public.purchase_miner(uuid, integer) from public;
revoke all on function public.purchase_miner(uuid, integer) from anon;
revoke all on function public.purchase_miner(uuid, integer) from authenticated;
grant execute on function public.purchase_miner(uuid, integer) to service_role;

-- No table schema (miner_catalog, mining_config, mining_state,
-- mining_inventory) is altered by this migration — CREATE OR REPLACE
-- FUNCTION only replaces the function body, not any table. No new
-- column is created on any table. No RLS policy is added, removed,
-- or modified. No new Edge Function or frontend file is introduced.
-- No previous migration (0016, 0017, 0021, 0022, or any other) is
-- modified.
