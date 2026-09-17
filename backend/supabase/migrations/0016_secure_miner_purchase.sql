-- Pro-X Network — Secure, atomic miner purchase.
--
-- Function: public.purchase_miner(p_user_id uuid, p_miner_tier integer).
--
-- Context: 0015_pxn_balance_security.sql introduced
-- public.adjust_pxn_balance as a generic, service-role-only balance
-- primitive, but explicitly deferred purchase validation, catalog
-- lookups, and inventory writes to a later step ("that policy
-- belongs in the (not-yet-built) Edge Function that calls it").
-- This migration is that step for miner purchases specifically. It
-- does NOT reuse adjust_pxn_balance, because a purchase needs the
-- balance deduction and the mining_inventory insert to happen in the
-- SAME transaction with a single rollback boundary — calling out to
-- a separate function and then doing a second, separate insert from
-- the Edge Function would reopen exactly the lost-update/partial-
-- write risk 0015 was written to close. Instead, purchase_miner
-- performs the deduction and the insert itself, atomically.
--
-- This migration does NOT modify mining_config, mining_state, or
-- mining_inventory (no ALTER TABLE of any kind), does NOT create any
-- marketplace/listing logic, does NOT modify mining accrual
-- (accrue-mining is untouched), does NOT create a custom JWT/JWKS/
-- private-JWK system, and does NOT reference SUPABASE_JWT_SECRET.
--
-- Trust model: p_user_id and p_miner_tier are the ONLY inputs. Every
-- other value used in the purchase — the miner's name, icon, speed,
-- and cost — is read server-side from the currently-ACTIVE row of
-- public.mining_config.miner_tiers (see 0003_mining_config.sql,
-- service_role-only by RLS) and is never accepted as a parameter,
-- so a caller cannot influence price/speed/name/icon no matter what
-- it passes.
--
-- Concurrency & atomicity: the whole function body runs inside the
-- single implicit transaction of the PL/pgSQL function call. The
-- balance-deducting UPDATE's WHERE clause re-checks
-- `pxn_balance >= v_cost` against the current row value at the time
-- that statement executes (not a value read earlier in the
-- function), and Postgres holds a row-level lock on the
-- mining_state row for the duration of the transaction once that
-- UPDATE runs — so two concurrent purchase_miner calls for the same
-- player can never both succeed against a balance that only covers
-- one of them. If the balance is insufficient, zero rows match the
-- UPDATE's WHERE clause, `not found` is raised, and the exception
-- unwinds the whole function — nothing is committed, including no
-- mining_inventory insert. If the mining_inventory INSERT fails for
-- any reason after the balance was deducted, the exception raised by
-- INSERT equally unwinds the whole function and the earlier UPDATE
-- to pxn_balance is rolled back along with it (single transaction,
-- single rollback boundary) — the PXN is never lost.
--
-- Multiple units of the same tier are explicitly allowed (no
-- uniqueness check against p_miner_tier), consistent with
-- 0014_mining_inventory.sql's "intentionally many-rows-per-player,
-- no unique constraint on (user_id, miner_tier)" design.
--
-- Custom SQLSTATEs (5-char, distinguishable by the calling Edge
-- Function so it can return the right HTTP status without parsing
-- error text):
--   PXN01 — unknown/invalid miner tier (not found in the active
--           catalog)                                    -> 404
--   PXN02 — insufficient PXN balance for this purchase   -> 400
--   PXN03 — no mining_state row exists for this user yet -> 404
--   PXN04 — invalid input (null user id, or miner tier not
--           an integer >= 1)                             -> 400
--   PXN05 — no active mining_config row (server misconfiguration)
--                                                         -> 500

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
  -- ---------------------------------------------------------------
  select id, miner_tiers
    into v_config_id, v_miner_tiers
    from public.mining_config
   where is_active
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
  -- ---------------------------------------------------------------
  perform 1
    from public.mining_state
   where user_id = p_user_id
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
  -- ---------------------------------------------------------------
  update public.mining_state
     set pxn_balance = pxn_balance - v_cost
   where user_id = p_user_id
     and pxn_balance >= v_cost
  returning pxn_balance into v_new_balance;

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
  -- ---------------------------------------------------------------
  insert into public.mining_inventory (
    user_id, miner_tier, miner_name, miner_icon, miner_level, miner_speed, is_applied
  ) values (
    p_user_id, p_miner_tier, v_name, v_icon, 1, v_speed, false
  )
  returning id, created_at, updated_at
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
  'Atomic, service-role-only miner purchase: looks up the requested tier in the active mining_config.miner_tiers catalog, deducts pxn_balance from mining_state only if sufficient, and inserts the purchased unit into mining_inventory — all in one transaction. Never trusts price/speed/name/icon from the caller. Not callable by anon/authenticated.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Same pattern as
-- 0015_pxn_balance_security.sql's adjust_pxn_balance.
revoke all on function public.purchase_miner(uuid, integer) from public;
revoke all on function public.purchase_miner(uuid, integer) from anon;
revoke all on function public.purchase_miner(uuid, integer) from authenticated;
grant execute on function public.purchase_miner(uuid, integer) to service_role;

-- No rows are seeded or modified here, and no existing table,
-- policy, or function (including adjust_pxn_balance) is touched.
-- This migration only adds the one new purchase_miner function.
