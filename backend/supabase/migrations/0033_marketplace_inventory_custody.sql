-- Pro-X Network — Marketplace listing custody protection for mining_inventory.
--
-- Column: public.mining_inventory.is_listed boolean NOT NULL DEFAULT false.
--
-- Context: 0032_marketplace_tables.sql added the (still-inert)
-- marketplace_listings / marketplace_offers / marketplace_config
-- tables. marketplace_listings.mining_inventory_id already references
-- public.mining_inventory(id) on delete cascade, and a partial unique
-- index (marketplace_listings_one_active_per_item) already guarantees
-- at most one ACTIVE listing per inventory row at the database level.
-- What's still missing — and what this migration adds — is CUSTODY:
-- once a specific owned miner unit is listed for sale, the existing
-- gameplay write paths (apply/remove, upgrade) must refuse to touch
-- it, so a seller cannot upgrade or re-slot a miner out from under a
-- listing (or its price/speed) while it is on the marketplace.
--
-- This migration adds exactly one column (is_listed) and one partial
-- index to public.mining_inventory, then re-defines (CREATE OR
-- REPLACE, same signatures and same RETURNS TABLE shapes) the two
-- existing gameplay RPCs that mutate a mining_inventory row in place:
--   - public.set_miner_applied(uuid, uuid, boolean) — 0018, unchanged
--     since.
--   - public.upgrade_miner(uuid, uuid) — 0025/0026, currency-switched
--     to m.PXN by 0029, unchanged since.
-- Both now reject with a new, distinct SQLSTATE the moment they find
-- is_listed = true on the target row, BEFORE any lock upgrade, slot
-- count, cost computation, or balance deduction happens. Every other
-- line of both functions' bodies — validation, lock order
-- (mining_state row first, then the target mining_inventory row),
-- the applied-slot-limit math, the m.PXN (claimed_total) deduction
-- formula and floor, the miner_upgrade_costs lookup, and every
-- existing SQLSTATE (PXN06-PXN11, PXN15-PXN21) — is carried over
-- byte-for-byte from the current (0018 / 0029) definitions. Both
-- functions' `returns table (...)` column lists, `language plpgsql
-- security definer set search_path = public, pg_temp`, and
-- `revoke ... / grant execute ... to service_role` lines are likewise
-- unchanged, so the existing set-miner-applied and upgrade-miner Edge
-- Functions remain wire-compatible with no changes required.
--
-- Who can set is_listed: nobody yet, and never the client. This
-- migration does NOT add any INSERT/UPDATE/DELETE policy for anon or
-- authenticated on mining_inventory — the existing
-- "mining_inventory_select_own" SELECT-only policy (0014) is
-- untouched, so is_listed becomes visible to a player reading their
-- own inventory row but remains just as unwritable by that role as
-- every other column on this table (miner_tier, miner_level,
-- miner_speed, is_applied, ...). is_listed defaults to false and is
-- left at false by every function in this migration; it will only
-- ever be flipped to true/false by the later, still-unbuilt,
-- service-role-only Marketplace list/cancel/buy/accept-offer RPCs
-- (0034+), exactly as marketplace_listings/marketplace_offers'
-- header comment (0032) already describes for those tables. No
-- marketplace RPC of any kind is created by this migration.
--
-- New SQLSTATE (continuing the existing PXN01-PXN28 sequence):
--   PXN29 — the targeted mining_inventory row has is_listed = true,
--           so it cannot be applied/removed (set_miner_applied) or
--           upgraded (upgrade_miner) while listed on the
--           marketplace                                       -> 409
--
-- Untouched by this migration:
--   - m.PXN / PXN separation: upgrade_miner still reads and deducts
--     ONLY mining_state.claimed_total (m.PXN), exactly as 0029 left
--     it. pxn_balance is not read, written, or referenced anywhere in
--     this migration.
--   - purchase_miner(), claim_mining(), level_up_mining(),
--     adjust_claimed_total(), adjust_pxn_balance(), set_updated_at() —
--     none of these functions are touched.
--   - public.mining_inventory's existing columns, constraints,
--     triggers, and the two existing indexes
--     (mining_inventory_user_id_idx,
--     mining_inventory_user_id_is_applied_idx) — untouched; this
--     migration only ADDs a column and a new partial index.
--   - public.marketplace_listings, public.marketplace_offers,
--     public.marketplace_config (0032) — schema, RLS, and seed data
--     untouched. No marketplace RPC (list/offer/accept/cancel/buy) is
--     created here.
--   - index.html, js/api-client.js, js/auth-client.js, admin.html,
--     and every existing Edge Function — none referenced or modified
--     by this SQL migration.
--
-- Safety on an existing database: ADD COLUMN ... NOT NULL DEFAULT
-- false backfills every pre-existing mining_inventory row with
-- is_listed = false in the same statement (Postgres materializes the
-- default for existing rows), so no separate UPDATE/backfill step is
-- needed and no existing row's ownership, miner_level, miner_speed,
-- is_applied, or timestamps are read or modified by this migration.

-- ---------------------------------------------------------------
-- 1. Column: public.mining_inventory.is_listed
-- ---------------------------------------------------------------
alter table public.mining_inventory
  add column is_listed boolean not null default false;

comment on column public.mining_inventory.is_listed is
  'Marketplace custody flag: true while this owned miner unit has an active marketplace listing. Server-authoritative and NOT directly writable by anon/authenticated (no INSERT/UPDATE/DELETE policy grants that) — only later service-role-only Marketplace RPCs (0034+) may set or clear it. While true, set_miner_applied() and upgrade_miner() both reject any operation against this row with SQLSTATE PXN29.';

-- ---------------------------------------------------------------
-- 2. Index: marketplace custody lookups.
-- ---------------------------------------------------------------
-- Partial index on is_listed = true: the only query pattern this
-- column needs to serve efficiently is "find the currently-listed
-- rows" (e.g. the later Marketplace RPCs re-checking custody, or an
-- admin/ops lookup) — most rows will have is_listed = false, so an
-- unqualified index over the whole table would mostly index a value
-- nobody looks up. Mirrors the existing partial-index convention
-- already used by marketplace_listings_active_idx (0032) and
-- mining_inventory_user_id_is_applied_idx's own composite-index
-- reasoning (0014).
create index mining_inventory_is_listed_idx
  on public.mining_inventory (is_listed)
  where is_listed = true;

-- ---------------------------------------------------------------
-- 3. Function: public.set_miner_applied(uuid, uuid, boolean)
-- ---------------------------------------------------------------
-- Identical to the current (0018) definition, with exactly one
-- addition: immediately after the target inventory row is locked
-- (and its current is_applied value read), a new check rejects with
-- PXN29 if that row's is_listed is true — before any applied-slot
-- counting, config read, or UPDATE happens. Signature, RETURNS TABLE
-- shape, every other validation/lock/error path (PXN06-PXN11), and
-- the revoke/grant lines are all unchanged from 0018.
create or replace function public.set_miner_applied(
  p_user_id       uuid,
  p_inventory_id  uuid,
  p_is_applied    boolean
)
returns table (
  id            uuid,
  user_id       uuid,
  miner_tier    integer,
  miner_name    text,
  miner_icon    text,
  miner_level   integer,
  miner_speed   numeric(20,8),
  is_applied    boolean,
  created_at    timestamptz,
  updated_at    timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_level          integer;
  v_max_slots      integer;
  v_applied_count  integer;
  v_current        boolean;
  v_is_listed      boolean;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate inputs. Never trust the shape of any parameter —
  --    this is a defense-in-depth check even though the (future)
  --    Edge Function also validates before calling this RPC.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'set_miner_applied: p_user_id is required'
      using errcode = 'PXN06';
  end if;

  if p_inventory_id is null then
    raise exception 'set_miner_applied: p_inventory_id is required'
      using errcode = 'PXN06';
  end if;

  if p_is_applied is null then
    raise exception 'set_miner_applied: p_is_applied is required'
      using errcode = 'PXN06';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the player's mining_state row and read their Mining
  --    Level. This lock is held for the rest of the transaction, so
  --    every concurrent set_miner_applied call for this same
  --    p_user_id queues behind this one rather than racing it —
  --    the same pattern purchase_miner (0016/0017) uses to guard
  --    pxn_balance.
  -- ---------------------------------------------------------------
  select ms.level
    into v_level
    from public.mining_state as ms
   where ms.user_id = p_user_id
     for update;

  if not found then
    raise exception 'set_miner_applied: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN07';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Lock the target inventory row, scoped to p_user_id so a
  --    mismatched/foreign inventory id can never be locked or
  --    touched, regardless of what p_user_id was passed.
  -- ---------------------------------------------------------------
  select mi.is_applied, mi.is_listed
    into v_current, v_is_listed
    from public.mining_inventory as mi
   where mi.id = p_inventory_id
     and mi.user_id = p_user_id
     for update;

  if not found then
    raise exception 'set_miner_applied: inventory item % not found for user_id %', p_inventory_id, p_user_id
      using errcode = 'PXN08';
  end if;

  -- ---------------------------------------------------------------
  -- 3a. Marketplace custody guard (new in this migration). A miner
  --     currently listed on the marketplace cannot be applied or
  --     removed — checked immediately after the row lock above, and
  --     before any slot-count read or state mutation below.
  -- ---------------------------------------------------------------
  if v_is_listed then
    raise exception 'set_miner_applied: inventory item % is currently listed on the marketplace and cannot be applied or removed', p_inventory_id
      using errcode = 'PXN29';
  end if;

  -- ---------------------------------------------------------------
  -- 4a. Applying a miner.
  -- ---------------------------------------------------------------
  if p_is_applied then

    if v_current then
      raise exception 'set_miner_applied: inventory item % is already applied', p_inventory_id
        using errcode = 'PXN09';
    end if;

    -- Player Mining Level -> max applied slots. Driven solely by
    -- mining_state.level (the player's Mining Level), never by
    -- mining_inventory.miner_level (the per-unit miner level) and
    -- never by any client-supplied slot count.
    v_max_slots := case
      when v_level >= 15 then 3
      when v_level >= 5  then 2
      else 1
    end;

    select count(*)
      into v_applied_count
      from public.mining_inventory as mi
     where mi.user_id = p_user_id
       and mi.is_applied;

    if v_applied_count >= v_max_slots then
      raise exception 'set_miner_applied: applied slots full for user_id % (level %, max %, applied %)',
        p_user_id, v_level, v_max_slots, v_applied_count
        using errcode = 'PXN11';
    end if;

    update public.mining_inventory as mi
       set is_applied = true
     where mi.id = p_inventory_id
       and mi.user_id = p_user_id;

  -- ---------------------------------------------------------------
  -- 4b. Removing a miner.
  -- ---------------------------------------------------------------
  else

    if not v_current then
      raise exception 'set_miner_applied: inventory item % is already removed', p_inventory_id
        using errcode = 'PXN10';
    end if;

    update public.mining_inventory as mi
       set is_applied = false
     where mi.id = p_inventory_id
       and mi.user_id = p_user_id;

  end if;

  -- ---------------------------------------------------------------
  -- 5. Return the updated row. No inventory row is ever deleted, no
  --    pxn_balance/mining balance column is read or written here.
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
      mi.updated_at
      from public.mining_inventory as mi
     where mi.id = p_inventory_id
       and mi.user_id = p_user_id;
end;
$$;

comment on function public.set_miner_applied(uuid, uuid, boolean) is
  'Service-role-only apply/remove of an owned miner unit. Verifies the inventory row belongs to p_user_id, rejects with PXN29 if the row is currently listed on the marketplace (is_listed = true) before any other state change, and when applying, enforces the player''s max-applied-slots limit derived from mining_state.level (1-4 => 1 slot, 5-14 => 2 slots, 15+ => 3 slots) entirely server-side. Locks the player''s mining_state row and the target mining_inventory row to prevent concurrent apply/remove races. Never deletes rows, never touches pxn_balance or any mining balance. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created/replaced functions to
-- PUBLIC by default — revoke that immediately, then grant only to the
-- role Edge Functions actually run as. Unchanged from 0018.
revoke all on function public.set_miner_applied(uuid, uuid, boolean) from public;
revoke all on function public.set_miner_applied(uuid, uuid, boolean) from anon;
revoke all on function public.set_miner_applied(uuid, uuid, boolean) from authenticated;
grant execute on function public.set_miner_applied(uuid, uuid, boolean) to service_role;

-- ---------------------------------------------------------------
-- 4. Function: public.upgrade_miner(uuid, uuid)
-- ---------------------------------------------------------------
-- Identical to the current (0029, m.PXN/claimed_total) definition,
-- with exactly one addition: immediately after the target inventory
-- row is locked (and its current miner_tier/miner_level read), a new
-- check rejects with PXN29 if that row's is_listed is true — before
-- the miner_catalog lookup, the miner_upgrade_config read, the
-- max-level check, the miner_upgrade_costs lookup, or the m.PXN
-- deduction. Signature, RETURNS TABLE shape (including the legacy
-- new_pxn_balance/pxn_cost output column names — see 0029's header
-- comment for why those names are kept), the claimed_total-based
-- deduction, every other validation/lock/error path
-- (PXN15-PXN21), and the revoke/grant lines are all unchanged from
-- 0029.
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
  v_is_listed       boolean;
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
  --    from 0025/0026/0029.
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
  --    set_miner_applied (0018) and 0025/0026/0029's upgrade_miner,
  --    so a concurrent upgrade_miner, set_miner_applied, or
  --    purchase_miner call for the same player queues behind this
  --    one rather than deadlocking against it. Held for the rest of
  --    the transaction. UNCHANGED from 0025/0026/0029.
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
  --    and reads the current tier/level (and, new in this migration,
  --    is_listed) in one round trip. UNCHANGED in structure from
  --    0025/0026/0029 aside from also reading is_listed.
  -- ---------------------------------------------------------------
  select mi.miner_tier, mi.miner_level, mi.is_listed
    into v_current_tier, v_current_level, v_is_listed
    from public.mining_inventory as mi
   where mi.id = p_inventory_id
     and mi.user_id = p_user_id
     for update;

  if not found then
    raise exception 'upgrade_miner: inventory item % not found for user_id %', p_inventory_id, p_user_id
      using errcode = 'PXN17';
  end if;

  -- ---------------------------------------------------------------
  -- 3a. Marketplace custody guard (new in this migration). A miner
  --     currently listed on the marketplace cannot be upgraded —
  --     checked immediately after the row lock above, and before the
  --     miner_catalog lookup, the max-level check, the
  --     miner_upgrade_costs lookup, or any m.PXN deduction.
  -- ---------------------------------------------------------------
  if v_is_listed then
    raise exception 'upgrade_miner: inventory item % is currently listed on the marketplace and cannot be upgraded', p_inventory_id
      using errcode = 'PXN29';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Read the tier's Level-1 baseline speed from miner_catalog.
  --    Read-only, and NOT gated on is_active — an already-owned unit
  --    of a since-retired tier must remain upgradeable, exactly as
  --    in 0025/0026/0029. price_pxn is not read here: cost comes
  --    exclusively from miner_upgrade_costs (step 6 below). UNCHANGED
  --    from 0029.
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
  --    with FOR UPDATE — same reasoning as 0025/0026/0029 (read-only,
  --    effectively-constant config; the security-critical state is
  --    protected by the row locks taken above and below). UNCHANGED
  --    from 0029.
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
  --    UNCHANGED from 0025/0026/0029.
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
  --    outright rather than guessing. UNCHANGED from 0026/0029.
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
  -- 8. Compute the new speed — unchanged from 0025/0026/0029 —
  --    entirely server-side from server-only inputs (the locked
  --    inventory row's current miner_level, miner_catalog.mining_speed,
  --    and miner_upgrade_config.speed_multiplier_per_level). Never a
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
  --    independent guard against going negative. UNCHANGED from 0029
  --    — this migration does not touch pxn_balance, mined_balance_total,
  --    or pending_claim anywhere.
  -- ---------------------------------------------------------------
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
  --     UNCHANGED from 0025/0026/0029. is_listed is never written by
  --     this function.
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
  --     0025/0026/0029.
  --
  --     new_pxn_balance (legacy output name) carries claimed_total
  --     (m.PXN). pxn_cost (legacy-shaped output name) carries the
  --     m.PXN amount charged. See 0029's header comment.
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
  'Atomic, service-role-only per-unit miner level upgrade. Locks mining_state then the target mining_inventory row (same order as set_miner_applied), verifies ownership, rejects with PXN29 if the row is currently listed on the marketplace (is_listed = true) before any cost/state work, reads the EXACT admin-configured cost for (current_level -> current_level+1) from public.miner_upgrade_costs (no formula fallback — a missing row fails the upgrade), computes the new miner_speed from miner_catalog.mining_speed and miner_upgrade_config.speed_multiplier_per_level, deducts m.PXN (mining_state.claimed_total) only if sufficient, and updates ONLY that inventory row''s miner_level and miner_speed. Never accepts level, speed, cost, or is_listed from the caller. Never reads or writes pxn_balance, mined_balance_total, or pending_claim. (0033: added the marketplace custody guard (PXN29); currency, locking, atomicity, cost source, and every other error code unchanged from 0029.) Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created/replaced functions to
-- PUBLIC by default — revoke that immediately, then grant only to the
-- role Edge Functions actually run as. Re-asserted here — unchanged
-- from every prior migration in this sequence — so this migration is
-- correct and self-contained even if read in isolation.
revoke all on function public.upgrade_miner(uuid, uuid) from public;
revoke all on function public.upgrade_miner(uuid, uuid) from anon;
revoke all on function public.upgrade_miner(uuid, uuid) from authenticated;
grant execute on function public.upgrade_miner(uuid, uuid) to service_role;

-- ---------------------------------------------------------------
-- No INSERT/UPDATE/DELETE policy is added, removed, or modified on
-- public.mining_inventory (or any other table) by this migration —
-- the existing "mining_inventory_select_own" SELECT-only policy
-- (0014) is untouched, so is_listed remains readable-by-owner and
-- unwritable by anon/authenticated, exactly like every other column
-- on this table. No marketplace RPC (list/offer/accept/cancel/buy) is
-- created here — those remain a later migration, exactly as
-- 0032_marketplace_tables.sql's own header describes. purchase_miner,
-- claim_mining, level_up_mining, adjust_claimed_total,
-- adjust_pxn_balance, and set_updated_at are not touched. The m.PXN
-- (mining_state.claimed_total) / PXN (mining_state.pxn_balance)
-- separation established by 0027-0031 is unchanged: this migration
-- reads and deducts claimed_total only, exactly as 0029 already did,
-- and never references pxn_balance. index.html and
-- js/api-client.js are not modified.
-- ---------------------------------------------------------------
