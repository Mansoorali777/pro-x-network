-- Pro-X Network — m.PXN Ledger Primitive.
--
-- Table: public.mpxn_ledger
-- Function: public.adjust_claimed_total(p_user_id, p_delta, p_reason,
--                                        p_ref_type, p_ref_id)
--
-- Context: mining_state.claimed_total (0013_mining_state.sql) is the
-- spendable m.PXN balance. Today exactly three functions write it —
-- claim_mining (0027), purchase_miner (0028), upgrade_miner (0029) —
-- each with its own bespoke update statement, because each of those
-- flows also does something else atomically (move pending_claim,
-- insert an inventory row, bump miner_level). Mining Level Up
-- (0031_level_up_mining.sql, later step) and the Marketplace
-- (0032-0034, later steps) are pure balance movements with no other
-- side effect, and there will be several of them (escrow debit,
-- escrow refund, sale credit, treasury fee credit, admin adjust) —
-- repeating a bespoke "lock row, check funds, update, done" block
-- for each of those invites the same balance to be checked/updated
-- via two subtly different code paths. This migration factors that
-- single pattern into one atomic, reusable primitive, exactly the
-- role adjust_pxn_balance (0015_pxn_balance_security.sql) already
-- plays for pxn_balance — mpxn_ledger + adjust_claimed_total is that
-- same pattern for claimed_total (m.PXN), kept as a fully separate
-- table/function so the two currencies never share a code path.
--
-- Ledger semantics (unchanged by this migration — see
-- 0013_mining_state.sql / 0027_secure_mpxn_claim.sql):
--   mined_balance_total — lifetime total ever mined. Never touched here.
--   pending_claim        — accrued, not-yet-claimed m.PXN. Never touched here.
--   claimed_total         — spendable m.PXN. The ONLY column this
--                            migration's function writes.
--   pxn_balance            — separate PXN token balance. NEVER touched
--                            here, and never will be by anything built
--                            on top of this primitive — that is the
--                            entire point of it being a distinct
--                            function from adjust_pxn_balance.
--
-- mpxn_ledger is an append-only audit trail of every claimed_total
-- movement made through this primitive (level-ups, marketplace
-- escrow/sale/fee/treasury movements, admin adjustments). It is NOT
-- itself the source of truth for the balance — mining_state.claimed_total
-- remains that — but it serves two purposes:
--   1. Idempotency: a unique index on (user_id, reason, ref_type,
--      ref_id) where ref_id is not null means a caller that retries
--      the exact same logical operation (e.g. the same client-supplied
--      level-up request_id, see 0031) physically cannot have it
--      applied twice — the second attempt's ledger insert fails with
--      a unique-violation, which this function turns into a distinct,
--      recognizable error (PXN26) rather than silently double-applying
--      or silently no-opping.
--   2. Auditability: every m.PXN movement, by every subsystem, lands
--      in one place with a reason and a reference, for admin/debugging
--      use — mirroring why mpxn_ledger exists at all rather than each
--      subsystem inventing its own history table.
--
-- Trust model: p_user_id is supplied by the calling Edge Function from
-- auth.getUser() (or, for admin actions, from an admin-verified target
-- user id) — never read from a request body by this function itself.
-- This function additionally scopes its lock/read/update to
-- `user_id = p_user_id`, the same belt-and-suspenders pattern used by
-- claim_mining/purchase_miner/set_miner_applied/upgrade_miner.
--
-- Concurrency: the player's mining_state row is locked (SELECT ... FOR
-- UPDATE) before claimed_total is read, for the remainder of the
-- transaction — same pattern as every other mining_state writer in
-- this schema.
--
-- Custom SQLSTATEs (continuing the existing PXN01-PXN23 sequence):
--   PXN24 — insufficient m.PXN (claimed_total + p_delta would be < 0)  -> 400/409
--   PXN25 — no mining_state row for this user_id                       -> 404
--   PXN26 — duplicate transaction (p_reason/p_ref_type/p_ref_id already
--           recorded for this user_id)                                -> 409
--
-- (PXN26 also covers plain invalid-input: a null p_user_id, p_delta,
-- or p_reason raises PXN26's sibling validation path below under the
-- same "reject before touching the database" discipline as
-- claim_mining's PXN22 — see the input-validation step.)

create table public.mpxn_ledger (
  id             uuid          primary key default gen_random_uuid(),

  -- Whose claimed_total this movement applied to. Not a foreign key
  -- to mining_state (which is keyed by user_id as its own primary
  -- key) — referencing users(id) directly, same as mining_state.user_id
  -- itself does, so a ledger row can outlive... nothing, actually: it
  -- cascades with the user, same as every other player-owned table
  -- in this schema.
  user_id        uuid          not null references public.users(id) on delete cascade,

  -- Signed movement. Positive = credited, negative = debited. The
  -- actual balance lives on mining_state.claimed_total — this column
  -- is the audit record of the change, not a second copy of the
  -- balance.
  delta          numeric(20,8) not null
                   check (delta <> 0),

  -- claimed_total AFTER this movement was applied, captured in the
  -- same transaction/lock that applied it — so this row is a true
  -- point-in-time snapshot, not a value recomputed later from other
  -- rows.
  balance_after  numeric(20,8) not null
                   check (balance_after >= 0),

  -- Free-form but conventionally one of: 'level_up',
  -- 'market_list_escrow' (unused — listing itself moves no m.PXN),
  -- 'market_offer_escrow', 'market_offer_refund', 'market_buy_debit',
  -- 'market_sale_credit', 'market_fee_treasury_credit', 'admin_adjust'.
  -- Not constrained by a CHECK/enum here deliberately — new reasons
  -- will be added by later migrations (0031/0034) without needing to
  -- alter this table again.
  reason         text          not null
                   check (length(reason) between 1 and 64),

  -- What this movement was for, so two different subsystems can each
  -- have their own idempotency key without colliding (e.g. a
  -- level-up request_id and a marketplace offer id are both valid
  -- ref_ids, distinguished by ref_type). Both nullable — an
  -- admin_adjust movement, for instance, has no natural ref_id to
  -- attach and relies on manual review instead of the unique index
  -- below for duplicate protection.
  ref_type       text,
  ref_id         uuid,

  created_at     timestamptz   not null default now()
);

comment on table public.mpxn_ledger is
  'Append-only audit trail of every claimed_total (m.PXN) movement made through adjust_claimed_total(). Not the source of truth for the balance (mining_state.claimed_total is) — exists for idempotency (via the unique ref index below) and admin/debugging history. service_role-only: no RLS policy grants anon/authenticated any access. Never written to directly outside adjust_claimed_total() — always go through that function so balance_after stays a true snapshot.';
comment on column public.mpxn_ledger.delta is
  'Signed m.PXN movement recorded by this row. Positive = credited to the player, negative = debited. Never pxn_balance-related.';
comment on column public.mpxn_ledger.balance_after is
  'mining_state.claimed_total immediately after this movement, captured under the same row lock that applied it.';
comment on column public.mpxn_ledger.reason is
  'Free-form movement category (e.g. level_up, market_offer_escrow, market_sale_credit, admin_adjust). Not enum-constrained so later migrations can introduce new reasons without altering this table.';
comment on column public.mpxn_ledger.ref_type is
  'What ref_id refers to (e.g. "level_up_request", "offer", "listing", "admin"). Paired with ref_id to scope the idempotency unique index per-subsystem.';
comment on column public.mpxn_ledger.ref_id is
  'The specific operation this movement belongs to (a client request_id, an offer id, a listing id, ...). NULL for movements with no natural idempotency key (e.g. admin_adjust), which then rely on manual review rather than this table for duplicate protection.';

-- Idempotency guard: for any given user_id + reason + ref_type, a
-- non-null ref_id can appear at most once. A retried call for the
-- exact same logical operation (same request_id, same offer id, ...)
-- therefore cannot have its ledger row inserted a second time — the
-- INSERT below fails with a unique_violation, which
-- adjust_claimed_total() catches and re-raises as PXN26 rather than
-- letting the caller's retry silently double-apply the balance
-- change.
create unique index mpxn_ledger_idempotency_key
  on public.mpxn_ledger (user_id, reason, ref_type, ref_id)
  where ref_id is not null;

-- Read/history index for admin tooling and per-user ledger views.
create index mpxn_ledger_user_id_created_at_idx
  on public.mpxn_ledger (user_id, created_at desc);

alter table public.mpxn_ledger enable row level security;

-- Deliberately no policies here. RLS + zero policies for
-- anon/authenticated = default-deny for every operation (including
-- SELECT) on this table for those roles, same pattern as
-- miner_upgrade_costs (0026) and mining_config (0003). service_role
-- bypasses RLS as usual and is the only way this table is ever read
-- or written — always through adjust_claimed_total() below, never by
-- a direct INSERT from any Edge Function.

-- ---------------------------------------------------------------
-- public.adjust_claimed_total — the single sanctioned, atomic,
-- idempotent primitive for changing a player's claimed_total
-- (m.PXN). Every later m.PXN-spending/crediting feature (level-up,
-- marketplace escrow/sale/fee/treasury, admin adjustment) calls this
-- rather than writing mining_state.claimed_total directly.
-- ---------------------------------------------------------------
create or replace function public.adjust_claimed_total(
  p_user_id  uuid,
  p_delta    numeric,
  p_reason   text,
  p_ref_type text default null,
  p_ref_id   uuid default null
)
returns numeric(20,8)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_new_balance numeric(20,8);
begin
  -- ---------------------------------------------------------------
  -- 1. Validate input. Defense in depth even though every caller
  --    (level_up_mining, the marketplace RPCs, the admin Edge
  --    Function) also validates before reaching here.
  -- ---------------------------------------------------------------
  if p_user_id is null then
    raise exception 'adjust_claimed_total: p_user_id is required'
      using errcode = 'PXN26';
  end if;

  if p_delta is null or p_delta = 0 then
    raise exception 'adjust_claimed_total: p_delta must be a non-zero number'
      using errcode = 'PXN26';
  end if;

  if p_reason is null or length(p_reason) < 1 then
    raise exception 'adjust_claimed_total: p_reason is required'
      using errcode = 'PXN26';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the player's mining_state row for the remainder of the
  --    transaction — same pattern as claim_mining/purchase_miner/
  --    set_miner_applied/upgrade_miner. A second concurrent
  --    adjust_claimed_total call for this same p_user_id (from any
  --    subsystem) queues behind this one instead of racing it.
  -- ---------------------------------------------------------------
  perform 1
    from public.mining_state as ms
   where ms.user_id = p_user_id
     for update;

  if not found then
    raise exception 'adjust_claimed_total: no mining_state row for user_id %', p_user_id
      using errcode = 'PXN25';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Apply the delta atomically, rejecting if it would take
  --    claimed_total below zero. The WHERE clause re-checks the
  --    condition against the CURRENT locked row value (not a value
  --    read in a separate statement), so this is race-free by
  --    construction — identical reasoning to purchase_miner's
  --    `pxn_balance >= v_cost` guard (0016/0022/0028) applied to
  --    claimed_total instead. The existing
  --    `check (claimed_total >= 0)` constraint (0013_mining_state.sql)
  --    remains a second, independent backstop.
  -- ---------------------------------------------------------------
  update public.mining_state as ms
     set claimed_total = ms.claimed_total + p_delta
   where ms.user_id = p_user_id
     and ms.claimed_total + p_delta >= 0
  returning ms.claimed_total into v_new_balance;

  if not found then
    raise exception 'adjust_claimed_total: insufficient m.PXN balance for user_id % (delta %, reason %)',
      p_user_id, p_delta, p_reason
      using errcode = 'PXN24';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Record the movement. balance_after is v_new_balance, the
  --    exact value just committed above under the same row lock —
  --    a true snapshot, not a value recomputed later. A
  --    unique_violation here (retried request_id/offer id/etc. —
  --    see mpxn_ledger_idempotency_key above) means this exact
  --    logical operation was already applied; re-raise as PXN26 so
  --    the caller can distinguish "already done" from every other
  --    failure mode, and so the balance change just made above is
  --    rolled back with the rest of this transaction rather than
  --    left half-applied.
  -- ---------------------------------------------------------------
  begin
    insert into public.mpxn_ledger (user_id, delta, balance_after, reason, ref_type, ref_id)
    values (p_user_id, p_delta, v_new_balance, p_reason, p_ref_type, p_ref_id);
  exception
    when unique_violation then
      raise exception 'adjust_claimed_total: duplicate transaction for user_id % (reason %, ref_type %, ref_id %)',
        p_user_id, p_reason, p_ref_type, p_ref_id
        using errcode = 'PXN26';
  end;

  return v_new_balance;
end;
$$;

comment on function public.adjust_claimed_total(uuid, numeric, text, text, uuid) is
  'Atomic, service-role-only primitive for changing a player''s claimed_total (m.PXN) balance (positive or negative delta). Locks the mining_state row, applies the delta, rejects results below zero (PXN24), rejects when no mining_state row exists (PXN25), records the movement in mpxn_ledger, and rejects a retried/duplicate (user_id, reason, ref_type, ref_id) as PXN26. Returns the new claimed_total. Never reads or writes pxn_balance, pending_claim, or mined_balance_total. Not callable by anon/authenticated. This is the m.PXN counterpart to adjust_pxn_balance (0015_pxn_balance_security.sql) — the two are intentionally separate functions over separate columns so the two currencies never share a write path.';

-- Postgres grants EXECUTE on newly created functions to PUBLIC by
-- default — revoke that immediately, then grant only to the role
-- Edge Functions actually run as. Same pattern as every other
-- service-role-only function in this schema.
revoke all on function public.adjust_claimed_total(uuid, numeric, text, text, uuid) from public;
revoke all on function public.adjust_claimed_total(uuid, numeric, text, text, uuid) from anon;
revoke all on function public.adjust_claimed_total(uuid, numeric, text, text, uuid) from authenticated;
grant execute on function public.adjust_claimed_total(uuid, numeric, text, text, uuid) to service_role;

-- ---------------------------------------------------------------
-- Nothing calls this function yet. This migration is intentionally
-- inert: it adds a new table and a new function, and touches no
-- existing table, column, RLS policy, or function. claim_mining
-- (0027), purchase_miner (0028), upgrade_miner (0029), and
-- adjust_pxn_balance (0015) are all unmodified and continue writing
-- claimed_total/pxn_balance exactly as they did before this
-- migration. level_up_mining (0031, next step) is the first caller.
-- ---------------------------------------------------------------
