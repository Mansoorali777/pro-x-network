-- Pro-X Network — Per-unit Miner Level Upgrade System.
--
-- Context: public.mining_inventory (0014_mining_inventory.sql) already
-- has miner_level (default 1) and miner_speed columns on every owned
-- miner unit, and public.miner_catalog (0021_miner_catalog.sql,
-- 0022_miner_catalog_purchase_source.sql) already provides the
-- server-authoritative Level-1 baseline (mining_speed) and purchase
-- price (price_pxn) for each tier. This migration adds the missing
-- piece: a way for a player to spend PXN to raise ONE owned unit's
-- miner_level, with a new mining_speed computed entirely server-side.
--
-- This migration does NOT touch miner_catalog, mining_config,
-- mining_state's schema, mining_inventory's schema, purchase_miner(),
-- set_miner_applied(), adjust_pxn_balance(), accrue-mining/index.ts,
-- purchase-miner/index.ts, set-miner-applied/index.ts,
-- get-mining-inventory/index.ts, index.html, or admin.html. It adds
-- exactly one new table and one new function.
--
-- Why accrue-mining needs no change: accrue-mining/index.ts computes
-- appliedMinerSpeed as SUM(mining_inventory.miner_speed) over this
-- player's is_applied = true rows, read FRESH from the table on every
-- single call — never cached, never read from a request. Because
-- upgrade_miner() below only ever updates miner_speed in place on the
-- single row being upgraded, an already-applied miner's contribution
-- to the player's mining rate is picked up automatically on the very
-- next accrue-mining call, with no re-apply/remove step required.
--
-- ---------------------------------------------------------------
-- Table: public.miner_upgrade_config
-- ---------------------------------------------------------------
-- A GLOBAL, singleton formula-parameters row (one table, one row —
-- same "server-only config" trust model as mining_config, but a true
-- singleton rather than mining_config's append-only/is_active history
-- pattern, since there is no dispute-audit requirement here and no
-- admin UI is being added in this step). Every numeric value here
-- feeds directly into upgrade cost/speed math inside upgrade_miner()
-- below, so — per the same reasoning as mining_config
-- (0003_mining_config.sql) and miner_catalog's write side
-- (0021_miner_catalog.sql) — NO client role (anon or authenticated)
-- may read or write this table directly. RLS is enabled with zero
-- policies for those roles, which means Postgres denies all access
-- to them by default (including SELECT — the frontend never needs
-- the raw formula, only the resulting numbers upgrade_miner()
-- returns). Only service_role can read or write, since service_role
-- bypasses RLS entirely by design.
--
-- Singleton enforcement: id is an integer primary key constrained to
-- always equal 1, so at most one row can ever exist — a second
-- INSERT would violate the primary key, and there is no code path in
-- this migration or upgrade_miner() that attempts one.

create table public.miner_upgrade_config (
  id                          integer       primary key default 1
                                check (id = 1),

  -- Compounding per-level multiplier applied to a tier's
  -- miner_catalog.mining_speed (the Level-1 baseline) to compute the
  -- speed at any higher level. Approved default: 1.15 (i.e. +15% per
  -- level, compounding).
  speed_multiplier_per_level  numeric(6,4)  not null default 1.1500
                                check (speed_multiplier_per_level > 0),

  -- Fraction of a tier's miner_catalog.price_pxn charged to go from
  -- Level 1 to Level 2. Approved default: 0.50.
  cost_base_factor            numeric(6,4)  not null default 0.5000
                                check (cost_base_factor >= 0),

  -- Compounding per-level multiplier applied to the base upgrade cost
  -- above for each subsequent level. Approved default: 1.35.
  cost_multiplier_per_level   numeric(6,4)  not null default 1.3500
                                check (cost_multiplier_per_level > 0),

  -- Hard ceiling on miner_level. Enforced entirely server-side inside
  -- upgrade_miner() below — never trusted from, or enforceable only
  -- by, the client. Approved default: 50.
  max_level                   integer       not null default 50
                                check (max_level >= 1),

  -- Absolute PXN floor for a single upgrade, regardless of what the
  -- formula above computes — including the price_pxn = 0 case (e.g.
  -- the free starter tier), where the formula alone would otherwise
  -- yield a cost of 0. Approved default: 10.
  min_upgrade_cost            numeric(20,8) not null default 10.00000000
                                check (min_upgrade_cost >= 0),

  updated_at                  timestamptz   not null default now()
);

comment on table public.miner_upgrade_config is
  'Singleton (exactly one row, id = 1), server-only global formula parameters for the per-unit Miner Level Upgrade System. No client role (anon or authenticated) may SELECT, INSERT, UPDATE, or DELETE this table — only service_role, via upgrade_miner() below. Editing this row changes upgrade cost/speed math for every player on their next upgrade; it never retroactively changes any already-upgraded mining_inventory row.';
comment on column public.miner_upgrade_config.speed_multiplier_per_level is
  'Compounding per-level speed multiplier applied to miner_catalog.mining_speed (the Level-1 baseline): speed(level) = mining_speed * speed_multiplier_per_level ^ (level - 1).';
comment on column public.miner_upgrade_config.cost_base_factor is
  'Fraction of miner_catalog.price_pxn charged for the Level 1 -> Level 2 upgrade, before the cost_multiplier_per_level compounding and the min_upgrade_cost floor are applied.';
comment on column public.miner_upgrade_config.cost_multiplier_per_level is
  'Compounding per-level cost multiplier: cost(level -> level+1) = price_pxn * cost_base_factor * cost_multiplier_per_level ^ (level - 1), floored by min_upgrade_cost.';
comment on column public.miner_upgrade_config.max_level is
  'Hard ceiling on mining_inventory.miner_level. upgrade_miner() rejects any attempt to upgrade a unit already at this level.';
comment on column public.miner_upgrade_config.min_upgrade_cost is
  'Absolute PXN floor for a single upgrade. Applies to every tier, including price_pxn = 0 tiers, where the formula alone would otherwise compute a cost of 0.';

-- Reuse the existing shared trigger function from 0001_helpers.sql
-- (public.set_updated_at()) rather than redefining it here — same
-- pattern as mining_inventory (0014) and miner_catalog (0021).
create trigger miner_upgrade_config_set_updated_at
  before update on public.miner_upgrade_config
  for each row execute function public.set_updated_at();

alter table public.miner_upgrade_config enable row level security;

-- Deliberately no policies here. RLS + zero policies for
-- anon/authenticated = default-deny for every operation (including
-- SELECT) on this table for those roles. service_role bypasses RLS
-- as usual and is the only way this table is ever read or written —
-- exclusively from inside upgrade_miner() below.

-- ---- seed: the one and only row, with the approved defaults ----
-- ON CONFLICT makes this idempotent: re-running this migration never
-- errors or duplicates the row, and never silently overwrites a value
-- an operator may have already tuned by then (see DO NOTHING).
insert into public.miner_upgrade_config
  (id, speed_multiplier_per_level, cost_base_factor, cost_multiplier_per_level, max_level, min_upgrade_cost)
values
  (1, 1.1500, 0.5000, 1.3500, 50, 10.00000000)
on conflict (id) do nothing;

-- ---------------------------------------------------------------
-- Function: public.upgrade_miner(p_user_id uuid, p_inventory_id uuid)
-- ---------------------------------------------------------------
-- Atomic, service-role-only per-unit miner level upgrade. Mirrors the
-- lock-order, atomic-conditional-deduct, and error-code conventions
-- already established by purchase_miner (0016/0017/0022) and
-- set_miner_applied (0018).
--
-- Never accepts miner_level, miner_speed, or any cost/price from the
-- caller — the ONLY inputs are which player (p_user_id, always from
-- the calling Edge Function's auth.getUser(), never the request body)
-- and which owned unit (p_inventory_id). Every number used in the
-- upgrade — current level, base speed, base price, and every
-- miner_upgrade_config parameter — is read server-side from tables no
-- client role can write.
--
-- Lock order (matches set_miner_applied exactly, to avoid deadlocking
-- against it or purchase_miner under concurrent load): mining_state
-- row FIRST, then the target mining_inventory row SECOND. Both locks
-- are held for the remainder of the transaction, so a double-click or
-- genuinely concurrent upgrade_miner call for the same player and/or
-- the same inventory row queues behind this one rather than racing
-- it — there is no window in which two concurrent calls could both
-- read the same "before" pxn_balance or the same "before" miner_level
-- and both succeed against stale data.
--
-- Formula (approved):
--   next_level  = current miner_level + 1
--   new_speed   = miner_catalog.mining_speed * speed_multiplier_per_level ^ (next_level - 1)
--   base_cost   = miner_catalog.price_pxn * cost_base_factor * cost_multiplier_per_level ^ (current_level - 1)
--   cost        = greatest(base_cost, min_upgrade_cost)   -- applies even when price_pxn = 0
--
-- miner_catalog.mining_speed is read ONLY as the Level-1 baseline
-- input to the formula above — this function never writes to
-- miner_catalog, and does not require the tier's is_active flag to be
-- true (an already-owned unit of a since-retired tier must remain
-- upgradeable, exactly as it remains usable/applicable today — see
-- 0021_miner_catalog.sql's is_active comment).
--
-- Error codes (continuing the existing PXN sequence — PXN01-PXN11 are
-- purchase_miner/set_miner_applied, PXN12-PXN14 are
-- admin_set_mining_speed/admin_clear_mining_speed_override, see
-- 0016/0017/0018/0020/0022):
--   PXN15 — invalid input (p_user_id or p_inventory_id is null)   -> 400
--   PXN16 — no mining_state row for this player                  -> 404
--   PXN17 — inventory row not found, or does not belong to
--           p_user_id (both cases reported identically, so a
--           foreign/mismatched id can never be distinguished from
--           a nonexistent one)                                    -> 404
--   PXN18 — miner_catalog has no row for this unit's miner_tier
--           (defensive only — should be unreachable for a unit that
--           was purchased through purchase_miner, since that path
--           requires the tier to exist; kept as a loud failure
--           instead of a silent wrong charge if that ever changes)  -> 500
--   PXN19 — this unit is already at max_level                     -> 400
--   PXN20 — insufficient PXN balance for the computed cost         -> 400

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
  v_base_price      numeric(20,8);
  v_speed_mult      numeric(6,4);
  v_cost_base       numeric(6,4);
  v_cost_mult       numeric(6,4);
  v_max_level       integer;
  v_min_cost        numeric(20,8);
  v_next_level      integer;
  v_new_speed       numeric(20,8);
  v_cost            numeric(20,8);
  v_new_balance     numeric(20,8);
begin
  -- ---------------------------------------------------------------
  -- 1. Validate inputs. Never trust the shape of any parameter —
  --    this is a defense-in-depth check even though the calling Edge
  --    Function also validates before invoking this RPC.
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
  --    set_miner_applied (0018), so a concurrent upgrade_miner,
  --    set_miner_applied, or purchase_miner call for the same player
  --    queues behind this one rather than deadlocking against it.
  --    This lock is held for the rest of the transaction.
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
  -- 3. Lock the target inventory row SECOND, scoped to p_user_id so
  --    a mismatched/foreign inventory id can never be locked or
  --    touched regardless of what p_user_id was passed. This single
  --    statement both verifies ownership and reads the current
  --    tier/level in one round trip.
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
  -- 4. Read the tier's Level-1 baseline speed and price directly
  --    from miner_catalog. Read-only: this function never writes to
  --    miner_catalog. is_active is intentionally NOT checked here —
  --    a unit already owned from a since-retired tier must remain
  --    upgradeable, exactly as it remains applicable/usable today.
  -- ---------------------------------------------------------------
  select mc.mining_speed, mc.price_pxn
    into v_base_speed, v_base_price
    from public.miner_catalog as mc
   where mc.miner_tier = v_current_tier
   limit 1;

  if not found then
    raise exception 'upgrade_miner: no miner_catalog row for miner_tier % (inventory %)', v_current_tier, p_inventory_id
      using errcode = 'PXN18';
  end if;

  -- ---------------------------------------------------------------
  -- 5. Load the (singleton) upgrade formula parameters. Not locked
  --    with FOR UPDATE: this is a read-only, effectively-constant
  --    config row, not a value this transaction contends over —
  --    the security-critical state (pxn_balance, miner_level) is
  --    protected by the row locks taken above and below, not by
  --    this read.
  -- ---------------------------------------------------------------
  select c.speed_multiplier_per_level, c.cost_base_factor, c.cost_multiplier_per_level,
         c.max_level, c.min_upgrade_cost
    into v_speed_mult, v_cost_base, v_cost_mult, v_max_level, v_min_cost
    from public.miner_upgrade_config as c
   where c.id = 1;

  if not found then
    raise exception 'upgrade_miner: miner_upgrade_config is not seeded'
      using errcode = 'PXN18';
  end if;

  -- ---------------------------------------------------------------
  -- 6. Reject if this unit is already at the configured max level.
  -- ---------------------------------------------------------------
  if v_current_level >= v_max_level then
    raise exception 'upgrade_miner: inventory item % is already at max level % (user_id %)',
      p_inventory_id, v_max_level, p_user_id
      using errcode = 'PXN19';
  end if;

  -- ---------------------------------------------------------------
  -- 7. Compute the next level, the new speed, and the cost — all
  --    server-side, from server-only inputs (the locked inventory
  --    row's current miner_level, miner_catalog's mining_speed /
  --    price_pxn, and miner_upgrade_config's parameters). Never a
  --    client-supplied value of any kind.
  --
  --    new_speed = miner_catalog.mining_speed * speed_multiplier_per_level ^ (next_level - 1)
  --    cost      = greatest(price_pxn * cost_base_factor * cost_multiplier_per_level ^ (current_level - 1),
  --                          min_upgrade_cost)
  --    The greatest(...) floor applies unconditionally, including
  --    when price_pxn = 0 (e.g. the free starter tier), per the
  --    approved design.
  -- ---------------------------------------------------------------
  v_next_level := v_current_level + 1;
  v_new_speed  := v_base_speed * power(v_speed_mult, v_next_level - 1);
  v_cost       := greatest(
                    v_base_price * v_cost_base * power(v_cost_mult, v_current_level - 1),
                    v_min_cost
                  );

  -- ---------------------------------------------------------------
  -- 8. Atomically deduct PXN, but ONLY if the (already row-locked,
  --    via step 2) current balance covers the cost. If it doesn't,
  --    zero rows match and `not found` below is raised — no partial
  --    deduction is possible, and the existing pxn_balance >= 0
  --    CHECK constraints (0013_mining_state.sql,
  --    0015_pxn_balance_security.sql) remain a second, independent
  --    guard against going negative. Same pattern as purchase_miner.
  -- ---------------------------------------------------------------
  update public.mining_state as ms
     set pxn_balance = ms.pxn_balance - v_cost
   where ms.user_id = p_user_id
     and ms.pxn_balance >= v_cost
  returning ms.pxn_balance into v_new_balance;

  if not found then
    raise exception 'upgrade_miner: insufficient PXN balance for user_id % (inventory %, cost %)',
      p_user_id, p_inventory_id, v_cost
      using errcode = 'PXN20';
  end if;

  -- ---------------------------------------------------------------
  -- 9. Update ONLY this single inventory row's miner_level and
  --    miner_speed. Scoped to both id and user_id, exactly like the
  --    lock in step 3, so no other row — this player's or anyone
  --    else's — can ever be touched by this statement. Any failure
  --    here (e.g. a future constraint violation) raises an exception
  --    that unwinds this entire function, rolling back the PXN
  --    deduction above along with it.
  -- ---------------------------------------------------------------
  update public.mining_inventory as mi
     set miner_level = v_next_level,
         miner_speed = v_new_speed
   where mi.id = p_inventory_id
     and mi.user_id = p_user_id;

  -- ---------------------------------------------------------------
  -- 10. Return the updated row plus the new authoritative balance
  --     and the cost actually charged. is_applied is read back
  --     as-is (never modified by this function) — if the unit was
  --     already applied, it stays applied, and accrue-mining will
  --     pick up its new miner_speed on the very next call (see the
  --     header comment above for why no re-apply step is needed).
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
  'Atomic, service-role-only per-unit miner level upgrade. Locks mining_state then the target mining_inventory row (same order as set_miner_applied), verifies ownership, computes next_level/new miner_speed/cost entirely server-side from miner_catalog.mining_speed/price_pxn (Level-1 baseline) and the singleton miner_upgrade_config row, deducts pxn_balance only if sufficient, and updates ONLY that inventory row''s miner_level and miner_speed. Never accepts level, speed, or cost from the caller. Never modifies miner_catalog, mining_config, or any other mining_inventory row. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Same pattern as
-- 0015/0016/0017/0018/0020/0022.
revoke all on function public.upgrade_miner(uuid, uuid) from public;
revoke all on function public.upgrade_miner(uuid, uuid) from anon;
revoke all on function public.upgrade_miner(uuid, uuid) from authenticated;
grant execute on function public.upgrade_miner(uuid, uuid) to service_role;

-- No existing table schema (miner_catalog, mining_config,
-- mining_state, mining_inventory) is altered by this migration. No
-- existing RLS policy is added, removed, or modified. No existing
-- function (purchase_miner, set_miner_applied, adjust_pxn_balance,
-- set_updated_at) is touched. No existing Edge Function or frontend
-- file is modified, and no grant to anon/authenticated is introduced.
