-- Pro-X Network — Authoritative per-player mining state.
--
-- Table: mining_state.
--
-- This is schema only, per the approved architecture review. It does
-- NOT implement accrual, claim, level-up, inventory, referrals, or
-- tasks — those are later steps, each targeting one system at a
-- time. It does NOT touch index.html, admin.html, js/auth-client.js,
-- js/api-client.js, or PLAYER_ID, and creates no Edge Function.
--
-- Identity: user_id is auth.uid(), i.e. public.users.id — the real,
-- Telegram-signature-verified identity minted by the auth-telegram
-- Edge Function (see 0001_helpers.sql's auth-assumption comment).
-- This is NOT the same as the frontend's current PLAYER_ID (derived
-- from unverified initDataUnsafe), which this table intentionally
-- has no column for.
--
-- Scope: exactly one row per player, holding only the fields the
-- prior architecture review classified as (A) authoritative
-- server-side state. Explicitly excluded, per that review and this
-- step's instructions: tasks_done, monthly_points,
-- monthly_period_key, ref_code, and inventory (miner units) — these
-- belong to other systems/tables designed in later steps, not here.
--
-- Trust model: every balance/progression column is written only by
-- server-side Edge Functions using the service_role key. No client
-- role may ever insert, update, or delete a row here directly — a
-- player's own mining_state row is created later by the backend
-- (e.g. on first successful auth), not seeded by this migration and
-- not created by the client.

create table public.mining_state (
  -- Primary identity. One row per authenticated player; user_id IS
  -- the primary key (no separate surrogate id), and always equals
  -- auth.uid() for that player once RLS is enforced below.
  user_id                     uuid        primary key references public.users(id) on delete cascade,

  -- ---- balances (see architecture report §B: minedBalance / pendingClaim / claimedTotal / pxnBalance are four distinct ledgers, preserved exactly) ----

  -- Lifetime total ever mined (display-only running total; never
  -- decremented by claiming, spending, or trading).
  mined_balance_total         numeric(20,8) not null default 0
                                check (mined_balance_total >= 0),

  -- Accrued-but-not-yet-claimed amount. Claiming moves this into
  -- claimed_total and resets this to 0 — it does not create value.
  pending_claim                numeric(20,8) not null default 0
                                check (pending_claim >= 0),

  -- Spendable balance (post-claim). Used for marketplace/swap
  -- activity in the current game design.
  claimed_total                numeric(20,8) not null default 0
                                check (claimed_total >= 0),

  -- Separate currency used for miner-store purchases and level-ups.
  -- Distinct ledger from claimed_total; funded via swap, not accrual.
  pxn_balance                  numeric(20,8) not null default 0
                                check (pxn_balance >= 0),

  -- ---- progression ----

  level                        integer     not null default 1
                                check (level >= 1),
  claim_count                  integer     not null default 0
                                check (claim_count >= 0),

  -- ---- boosts (server-set expiry timestamps, not client-authored durations) ----

  boost_until                  timestamptz,
  ad_boost_until                timestamptz,

  -- ---- ad tracking ----

  ads_watched_in_window         integer     not null default 0
                                check (ads_watched_in_window >= 0),
  ads_window_started_at         timestamptz,

  -- ---- accrual bookkeeping ----

  -- Server clock only. Every accrual computation reads this and
  -- overwrites it with now() inside the same server-side transaction
  -- — it must never be accepted as a client-supplied value.
  last_accrued_at               timestamptz not null default now(),

  -- ---- referral placeholder ----

  -- Raw counter only, per the approved architecture. Whether a
  -- verified referral system lives here or in a separate table is an
  -- explicitly deferred decision (see architecture report §12) — not
  -- resolved by this migration.
  referral_count                 integer     not null default 0
                                check (referral_count >= 0),

  -- ---- concurrency guard ----

  -- Optimistic-concurrency counter, incremented by every server-side
  -- write to this row. Exists to prevent two concurrent
  -- accrual/claim requests for the same player from both reading the
  -- same "before" state and each applying the same elapsed time
  -- twice (see architecture report §F).
  accrual_lock_version            bigint    not null default 0
                                check (accrual_lock_version >= 0),

  -- ---- bookkeeping ----

  created_at                      timestamptz not null default now(),
  updated_at                      timestamptz not null default now()
);

comment on table public.mining_state is
  'One row per authenticated player, keyed by user_id = auth.uid() (= public.users.id). Every financial and progression field is server-authoritative: the client must never directly write mined_balance_total, pending_claim, claimed_total, pxn_balance, level, or any other column here. Rows are created later by the backend, not seeded by this migration and not insertable by the client.';
comment on column public.mining_state.last_accrued_at is
  'Server clock only. Always overwritten with now() by the server during accrual — never accepted as a client-supplied timestamp.';
comment on column public.mining_state.accrual_lock_version is
  'Optimistic-concurrency counter used by server-side accrual/claim functions to prevent double-accrual from concurrent requests. Not player-meaningful.';

-- Reuse the existing shared trigger function from 0001_helpers.sql —
-- confirmed present there (public.set_updated_at()) — rather than
-- redefining it here.
create trigger mining_state_set_updated_at
  before update on public.mining_state
  for each row execute function public.set_updated_at();

alter table public.mining_state enable row level security;

-- A player may read their own row (needed by the frontend to render
-- balances once wired up in a later step). No INSERT, UPDATE, or
-- DELETE policy is created for authenticated or anon: with RLS
-- enabled and no matching policy, Postgres denies those operations
-- to those roles by default. All mutations happen via service_role
-- inside future Edge Functions (accrual, claim, level-up, etc.),
-- which bypass RLS entirely by design — the same pattern already
-- used for public.users and public.mining_config.
create policy "mining_state_select_own"
  on public.mining_state
  for select
  to authenticated
  using (auth.uid() = user_id);

-- No rows are seeded here. mining_state is one row per player and is
-- created later by the backend (e.g. on first successful
-- authentication), not by this migration.
