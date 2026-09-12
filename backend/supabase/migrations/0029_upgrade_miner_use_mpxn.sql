-- Pro-X Network — Switch upgrade_miner() from PXN to m.PXN.
--
-- Function: public.upgrade_miner(p_user_id uuid, p_inventory_id uuid)
-- (signature UNCHANGED from 0025_miner_upgrade_system.sql /
-- 0026_admin_miner_upgrade_costs.sql).
--
-- Context: the game's economy is migrating spending from PXN (the
-- future blockchain/project token, held in
-- public.mining_state.pxn_balance) to m.PXN (the in-game gameplay
-- currency). m.PXN's spendable balance is
-- public.mining_state.claimed_total — the amount a player has
-- already claimed via public.claim_mining (see
-- 0027_secure_mpxn_claim.sql). PXN itself remains a separate,
-- untouched, future currency. This migration is the Miner Upgrade
-- half of that migration (the Miner Store purchase half was already
-- completed by 0028_purchase_miner_use_mpxn.sql for
-- purchase_miner()). It changes WHICH mining_state column
-- upgrade_miner() reads and deducts from. It changes nothing else.
--
-- ONLY the balance column changes, from pxn_balance to claimed_total.
-- Every other piece of 0026's upgrade_miner() is carried over
-- unchanged:
--   - Input validation (p_user_id / p_inventory_id null checks,
--     PXN15) — unchanged.
--   - Lock order: mining_state row FIRST (PXN16 if missing), then
--     the target mining_inventory row SECOND, scoped to p_user_id
--     (PXN17 if not found/not owned) — unchanged. Both locks are
--     held for the remainder of the transaction, exactly as in
--     0025/0026.
--   - The miner_catalog lookup for the tier's Level-1 baseline
--     mining_speed (PXN18 if missing, NOT gated on is_active) —
--     unchanged. price_pxn is still not read here (cost comes
--     exclusively from miner_upgrade_costs, see below) — unchanged
--     from 0026.
--   - The miner_upgrade_config lookup for speed_multiplier_per_level
--     and max_level (PXN18 if not seeded) — unchanged.
--   - The max-level check (PXN19) — unchanged.
--   - The miner_upgrade_costs lookup for the EXACT admin-configured
--     cost of (current_level -> current_level + 1), with no formula
--     fallback (PXN21 if missing) — unchanged.
--   - The new_speed calculation from miner_catalog.mining_speed and
--     miner_upgrade_config.speed_multiplier_per_level — unchanged.
--   - The atomic, conditional balance deduction (zero rows updated,
--     no partial deduction, if the balance is insufficient) —
--     unchanged in structure; ONLY the column changes (see below).
--   - The single-row-only mining_inventory update (miner_level,
--     miner_speed), scoped to both id and user_id — unchanged.
--   - is_applied is read back as-is, never modified here — unchanged.
--   - The `returns table (...)` shape, including every output column
--     name — unchanged, byte-for-byte, from 0025/0026. Only what
--     VALUE is placed into `new_pxn_balance` changes (see below).
--   - `language plpgsql security definer set search_path = public,
--     pg_temp` — unchanged.
--   - The `revoke ... from public/anon/authenticated` +
--     `grant execute ... to service_role` lines — unchanged;
--     re-asserted below purely for idempotency/defense-in-depth,
--     exactly as every prior migration in this sequence has done
--     (CREATE OR REPLACE FUNCTION does not by itself reset
--     previously granted/revoked privileges).
--
-- What's different:
--   - OLD (0025/0026): `update public.mining_state as ms set
--     pxn_balance = ms.pxn_balance - v_cost where ms.user_id =
--     p_user_id and ms.pxn_balance >= v_cost returning
--     ms.pxn_balance into v_new_balance;` — checked and deducted PXN.
--   - NEW: the identical statement shape, but against
--     `claimed_total` instead of `pxn_balance` — checks and deducts
--     m.PXN instead.
--   - IMPORTANT — the `returns table (...)` shape, including the
--     output column names `new_pxn_balance` and `pxn_cost`, is left
--     EXACTLY as it was in 0025/0026. `CREATE OR REPLACE FUNCTION`
--     cannot change an existing function's return type / OUT-parameter
--     list without dropping and recreating the function (which would
--     require coordinating a DROP across every caller — the Edge
--     Function's `.rpc(...)` call, PostgREST's cached function
--     signature, and any concurrent in-flight calls at deploy time),
--     so this migration deliberately keeps both column names
--     unchanged. This is the SAME pattern already used by
--     0028_purchase_miner_use_mpxn.sql for purchase_miner().
--
--     As of this migration:
--       * `new_pxn_balance` is a LEGACY PostgreSQL output column name
--         only — the value it carries is the player's new
--         `claimed_total` (m.PXN) after this upgrade, NOT
--         `pxn_balance`, which this function no longer reads or
--         writes at all. The calling Edge Function
--         (upgrade-miner/index.ts) re-labels this to the honest JSON
--         key `claimed_total` before it ever reaches the frontend —
--         it never forwards it to the client under the name
--         `pxn_balance` or `new_pxn_balance`.
--       * `pxn_cost` is likewise a legacy-shaped name whose value is
--         now the m.PXN amount charged for this upgrade. The Edge
--         Function re-labels this to `mpxn_cost` in its JSON
--         response.
--     Any future migration that finally renames these output columns
--     at the database level would need to DROP FUNCTION first (a
--     breaking, coordinated change) — out of scope here.
--
-- Untouched by this migration:
--   - public.mining_state.pxn_balance — no longer read or written by
--     upgrade_miner() at all after this migration. Column, its
--     `>= 0` CHECK constraint, and every other function/Edge
--     Function that touches it (purchase_miner's own pre-0028
--     history, adjust_pxn_balance, 0015_pxn_balance_security.sql,
--     accrue-mining) are unaffected.
--   - public.mining_state.mined_balance_total — never read or
--     written by upgrade_miner(), before or after this migration.
--   - public.mining_state.pending_claim — never read or written by
--     upgrade_miner(), before or after this migration.
--   - public.mining_state schema — no ALTER TABLE of any kind. No
--     new column, no new constraint, no new trigger. In particular,
--     NO new mPXN/claimed balance column is created — claimed_total
--     already exists and is the spendable m.PXN ledger after
--     claiming (see 0013_mining_state.sql, 0027_secure_mpxn_claim.sql).
--   - public.miner_catalog, public.miner_upgrade_config,
--     public.miner_upgrade_costs — tables, schema, RLS, and seed
--     data untouched. upgrade_miner() still reads them exactly as
--     0026 left it.
--   - public.mining_inventory — schema untouched. Same columns
--     written, in the same way, as 0025/0026.
--   - public.mining_config — already unread by upgrade_miner() since
--     0025; still untouched here.
--   - purchase_miner(), claim_mining(), set_miner_applied(),
--     admin_set_mining_speed(), admin_clear_mining_speed_override() —
--     none of these functions are touched by this migration.
--   - 0025, 0026, 0027, and 0028 — none of those migration files are
--     modified. This migration only adds a new CREATE OR REPLACE of
--     the same function, which supersedes 0026's function body at
--     the database level going forward.
--   - upgrade-miner/index.ts, get-miner-upgrade-costs/index.ts,
--     purchase-miner/index.ts, accrue-mining/index.ts,
--     set-miner-applied/index.ts, admin.html, and index.html — none
--     referenced or modified by this SQL migration (the accompanying
--     Edge Function and frontend changes are separate files, not
--     part of this migration).
--
-- Error codes: no new SQLSTATE is introduced and none change meaning.
--   PXN15 — invalid input (p_user_id or p_inventory_id is null)   -> 400
--   PXN16 — no mining_state row for this player                  -> 404
--   PXN17 — inventory row not found, or does not belong to
--           p_user_id                                             -> 404
--   PXN18 — miner_catalog has no row for this unit's miner_tier,
--           or miner_upgrade_config is not seeded (defensive only)  -> 500
--   PXN19 — this unit is already at max_level                     -> 400
--   PXN20 — insufficient m.PXN (claimed_total) balance for the
--           configured cost                                        -> 400
--   PXN21 — no miner_upgrade_costs row exists for
--           (current_level -> current_level + 1) (defensive/
--           server-misconfiguration only)                          -> 500

create or replace function public.upgrade_miner(
  p_user_id       uuid,
  p_inventory_id  uuid
)
returns table (
  id              uuid,
  user_id         uuid,
  miner_tier      integer,
  miner_name      text,
  miner_icon      text,
  miner_level     integer,
  miner_speed     numeric(20,8),
  is_applied      boolean,
  created_at      timestamptz,
  updated_at      timestamptz,
  new_pxn_balance numeric(20,8),
  pxn_cost        numeric(20,8)
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current_tier    integer;
  v_current_level   integer;
  v_base_speed      numeric(20,8);
  v_speed_mult      numeric(6,4);
  v_max_level       integer;
  v_next_level      integer;
  v_new_speed       numeric(20,8);
  v_cost            numeric(20,8);
  v_new_balance     numeric(20,8);
begin
  -- ---------------------------------------------------------------
  -- 1. Validate inputs. Never trust the shape of any parameter —
  --    this is a defense-in-depth check even though the calling Edge
  --    Function also validates before invoking this RPC. UNCHANGED
  --    from 0025/0026.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'upgrade_miner: p_user_id is required'
      using errcode = 'PXN15';
  end if;

  if p_inventory_id is null then
    raise exception 'upgrade_miner: p_inventory_id is required'
      using errcode = 'PXN15';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the player's mining_state row FIRST — same order as
  --    set_miner_applied (0018) and 0025/0026's upgrade_miner, so a
  --    concurrent upgrade_miner, set_miner_applied, or
  --    purchase_miner call for the same player queues behind this
  --    one rather than deadlocking against it. Held for the rest of
  --    the transaction. UNCHANGED from 0025/0026.
  -- ---------------------------------------------------------------
  perform 1
    from public.mining_state as ms
   where ms.user_id = p_user_id
     for update;

  if not found then
    raise exception 'upgrade_miner: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN16';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Lock the target inventory row SECOND, scoped to p_user_id so a
  --    mismatched/foreign inventory id can never be locked or touched
  --    regardless of what p_user_id was passed. Verifies ownership
  --    and reads the current tier/level in one round trip. UNCHANGED
  --    from 0025/0026.
  -- ---------------------------------------------------------------
  select mi.miner_tier, mi.miner_level
    into v_current_tier, v_current_level
    from public.mining_inventory as mi
   where mi.id = p_inventory_id
     and mi.user_id = p_user_id
     for update;

  if not found then
    raise exception 'upgrade_miner: inventory item % not found for user_id %', p_inventory_id, p_user_id
      using errcode = 'PXN17';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Read the tier's Level-1 baseline speed from miner_catalog.
  --    Read-only, and NOT gated on is_active — an already-owned unit
  --    of a since-retired tier must remain upgradeable, exactly as
  --    in 0025/0026. price_pxn is not read here: cost comes
  --    exclusively from miner_upgrade_costs (step 6 below).
  --    UNCHANGED from 0026.
  -- ---------------------------------------------------------------
  select mc.mining_speed
    into v_base_speed
    from public.miner_catalog as mc
   where mc.miner_tier = v_current_tier
   limit 1;

  if not found then
    raise exception 'upgrade_miner: no miner_catalog row for miner_tier % (inventory %)', v_current_tier, p_inventory_id
      using errcode = 'PXN18';
  end if;

  -- ---------------------------------------------------------------
  -- 5. Load the (singleton) upgrade formula parameters that still
  --    apply: speed_multiplier_per_level and max_level. Not locked
  --    with FOR UPDATE — same reasoning as 0025/0026 (read-only,
  --    effectively-constant config; the security-critical state is
  --    protected by the row locks taken above and below). UNCHANGED
  --    from 0026.
  -- ---------------------------------------------------------------
  select c.speed_multiplier_per_level, c.max_level
    into v_speed_mult, v_max_level
    from public.miner_upgrade_config as c
   where c.id = 1;

  if not found then
    raise exception 'upgrade_miner: miner_upgrade_config is not seeded'
      using errcode = 'PXN18';
  end if;

  -- ---------------------------------------------------------------
  -- 6. Reject if this unit is already at the configured max level.
  --    UNCHANGED from 0025/0026.
  -- ---------------------------------------------------------------
  if v_current_level >= v_max_level then
    raise exception 'upgrade_miner: inventory item % is already at max level % (user_id %)',
      p_inventory_id, v_max_level, p_user_id
      using errcode = 'PXN19';
  end if;

  v_next_level := v_current_level + 1;

  -- ---------------------------------------------------------------
  -- 7. Read the EXACT admin-configured cost for this transition from
  --    public.miner_upgrade_costs. This is the only source of cost —
  --    there is no formula fallback. A missing row fails the upgrade
  --    outright rather than guessing. UNCHANGED from 0026.
  -- ---------------------------------------------------------------
  select uc.cost_pxn
    into v_cost
    from public.miner_upgrade_costs as uc
   where uc.from_level = v_current_level
     and uc.to_level = v_next_level;

  if not found then
    raise exception 'upgrade_miner: no configured upgrade cost for level % -> % (inventory %, user_id %)',
      v_current_level, v_next_level, p_inventory_id, p_user_id
      using errcode = 'PXN21';
  end if;

  -- ---------------------------------------------------------------
  -- 8. Compute the new speed — unchanged from 0025/0026 — entirely
  --    server-side from server-only inputs (the locked inventory
  --    row's current miner_level, miner_catalog.mining_speed, and
  --    miner_upgrade_config.speed_multiplier_per_level). Never a
  --    client-supplied value.
  --
  --    new_speed = miner_catalog.mining_speed * speed_multiplier_per_level ^ (next_level - 1)
  -- ---------------------------------------------------------------
  v_new_speed := v_base_speed * power(v_speed_mult, v_next_level - 1);

  -- ---------------------------------------------------------------
  -- 9. Atomically deduct m.PXN (public.mining_state.claimed_total),
  --    but ONLY if the (already row-locked, via step 2) current
  --    balance covers the cost. If it doesn't, zero rows match and
  --    `not found` below is raised — no partial deduction is
  --    possible, and the existing claimed_total >= 0 CHECK
  --    constraint (0013_mining_state.sql) remains a second,
  --    independent guard against going negative.
  --
  --    THE CHANGE (this migration): this statement targets
  --    `claimed_total` instead of `pxn_balance` (0025/0026).
  --    Everything else about this statement — the row lock already
  --    held, the live re-check of the current balance in the WHERE
  --    clause (not a value read earlier, so no lost-update race is
  --    possible), and the `returning ... into v_new_balance`
  --    capture — is unchanged in structure. Same pattern already
  --    used by 0028_purchase_miner_use_mpxn.sql for purchase_miner().
  --
  --    public.mining_state.pxn_balance is NOT read, deducted,
  --    modified, or depended on anywhere in this function after this
  --    migration. mined_balance_total and pending_claim are likewise
  --    not referenced by this statement or anywhere else in this
  --    function.
  -- ---------------------------------------------------------------
  --    v_new_balance is named generically because it is returned
  --    below under the RETURNS TABLE's legacy `new_pxn_balance`
  --    column (see the header comment above) — its actual contents
  --    are the player's new claimed_total (m.PXN), never pxn_balance.
  update public.mining_state as ms
     set claimed_total = ms.claimed_total - v_cost
   where ms.user_id = p_user_id
     and ms.claimed_total >= v_cost
  returning ms.claimed_total into v_new_balance;

  if not found then
    raise exception 'upgrade_miner: insufficient m.PXN balance for user_id % (inventory %, cost %)',
      p_user_id, p_inventory_id, v_cost
      using errcode = 'PXN20';
  end if;

  -- ---------------------------------------------------------------
  -- 10. Update ONLY this single inventory row's miner_level and
  --     miner_speed. Scoped to both id and user_id, exactly like the
  --     lock in step 3, so no other row — this player's or anyone
  --     else's — can ever be touched by this statement. Any failure
  --     here raises an exception that unwinds this entire function,
  --     rolling back the m.PXN deduction above along with it.
  --     UNCHANGED from 0025/0026.
  -- ---------------------------------------------------------------
  update public.mining_inventory as mi
     set miner_level = v_next_level,
         miner_speed = v_new_speed
   where mi.id = p_inventory_id
     and mi.user_id = p_user_id;

  -- ---------------------------------------------------------------
  -- 11. Return the updated row plus the new authoritative balance and
  --     the cost actually charged. is_applied is read back as-is
  --     (never modified by this function) — accrue-mining picks up
  --     the new miner_speed on its very next call, same as
  --     0025/0026.
  --
  --     new_pxn_balance (legacy output name) now carries
  --     claimed_total (m.PXN). pxn_cost (legacy-shaped output name)
  --     now carries the m.PXN amount charged. See header comment.
  -- ---------------------------------------------------------------
  return query
    select
      mi.id,
      mi.user_id,
      mi.miner_tier,
      mi.miner_name,
      mi.miner_icon,
      mi.miner_level,
      mi.miner_speed,
      mi.is_applied,
      mi.created_at,
      mi.updated_at,
      v_new_balance,
      v_cost
      from public.mining_inventory as mi
     where mi.id = p_inventory_id
       and mi.user_id = p_user_id;
end;
$$;

comment on function public.upgrade_miner(uuid, uuid) is
  'Atomic, service-role-only per-unit miner level upgrade. Locks mining_state then the target mining_inventory row (same order as set_miner_applied), verifies ownership, reads the EXACT admin-configured cost for (current_level -> current_level+1) from public.miner_upgrade_costs (no formula fallback — a missing row fails the upgrade), computes the new miner_speed from miner_catalog.mining_speed and miner_upgrade_config.speed_multiplier_per_level, deducts m.PXN (mining_state.claimed_total) only if sufficient, and updates ONLY that inventory row''s miner_level and miner_speed. Never accepts level, speed, or cost from the caller. Never reads or writes pxn_balance, mined_balance_total, or pending_claim. (0029: upgrade currency switched from PXN (pxn_balance) to m.PXN (claimed_total); the RETURNS TABLE output columns are still named new_pxn_balance and pxn_cost for signature compatibility, but new_pxn_balance now carries the new claimed_total, not pxn_balance. Catalog/cost-table source, locking, atomicity, validation, and error codes unchanged from 0026.) Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created/replaced functions to
-- PUBLIC by default — revoke that immediately, then grant only to the
-- role Edge Functions actually run as. Re-asserted here — unchanged
-- from 0015/0016/0017/0018/0020/0022/0025/0026/0028 — so this
-- migration is correct and self-contained even if read in isolation.
revoke all on function public.upgrade_miner(uuid, uuid) from public;
revoke all on function public.upgrade_miner(uuid, uuid) from anon;
revoke all on function public.upgrade_miner(uuid, uuid) from authenticated;
grant execute on function public.upgrade_miner(uuid, uuid) to service_role;

-- No table schema (miner_catalog, mining_config, mining_state,
-- mining_inventory, miner_upgrade_config, miner_upgrade_costs) is
-- altered by this migration — CREATE OR REPLACE FUNCTION only
-- replaces the function body, not any table. No new column is
-- created on any table (in particular, no new mPXN/claimed balance
-- column — claimed_total already exists and is reused as-is). No RLS
-- policy is added, removed, or modified. No new Edge Function or
-- frontend file is introduced by this SQL migration. No previous
-- migration (0025, 0026, 0027, 0028, or any other) is modified.
