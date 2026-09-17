-- Pro-X Network — Admin-controlled Miner Level Upgrade costs.
--
-- Context: 0025_miner_upgrade_system.sql introduced upgrade_miner()
-- and computed each upgrade's PXN cost on the fly from a formula
-- (miner_catalog.price_pxn * miner_upgrade_config.cost_base_factor *
-- miner_upgrade_config.cost_multiplier_per_level ^ (current_level-1),
-- floored by miner_upgrade_config.min_upgrade_cost). That formula is
-- still not admin-editable per level, and it ties every tier's
-- upgrade cost to that tier's purchase price rather than letting an
-- operator set an exact PXN number for "Level 1 -> 2", "Level 2 -> 3",
-- etc. This migration replaces ONLY the cost side of upgrade_miner()
-- with a lookup into a new, explicit, admin-controlled table — one
-- row per (from_level, to_level) pair, holding the exact PXN cost a
-- player is charged for that transition, regardless of miner tier.
--
-- This migration does NOT modify 0025_miner_upgrade_system.sql itself
-- (that file is left byte-for-byte as deployed). It does NOT touch
-- miner_catalog, mining_config, mining_state's schema, mining_inventory's
-- schema, purchase_miner(), set_miner_applied(), adjust_pxn_balance(),
-- accrue-mining/index.ts, purchase-miner/index.ts,
-- set-miner-applied/index.ts, get-mining-inventory/index.ts,
-- upgrade-miner/index.ts, index.html, or the existing Miner
-- Management (miner_catalog) section of admin.html. It adds exactly
-- one new table, one new admin-only Edge Function
-- (admin-miner-upgrade-cost, see that file), a new "Miner Upgrade
-- Cost Management" section of admin.html, and REPLACES the body of
-- public.upgrade_miner(uuid, uuid) — same name, same signature, same
-- return shape — so upgrade-miner/index.ts requires no changes at
-- all: it already forwards whatever public.upgrade_miner returns.
--
-- The miner_speed side of upgrade_miner() is UNCHANGED: new_speed is
-- still computed from miner_catalog.mining_speed (the tier's Level-1
-- baseline) and miner_upgrade_config.speed_multiplier_per_level /
-- max_level, exactly as in 0025. Only the cost side moves from a
-- formula to a table lookup. miner_upgrade_config itself is untouched
-- by this migration — its cost_base_factor / cost_multiplier_per_level
-- / min_upgrade_cost columns simply stop being read by upgrade_miner()
-- from this migration forward (they are still readable/editable by
-- service_role directly if ever needed again, but no longer wired
-- into the upgrade path).
--
-- ---------------------------------------------------------------
-- Table: public.miner_upgrade_costs
-- ---------------------------------------------------------------
-- One row per (from_level, to_level) transition, GLOBAL across every
-- miner tier — the admin sets one PXN number for "Level 1 -> 2" and
-- every player upgrading any tier's unit from Level 1 to Level 2 pays
-- exactly that number. This mirrors the same "server-only config"
-- trust model as miner_upgrade_config (0025) and miner_catalog's
-- write side (0021): no client role (anon or authenticated) may read
-- or write this table directly. RLS is enabled with zero policies for
-- those roles, which means Postgres denies all access to them by
-- default (including SELECT — the frontend never needs the raw cost
-- table, only the single cost number upgrade_miner() charges and
-- returns for the one upgrade it just performed, and the admin panel
-- reads/writes it exclusively through the admin-miner-upgrade-cost
-- Edge Function's service-role client, never a direct client query).
-- Only service_role can read or write, since service_role bypasses
-- RLS entirely by design.
create table public.miner_upgrade_costs (
  id                  uuid          primary key default gen_random_uuid(),

  -- The unit's miner_level BEFORE the upgrade.
  from_level          integer       not null
                        check (from_level >= 1),

  -- The unit's miner_level AFTER the upgrade. Always exactly
  -- from_level + 1 — this table only ever represents single-step
  -- transitions, matching upgrade_miner()'s own next_level :=
  -- current_level + 1 logic. Enforced by a CHECK rather than a
  -- generated column so the constraint is self-documenting in \d
  -- output and in any client that inspects the schema directly.
  to_level            integer       not null
                        check (to_level = from_level + 1),

  -- The exact PXN amount charged for this transition, admin-editable.
  -- Global across every miner tier (see table comment above).
  cost_pxn            numeric(20,8) not null
                        check (cost_pxn >= 0),

  -- The value this row was seeded with (see the seed insert below).
  -- Never modified by admin edits to cost_pxn — this is what "reset
  -- this level to default" (admin-miner-upgrade-cost's "reset"
  -- action) restores cost_pxn to, without needing to recompute the
  -- original formula or read miner_catalog/miner_upgrade_config again
  -- at reset time.
  default_cost_pxn    numeric(20,8) not null
                        check (default_cost_pxn >= 0),

  created_at          timestamptz   not null default now(),
  updated_at          timestamptz   not null default now(),

  constraint miner_upgrade_costs_from_to_key unique (from_level, to_level)
);

comment on table public.miner_upgrade_costs is
  'Admin-controlled, server-only, GLOBAL (not per-tier) table of exact PXN costs for each miner_level -> miner_level+1 transition. No client role (anon or authenticated) may SELECT, INSERT, UPDATE, or DELETE this table — only service_role, via upgrade_miner() (read) and the admin-miner-upgrade-cost Edge Function (read/write). upgrade_miner() treats a missing row for a given (from_level, to_level) as a hard failure (errcode PXN21) rather than falling back to any formula — every reachable level below max_level must have a configured cost.';
comment on column public.miner_upgrade_costs.from_level is
  'The mining_inventory.miner_level value BEFORE the upgrade.';
comment on column public.miner_upgrade_costs.to_level is
  'The mining_inventory.miner_level value AFTER the upgrade. Always from_level + 1.';
comment on column public.miner_upgrade_costs.cost_pxn is
  'Exact PXN amount deducted from the player''s pxn_balance for this transition, regardless of which miner tier is being upgraded. Admin-editable via the admin-miner-upgrade-cost Edge Function only.';
comment on column public.miner_upgrade_costs.default_cost_pxn is
  'The cost_pxn value this row was originally seeded with. Never changed by admin edits — used only to restore cost_pxn via the admin-miner-upgrade-cost Edge Function''s "reset" action.';

create index if not exists miner_upgrade_costs_from_level_idx
  on public.miner_upgrade_costs (from_level);

-- Reuse the existing shared trigger function from 0001_helpers.sql
-- (public.set_updated_at()) rather than redefining it here — same
-- pattern as mining_inventory (0014), miner_catalog (0021), and
-- miner_upgrade_config (0025).
create trigger miner_upgrade_costs_set_updated_at
  before update on public.miner_upgrade_costs
  for each row execute function public.set_updated_at();

alter table public.miner_upgrade_costs enable row level security;

-- Deliberately no policies here. RLS + zero policies for
-- anon/authenticated = default-deny for every operation (including
-- SELECT) on this table for those roles. service_role bypasses RLS
-- as usual and is the only way this table is ever read or written.

-- ---------------------------------------------------------------
-- Seed: default costs for Level 1 -> 2 through Level 49 -> 50.
-- ---------------------------------------------------------------
-- Computed once, at migration time, from the SAME formula shape
-- approved for miner_upgrade_config (0025) — cost = greatest(base *
-- cost_base_factor * cost_multiplier_per_level ^ (from_level - 1),
-- min_upgrade_cost) — using a single representative baseline "base"
-- price of 100 PXN (a round, tier-independent stand-in, since this
-- table is intentionally no longer tier-specific: miner_catalog's
-- actual tier prices range from 0 to 26,000+ PXN, so no single tier's
-- price could serve as "the" baseline for every tier at once). With
-- the approved defaults (cost_base_factor = 0.50,
-- cost_multiplier_per_level = 1.35, min_upgrade_cost = 10), Level
-- 1 -> 2 seeds to exactly 50 PXN. These are starting points only —
-- every value here is immediately admin-editable from the "Miner
-- Upgrade Cost Management" section of admin.html, and upgrade_miner()
-- reads whatever is currently stored, never this formula again.
--
-- ON CONFLICT makes this insert idempotent: re-running this migration
-- never errors or duplicates rows, and never silently overwrites a
-- value an admin may have already tuned by then (see DO NOTHING).
insert into public.miner_upgrade_costs (from_level, to_level, cost_pxn, default_cost_pxn)
select
  lvl as from_level,
  lvl + 1 as to_level,
  greatest(round((100 * 0.50 * power(1.35, lvl - 1))::numeric, 8), 10.00000000) as cost_pxn,
  greatest(round((100 * 0.50 * power(1.35, lvl - 1))::numeric, 8), 10.00000000) as default_cost_pxn
from generate_series(1, 49) as lvl
on conflict (from_level, to_level) do nothing;

-- ---------------------------------------------------------------
-- Function: public.upgrade_miner(p_user_id uuid, p_inventory_id uuid)
-- ---------------------------------------------------------------
-- REPLACES the function body deployed by 0025_miner_upgrade_system.sql
-- (0025's file is left unmodified — this is a new migration issuing
-- `create or replace function` against the same name/signature/return
-- shape). Every guarantee from 0025 is preserved:
--   - Same lock order: mining_state row FIRST, then the target
--     mining_inventory row SECOND.
--   - Same inputs: only p_user_id (always from the calling Edge
--     Function's auth.getUser(), never the request body) and
--     p_inventory_id. Never accepts miner_level, miner_speed, or cost
--     from the caller.
--   - Same ownership/ max-level checks.
--   - Same atomic, conditional PXN deduction (zero rows updated if
--     insufficient balance, no partial deduction possible).
--   - Same single-row-only inventory update, same is_applied
--     preservation, same returned columns.
--
-- What changed: cost is no longer computed from
-- miner_catalog.price_pxn * miner_upgrade_config's cost formula.
-- Instead, the EXACT admin-configured cost for
-- (current_level -> current_level + 1) is read from the new
-- public.miner_upgrade_costs table (this migration, above). If no row
-- exists for that transition, the upgrade is rejected outright
-- (errcode PXN21) rather than falling back to any computed value —
-- an admin-controlled cost table is only trustworthy if a missing row
-- fails loudly instead of silently charging something else.
--
-- new_speed is still computed exactly as in 0025, from
-- miner_catalog.mining_speed (Level-1 baseline) and
-- miner_upgrade_config.speed_multiplier_per_level. max_level is still
-- read from miner_upgrade_config.max_level, unchanged.
--
-- Error codes (continuing the existing PXN sequence; PXN01-PXN11 are
-- purchase_miner/set_miner_applied, PXN12-PXN14 are
-- admin_set_mining_speed/admin_clear_mining_speed_override, PXN15-PXN20
-- are 0025's original upgrade_miner — see that file):
--   PXN15 — invalid input (p_user_id or p_inventory_id is null)   -> 400
--   PXN16 — no mining_state row for this player                  -> 404
--   PXN17 — inventory row not found, or does not belong to
--           p_user_id                                             -> 404
--   PXN18 — miner_catalog has no row for this unit's miner_tier
--           (defensive only, same as 0025)                        -> 500
--   PXN19 — this unit is already at max_level                     -> 400
--   PXN20 — insufficient PXN balance for the configured cost       -> 400
--   PXN21 — NEW: no miner_upgrade_costs row exists for
--           (current_level -> current_level + 1). Defensive/
--           server-misconfiguration only: every level below
--           max_level is seeded by this migration and is expected to
--           stay populated by the admin panel going forward, but a
--           gap must fail loudly rather than silently charge a wrong
--           amount.                                                -> 500

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
  --    set_miner_applied (0018) and 0025's original upgrade_miner, so
  --    a concurrent upgrade_miner, set_miner_applied, or
  --    purchase_miner call for the same player queues behind this one
  --    rather than deadlocking against it. Held for the rest of the
  --    transaction.
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
  --    and reads the current tier/level in one round trip.
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
  --    of a since-retired tier must remain upgradeable, exactly as in
  --    0025. price_pxn is no longer read here: cost now comes
  --    exclusively from miner_upgrade_costs (step 6 below).
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
  --    with FOR UPDATE — same reasoning as 0025 (read-only,
  --    effectively-constant config; the security-critical state is
  --    protected by the row locks taken above and below).
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
  --    there is no formula fallback. A missing row (e.g. an admin
  --    deleted it, or max_level was raised without seeding the new
  --    level) fails the upgrade outright rather than guessing.
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
  -- 8. Compute the new speed — unchanged from 0025 — entirely
  --    server-side from server-only inputs (the locked inventory
  --    row's current miner_level, miner_catalog.mining_speed, and
  --    miner_upgrade_config.speed_multiplier_per_level). Never a
  --    client-supplied value.
  --
  --    new_speed = miner_catalog.mining_speed * speed_multiplier_per_level ^ (next_level - 1)
  -- ---------------------------------------------------------------
  v_new_speed := v_base_speed * power(v_speed_mult, v_next_level - 1);

  -- ---------------------------------------------------------------
  -- 9. Atomically deduct PXN, but ONLY if the (already row-locked,
  --    via step 2) current balance covers the cost. If it doesn't,
  --    zero rows match and `not found` below is raised — no partial
  --    deduction is possible, and the existing pxn_balance >= 0 CHECK
  --    constraints remain a second, independent guard against going
  --    negative. Same pattern as purchase_miner / 0025.
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
  -- 10. Update ONLY this single inventory row's miner_level and
  --     miner_speed. Scoped to both id and user_id, exactly like the
  --     lock in step 3, so no other row — this player's or anyone
  --     else's — can ever be touched by this statement. Any failure
  --     here raises an exception that unwinds this entire function,
  --     rolling back the PXN deduction above along with it.
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
  --     the new miner_speed on its very next call, same as 0025.
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
  'Atomic, service-role-only per-unit miner level upgrade. Locks mining_state then the target mining_inventory row (same order as set_miner_applied), verifies ownership, reads the EXACT admin-configured PXN cost for (current_level -> current_level+1) from public.miner_upgrade_costs (no formula fallback — a missing row fails the upgrade), computes the new miner_speed from miner_catalog.mining_speed and miner_upgrade_config.speed_multiplier_per_level, deducts pxn_balance only if sufficient, and updates ONLY that inventory row''s miner_level and miner_speed. Never accepts level, speed, or cost from the caller. Replaces the cost side of the function body originally deployed by 0025_miner_upgrade_system.sql; 0025''s own file is unmodified. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created/replaced functions to
-- PUBLIC by default — revoke that immediately, then grant only to the
-- role Edge Functions actually run as. Same pattern as
-- 0015/0016/0017/0018/0020/0022/0025.
revoke all on function public.upgrade_miner(uuid, uuid) from public;
revoke all on function public.upgrade_miner(uuid, uuid) from anon;
revoke all on function public.upgrade_miner(uuid, uuid) from authenticated;
grant execute on function public.upgrade_miner(uuid, uuid) to service_role;

-- No existing table schema (miner_catalog, mining_config,
-- mining_state, mining_inventory, miner_upgrade_config) is altered by
-- this migration. No existing RLS policy is added, removed, or
-- modified. No existing function other than upgrade_miner (via
-- create or replace, same signature) is touched. No existing Edge
-- Function or frontend file is modified by this migration, and no
-- grant to anon/authenticated is introduced.
