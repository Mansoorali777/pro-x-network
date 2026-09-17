-- Pro-X Network — Point purchase_miner() at public.miner_catalog.
--
-- Function: public.purchase_miner(p_user_id uuid, p_miner_tier integer)
-- (signature UNCHANGED from 0016_secure_miner_purchase.sql /
-- 0017_fix_purchase_miner_created_at.sql).
--
-- Context: 0021_miner_catalog.sql created the database-backed
-- public.miner_catalog table (schema/RLS/seed only) explicitly as
-- prep for a "later step" that would point real purchase logic at
-- it. admin-miner-catalog (a later Edge Function) already lets an
-- admin manage that table, and purchase-miner/index.ts already gates
-- purchases on miner_catalog.is_active BEFORE calling this RPC. This
-- migration is that "later step" for purchase_miner itself: its
-- catalog lookup — previously the sole read of
-- public.mining_config.miner_tiers inside this function — is
-- replaced with a lookup against public.miner_catalog, so miner_name,
-- miner_icon, mining_speed, and price_pxn from THAT table are what
-- actually gets charged and recorded from now on.
--
-- ONLY the catalog-lookup section changes. Every other piece of
-- 0016/0017's purchase_miner is carried over unchanged:
--   - Input validation (p_user_id / p_miner_tier null/range checks,
--     PXN04).
--   - The mining_state existence check + `for update` row lock
--     (PXN03), taken BEFORE any deduction, exactly as before.
--   - The balance-deducting UPDATE, whose WHERE clause re-checks
--     `pxn_balance >= v_cost` against the CURRENT locked row value
--     (not a value read earlier) — same lost-update protection as
--     before (PXN02 on insufficient balance).
--   - The mining_inventory INSERT ... RETURNING, in the SAME
--     transaction/single rollback boundary as the deduction — a
--     failure here still unwinds the balance UPDATE too.
--   - The `returns table (...)` shape, so the already-deployed
--     purchase-miner Edge Function's
--     `.rpc('purchase_miner', ...).maybeSingle()` call keeps reading
--     the exact same column set with no Edge Function change needed.
--   - `language plpgsql security definer set search_path = public,
--     pg_temp` — unchanged.
--   - The `revoke ... from public/anon/authenticated` +
--     `grant execute ... to service_role` lines — unchanged;
--     re-asserted below purely for idempotency/defense-in-depth,
--     exactly as 0017 already did relative to 0016 (CREATE OR
--     REPLACE FUNCTION does not by itself reset previously granted/
--     revoked privileges).
--
-- What's different in the catalog-lookup section:
--   - OLD: select the single is_active=true row of mining_config,
--     then jsonb_array_elements(miner_tiers) to find the element
--     whose "level" key equals p_miner_tier. Name/icon/speed/cost
--     were pulled out of that JSONB element (icon was frequently
--     null — 0003_mining_config.sql never populated it).
--   - NEW: `select ... from public.miner_catalog mc where
--     mc.miner_tier = p_miner_tier` (miner_catalog has a UNIQUE
--     constraint on miner_tier, so this is at most one row — see
--     0021_miner_catalog.sql). is_active is read directly off that
--     row rather than gating which catalog-wide "config version" is
--     visible: this function now requires that specific row to
--     exist AND have is_active = true (requirement 4). miner_icon on
--     miner_catalog is NOT NULL (0021's schema), so v_icon can no
--     longer be null the way it could be under the old JSONB path.
--   - This function is SECURITY DEFINER, exactly as before, so it
--     can read miner_catalog regardless of that table's RLS policy
--     (which only exposes is_active=true rows to `authenticated` —
--     see 0021_miner_catalog.sql) — the same reason it could already
--     read mining_config (service_role-only RLS) despite the caller
--     being an ordinary authenticated user. No RLS policy on
--     miner_catalog, mining_config, mining_state, or
--     mining_inventory is created, removed, or modified by this
--     migration.
--
-- Error codes: no new SQLSTATE is introduced. The old PXN01 ("unknown
-- miner tier") now also covers "miner_catalog row exists but
-- is_active = false" — from the caller's perspective both mean "you
-- cannot purchase this tier right now", and the already-deployed
-- purchase-miner Edge Function already maps PXN01 to 404 "Unknown
-- miner tier" without needing to distinguish the two (it also already
-- performs its own separate is_active pre-check against miner_catalog
-- before ever calling this RPC, so in practice this RPC's PXN01 for
-- "inactive" is a defense-in-depth backstop, not the primary path).
-- PXN05 ("server misconfiguration") is kept for the same defensive
-- purpose it served before — miner_catalog's columns are all NOT
-- NULL by constraint, so v_name/v_icon/v_speed/v_cost being null
-- after a successful row fetch should be impossible, but the check is
-- kept rather than removed so a future, unrelated schema change can't
-- silently turn a malformed row into a wrong charge instead of a loud
-- 500. PXN02, PXN03, PXN04 are unchanged in both meaning and the
-- exact statements that raise them.
--
-- Not touched by this migration: public.mining_config (table and
-- data untouched — purchase_miner simply no longer reads it, but
-- nothing about the table itself changes, and nothing else in this
-- codebase that still reads it, e.g. index.html's own defaults, is
-- affected), public.mining_state (schema untouched), public.
-- mining_inventory (schema untouched — this migration writes to it
-- exactly the same columns as before, only sourcing three of those
-- values from a different upstream table), auth-telegram,
-- accrue-mining, set-miner-applied, admin-set-mining-speed,
-- admin.html, index.html, and every other existing migration.

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
  --    validates it before calling this RPC. UNCHANGED from 0016/0017.
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
  --    miner_tier. This REPLACES the old mining_config.miner_tiers
  --    JSONB lookup (0016/0017). This function is SECURITY DEFINER,
  --    so it can read miner_catalog regardless of that table's RLS
  --    policy, exactly as it could already read mining_config.
  -- ---------------------------------------------------------------
  select mc.id, mc.is_active, mc.miner_name, mc.miner_icon, mc.mining_speed, mc.price_pxn
    into v_catalog_id, v_is_active, v_name, v_icon, v_speed, v_cost
    from public.miner_catalog mc
   where mc.miner_tier = p_miner_tier
   limit 1;

  -- A miner must exist for this tier AND be currently active
  -- (requirement 4). Both "no such tier" and "tier exists but
  -- retired" are reported as the same PXN01 the caller already
  -- handles as "unknown miner tier" — see the header note on why no
  -- new error code is introduced for this distinction.
  if not found or v_is_active is not true then
    raise exception 'purchase_miner: unknown or inactive miner tier %', p_miner_tier
      using errcode = 'PXN01';
  end if;

  -- Defense in depth: miner_catalog's miner_name/miner_icon/
  -- price_pxn/mining_speed columns are all NOT NULL by constraint
  -- (0021_miner_catalog.sql), so this should be unreachable for a
  -- row that was just found — kept as a loud failure instead of a
  -- silent wrong charge if that ever stops being true.
  if v_name is null or v_icon is null or v_speed is null or v_cost is null then
    raise exception 'purchase_miner: catalog entry for tier % is malformed (miner_catalog id %)', p_miner_tier, v_catalog_id
      using errcode = 'PXN05';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Verify the player's mining_state row exists BEFORE
  --    attempting any deduction, and take a row lock on it for the
  --    remainder of this transaction so a concurrent purchase_miner
  --    call for the same player queues behind this one rather than
  --    racing it. UNCHANGED from 0016/0017.
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
  -- 4. Atomically deduct PXN, but ONLY if the (now row-locked)
  --    current balance covers the cost (now sourced from
  --    miner_catalog.price_pxn rather than
  --    mining_config.miner_tiers[].cost). If it doesn't, zero rows
  --    match and `not found` below is raised — no partial deduction
  --    is possible, and the existing pxn_balance >= 0 CHECK
  --    constraints (0013_mining_state.sql, 0015_pxn_balance_security.sql)
  --    remain a second, independent guard against going negative.
  --    UNCHANGED from 0016/0017 other than v_cost's new source.
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
  -- 5. Insert the purchased unit in the SAME transaction. Any
  --    failure here (e.g. a future constraint violation) raises an
  --    exception that unwinds this entire function, rolling back
  --    the PXN deduction above along with it. UNCHANGED from
  --    0016/0017 (including the `mi` alias + qualified RETURNING
  --    list from 0017's ambiguity fix) other than v_name/v_icon/
  --    v_speed's new source.
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
  'Atomic, service-role-only miner purchase: looks up the requested tier in public.miner_catalog (must exist and be is_active), deducts pxn_balance from mining_state only if sufficient, and inserts the purchased unit into mining_inventory — all in one transaction. Never trusts price/speed/name/icon from the caller. Not callable by anon/authenticated. (0022: catalog source changed from mining_config.miner_tiers JSONB to public.miner_catalog; signature, locking, atomicity, and return shape unchanged from 0016/0017.)';

-- Re-assert service_role-only execution. CREATE OR REPLACE FUNCTION
-- does not reset previously granted/revoked privileges by itself,
-- but these lines are repeated here — unchanged from 0016/0017 — so
-- this migration is correct and self-contained even if read in
-- isolation.
revoke all on function public.purchase_miner(uuid, integer) from public;
revoke all on function public.purchase_miner(uuid, integer) from anon;
revoke all on function public.purchase_miner(uuid, integer) from authenticated;
grant execute on function public.purchase_miner(uuid, integer) to service_role;

-- No table schema (miner_catalog, mining_config, mining_state,
-- mining_inventory) is altered by this migration — CREATE OR REPLACE
-- FUNCTION only replaces the function body, not any table. No RLS
-- policy is added, removed, or modified. No new Edge Function,
-- frontend file, or grant to anon/authenticated is introduced. No
-- other migration is created or modified.
