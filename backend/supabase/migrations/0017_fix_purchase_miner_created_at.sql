-- Pro-X Network — Fix ambiguous "created_at"/"updated_at" in purchase_miner.
--
-- Bug (observed in production Edge Function logs):
--   [purchase-miner] purchase_miner RPC failed: column reference
--   "created_at" is ambiguous
--
-- Root cause: public.purchase_miner (0016_secure_miner_purchase.sql)
-- is declared `returns table (..., created_at timestamptz,
-- updated_at timestamptz, ...)`. Every column in a RETURNS TABLE
-- list becomes an implicit PL/pgSQL OUT-parameter variable, in scope
-- by that exact name for the entire function body — the same as any
-- other declared variable. Two of those names, `created_at` and
-- `updated_at`, collide with real column names on
-- public.mining_inventory. The function's
--
--   insert into public.mining_inventory (...)
--   values (...)
--   returning id, created_at, updated_at
--     into v_inventory_id, v_created_at, v_updated_at;
--
-- statement's RETURNING list is evaluated in a context where both
-- the just-inserted row's columns AND the function's own OUT
-- variables are visible, so unqualified `created_at` (and
-- `updated_at`) match two different things and Postgres refuses to
-- guess which one is meant.
--
-- This migration does NOT touch 0016_secure_miner_purchase.sql (it
-- is left exactly as deployed). It replaces the function body only,
-- via CREATE OR REPLACE FUNCTION with an IDENTICAL signature and an
-- IDENTICAL `returns table (...)` shape — the exact contract the
-- already-deployed purchase-miner Edge Function expects from
-- `.rpc('purchase_miner', ...).maybeSingle()` (it reads
-- inventory_id, miner_tier, miner_name, miner_icon, miner_level,
-- miner_speed, is_applied, created_at, updated_at, and
-- new_pxn_balance directly off the returned row). Changing the
-- return type (e.g. to jsonb) would silently break that already-
-- working Edge Function without modifying it, which is explicitly
-- out of scope here.
--
-- Fix: every column reference that could ever be ambiguous against
-- an OUT-parameter name — not just the two that actually triggered
-- the reported error — is now qualified with a table alias:
--   - `public.mining_config mc`      for the catalog read
--   - `public.mining_state ms`       for the existence check + lock
--     and the balance-deducting UPDATE
--   - `public.mining_inventory mi`   for the INSERT ... RETURNING
-- This is defense in depth: mining_inventory also has miner_tier,
-- miner_name, miner_icon, miner_level, miner_speed, and is_applied
-- columns that collide with OUT-parameter names of the same names —
-- they don't appear in today's RETURNING list, so they didn't
-- trigger today's error, but qualifying now prevents the same class
-- of bug if the RETURNING list is ever extended later.
--
-- No table schema (mining_config, mining_state, mining_inventory)
-- is altered by this migration. No permission model changes: the
-- same REVOKE/GRANT lines from 0016 are re-asserted below purely for
-- idempotency/defense-in-depth (CREATE OR REPLACE FUNCTION does not,
-- by itself, reset previously granted/revoked privileges — but
-- re-stating them here removes any doubt and keeps this migration
-- self-contained and safe to read in isolation).

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
  v_config_id     uuid;
  v_miner_tiers   jsonb;
  v_tier          jsonb;
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
  --    validates it before calling this RPC.
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
  -- 2. Load the ACTIVE catalog row. mining_config has zero
  --    client-facing RLS policies (service_role only), and this
  --    function runs as SECURITY DEFINER, so it can read it despite
  --    the caller being an ordinary authenticated user.
  --
  --    Qualified with alias `mc` — defense in depth, even though
  --    neither `id` nor `miner_tiers` collides with an OUT-parameter
  --    name today.
  -- ---------------------------------------------------------------
  select mc.id, mc.miner_tiers
    into v_config_id, v_miner_tiers
    from public.mining_config mc
   where mc.is_active
   limit 1;

  if not found then
    raise exception 'purchase_miner: no active mining_config row'
      using errcode = 'PXN05';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Look up the requested tier inside the catalog JSONB. Tiers
  --    are keyed by "level" in mining_config.miner_tiers (see
  --    0003_mining_config.sql) — p_miner_tier is matched against
  --    that field, never against an array index.
  -- ---------------------------------------------------------------
  select elem
    into v_tier
    from jsonb_array_elements(v_miner_tiers) as elem
   where (elem->>'level')::integer = p_miner_tier
   limit 1;

  if v_tier is null then
    raise exception 'purchase_miner: unknown miner tier % in active config %', p_miner_tier, v_config_id
      using errcode = 'PXN01';
  end if;

  -- Server-side catalog values ONLY. icon is not currently present
  -- in mining_config.miner_tiers (0003 intentionally excluded it as
  -- cosmetic-only), so v_icon is simply null unless a future config
  -- row adds it — either way, this value never comes from the
  -- caller.
  v_name  := v_tier->>'name';
  v_icon  := v_tier->>'icon';
  v_speed := (v_tier->>'speed')::numeric(20,8);
  v_cost  := (v_tier->>'cost')::numeric(20,8);

  if v_name is null or v_speed is null or v_cost is null then
    raise exception 'purchase_miner: catalog entry for tier % is malformed in config %', p_miner_tier, v_config_id
      using errcode = 'PXN05';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Verify the player's mining_state row exists BEFORE
  --    attempting any deduction, and take a row lock on it for the
  --    remainder of this transaction so a concurrent purchase_miner
  --    call for the same player queues behind this one rather than
  --    racing it.
  --
  --    Qualified with alias `ms` — defense in depth.
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
  -- 5. Atomically deduct PXN, but ONLY if the (now row-locked)
  --    current balance covers the cost. If it doesn't, zero rows
  --    match and `not found` below is raised — no partial deduction
  --    is possible, and the existing pxn_balance >= 0 CHECK
  --    constraints (0013_mining_state.sql, 0015_pxn_balance_security.sql)
  --    remain a second, independent guard against going negative.
  --
  --    The SET target `pxn_balance` is intentionally left
  --    unqualified — Postgres requires a bare column name on the
  --    left-hand side of SET in an UPDATE statement, it cannot be
  --    alias-qualified. The right-hand side and WHERE/RETURNING
  --    clauses are qualified with alias `ms`.
  -- ---------------------------------------------------------------
  update public.mining_state as ms
     set pxn_balance = ms.pxn_balance - v_cost
   where ms.user_id = p_user_id
     and ms.pxn_balance >= v_cost
  returning ms.pxn_balance into v_new_balance;

  if not found then
    raise exception 'purchase_miner: insufficient PXN balance for user_id % (miner tier %, cost %)',
      p_user_id, p_miner_tier, v_cost
      using errcode = 'PXN02';
  end if;

  -- ---------------------------------------------------------------
  -- 6. Insert the purchased unit in the SAME transaction. Any
  --    failure here (e.g. a future constraint violation) raises an
  --    exception that unwinds this entire function, rolling back
  --    the PXN deduction above along with it.
  --
  --    THE FIX: the table is aliased `mi`, and every column in the
  --    RETURNING clause is qualified as `mi.<column>` — this is
  --    what resolves the reported "column reference is ambiguous"
  --    error, since `mi.created_at` and `mi.updated_at` can no
  --    longer be confused with this function's own
  --    `created_at`/`updated_at` OUT-parameter variables.
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
  'Atomic, service-role-only miner purchase: looks up the requested tier in the active mining_config.miner_tiers catalog, deducts pxn_balance from mining_state only if sufficient, and inserts the purchased unit into mining_inventory — all in one transaction. Never trusts price/speed/name/icon from the caller. Not callable by anon/authenticated. (0017: fixed "created_at"/"updated_at" ambiguity via explicit table-alias qualification; behavior otherwise unchanged from 0016.)';

-- Re-assert service_role-only execution. CREATE OR REPLACE FUNCTION
-- does not reset previously granted/revoked privileges by itself,
-- but these lines are repeated here so this migration is correct
-- and self-contained even if read in isolation from 0016.
revoke all on function public.purchase_miner(uuid, integer) from public;
revoke all on function public.purchase_miner(uuid, integer) from anon;
revoke all on function public.purchase_miner(uuid, integer) from authenticated;
grant execute on function public.purchase_miner(uuid, integer) to service_role;

-- No table schema (mining_config, mining_state, mining_inventory) is
-- altered by this migration. No RLS policy is added, removed, or
-- modified. No new Edge Function, frontend file, or grant to
-- anon/authenticated is introduced.
