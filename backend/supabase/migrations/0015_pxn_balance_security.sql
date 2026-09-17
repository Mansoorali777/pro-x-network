-- Pro-X Network — PXN balance security hardening.
--
-- Context: pxn_balance already exists on public.mining_state (see
-- 0013_mining_state.sql) as `numeric(20,8) not null default 0
-- check (pxn_balance >= 0)`, and that table already has RLS enabled
-- with exactly one policy — `mining_state_select_own`
-- (`auth.uid() = user_id`, SELECT only) — and zero INSERT/UPDATE/
-- DELETE policies for `authenticated`. This migration does NOT
-- duplicate any of that. It exists to (a) defensively verify those
-- security properties still hold before this table becomes the
-- target of real-money-adjacent writes, and (b) introduce the one
-- new piece of infrastructure required before miner purchases can be
-- built safely: a single, atomic, service-role-only function for
-- changing pxn_balance, so that no future Edge Function ever has to
-- hand-roll a read-then-write balance update (which would be
-- vulnerable to lost updates / double-spend under concurrent
-- requests).
--
-- This migration does NOT implement miner purchasing, does NOT
-- change mining_inventory, does NOT touch mining_config, does NOT
-- grant authenticated/anon any new table privileges, does NOT create
-- a custom JWT/JWKS, and does NOT embed any credential or secret —
-- consistent with every prior migration in this project.
--
-- Idempotency: every DDL statement below is written so this file can
-- be re-run against a database that already has some or all of these
-- properties (the expected case, since 0013 already created the
-- column/constraint/policy) without erroring or creating duplicates.

-- ---------------------------------------------------------------
-- 1. Verify assumptions about the existing schema before proceeding.
--    If pxn_balance is ever missing or a different shape than
--    expected (e.g. a future migration accidentally altered it),
--    fail loudly here instead of silently operating on the wrong
--    assumption.
-- ---------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'mining_state'
      and column_name  = 'pxn_balance'
      and data_type    = 'numeric'
      and numeric_precision = 20
      and numeric_scale     = 8
  ) then
    raise exception
      'Expected public.mining_state.pxn_balance to already exist as numeric(20,8) (see 0013_mining_state.sql). Schema does not match — aborting rather than creating a duplicate/incompatible column.';
  end if;
end $$;

-- ---------------------------------------------------------------
-- 2. Ensure a not-negative constraint on pxn_balance exists.
--    0013_mining_state.sql already added `check (pxn_balance >= 0)`
--    as an inline, auto-named constraint. This step does not touch
--    that constraint. It adds a second, explicitly-named constraint
--    ONLY if one by this exact name does not already exist, so this
--    file is safe to re-run and never creates more than one copy of
--    itself. Having both the original inline check and this
--    explicitly-named one is intentional belt-and-suspenders: the
--    named constraint documents the invariant clearly for anyone
--    reading \d mining_state, independent of whatever name Postgres
--    auto-generated for the original.
-- ---------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'mining_state_pxn_balance_nonnegative_chk'
  ) then
    alter table public.mining_state
      add constraint mining_state_pxn_balance_nonnegative_chk
      check (pxn_balance >= 0);
  end if;
end $$;

-- ---------------------------------------------------------------
-- 3. Ensure Row Level Security is enabled on mining_state.
--    This is a no-op (never errors) if already enabled — included
--    here purely as a defensive guarantee, not a change in behavior.
-- ---------------------------------------------------------------
alter table public.mining_state enable row level security;

-- ---------------------------------------------------------------
-- 4. Ensure the player-owns-their-row SELECT policy exists.
--    Re-creates `mining_state_select_own` ONLY if it is missing —
--    CREATE POLICY has no IF NOT EXISTS form in Postgres, so this
--    guard is what makes the step idempotent. In the expected case
--    (0013 already ran) this block does nothing at all.
-- ---------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename  = 'mining_state'
      and policyname = 'mining_state_select_own'
  ) then
    create policy "mining_state_select_own"
      on public.mining_state
      for select
      to authenticated
      using (auth.uid() = user_id);
  end if;
end $$;

-- ---------------------------------------------------------------
-- 5. Guard against a security regression: fail the migration if any
--    INSERT/UPDATE/DELETE policy ever grants the `authenticated`
--    role access to mining_state. Per the architecture, ALL writes
--    to this table must go through service_role inside Edge
--    Functions — never directly from a client role. This is a
--    defensive assertion, not new access control by itself.
-- ---------------------------------------------------------------
do $$
begin
  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename  = 'mining_state'
      and cmd in ('INSERT', 'UPDATE', 'DELETE')
      and 'authenticated' = any(roles)
  ) then
    raise exception
      'Security invariant violated: an INSERT/UPDATE/DELETE policy grants the authenticated role access to public.mining_state. All writes must go through service_role Edge Functions only.';
  end if;
end $$;

-- ---------------------------------------------------------------
-- 6. Atomic PXN balance adjustment helper (infrastructure only —
--    no purchase logic yet).
--
--    public.adjust_pxn_balance(p_user_id, p_delta, p_reason) is the
--    one sanctioned way any future Edge Function should change a
--    player's pxn_balance: it locks the target row, applies the
--    delta, refuses to let the balance go negative, and returns the
--    new balance — all inside a single atomic statement, so two
--    concurrent calls (e.g. two purchase requests racing each other)
--    can never both read the same "before" balance and each apply
--    their own delta on top of stale data (the lost-update problem
--    a hand-rolled read-then-write would be vulnerable to).
--
--    p_delta may be positive (credit, e.g. a future reward) or
--    negative (debit, e.g. a future miner purchase) — this function
--    intentionally has no opinion on *why* the balance is changing;
--    that policy belongs in the (not-yet-built) Edge Function that
--    calls it, which is expected to pass a human-readable p_reason
--    for logging.
--
--    This function does NOT implement purchase validation, catalog
--    lookups, or inventory writes — it is strictly the balance
--    primitive those future features will be built on top of.
--
--    SECURITY DEFINER + explicit search_path: runs with the
--    privileges of the function owner (not the caller), so it can
--    update mining_state despite RLS denying authenticated/anon
--    direct UPDATE access. search_path is pinned to prevent a
--    search-path-hijacking attack from redefining what "mining_state"
--    resolves to.
--
--    EXECUTE is revoked from PUBLIC/anon/authenticated immediately
--    below the definition: Postgres grants EXECUTE on new functions
--    to PUBLIC by default, which — combined with SECURITY DEFINER —
--    would otherwise let any authenticated client call this directly
--    via PostgREST RPC and adjust their own (or, with a crafted
--    p_user_id, another player's) balance, completely bypassing the
--    Edge Function layer this project's architecture relies on for
--    validation. Only service_role may execute it.
-- ---------------------------------------------------------------
create or replace function public.adjust_pxn_balance(
  p_user_id uuid,
  p_delta   numeric(20,8),
  p_reason  text default null
)
returns numeric(20,8)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_new_balance numeric(20,8);
begin
  if p_user_id is null then
    raise exception 'adjust_pxn_balance: p_user_id is required';
  end if;

  if p_delta is null then
    raise exception 'adjust_pxn_balance: p_delta is required';
  end if;

  -- Lock the target row for the duration of this transaction so a
  -- concurrent call for the same user cannot read the same
  -- "before" balance and race this one.
  update public.mining_state
     set pxn_balance = pxn_balance + p_delta
   where user_id = p_user_id
  returning pxn_balance into v_new_balance;

  if not found then
    raise exception 'adjust_pxn_balance: no mining_state row for user_id %', p_user_id;
  end if;

  -- The nonnegative CHECK constraints on pxn_balance would already
  -- reject this UPDATE, but raising an explicit, descriptive error
  -- here gives callers a clearer signal than a generic constraint-
  -- violation error would.
  if v_new_balance < 0 then
    raise exception 'adjust_pxn_balance: insufficient PXN balance for user_id % (delta %, reason %)',
      p_user_id, p_delta, coalesce(p_reason, 'unspecified');
  end if;

  return v_new_balance;
end;
$$;

comment on function public.adjust_pxn_balance(uuid, numeric, text) is
  'Atomic, service-role-only primitive for changing a player''s pxn_balance (positive or negative delta). Locks the row, applies the delta, rejects results below zero, returns the new balance. Not callable by anon/authenticated. Contains no purchase/catalog/inventory logic — that belongs in the Edge Function(s) that call this.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as.
revoke all on function public.adjust_pxn_balance(uuid, numeric, text) from public;
revoke all on function public.adjust_pxn_balance(uuid, numeric, text) from anon;
revoke all on function public.adjust_pxn_balance(uuid, numeric, text) from authenticated;
grant execute on function public.adjust_pxn_balance(uuid, numeric, text) to service_role;

-- No rows are seeded or modified here, and no existing data is
-- touched. This migration only adds defensive guards and one new
-- helper function.
