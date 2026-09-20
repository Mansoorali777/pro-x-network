-- Pro-X Network — Friends Referral system: relationship table.
--
-- Table: public.referrals.
--
-- Context: per the FINAL LOCKED referral design (Design Revision v2),
-- this migration implements ONLY the referral relationship table —
-- the immutable, one-time link between a referrer and a referred
-- Telegram account. This is SCHEMA ONLY, mirroring the discipline
-- already used by 0013_mining_state.sql / 0014_mining_inventory.sql /
-- 0021_miner_catalog.sql: no RPC, no Edge Function, no wiring into
-- auth-telegram, no qualification/reward logic, and no change to
-- index.html, admin.html, or any existing migration file (0000-0042)
-- is made by this migration.
--
-- Explicitly NOT part of this migration (all deferred to later,
-- separate steps per the locked migration sequence):
--   - public.referral_config (qualification thresholds/cooldown) —
--     does not exist yet.
--   - record_pending_referral(), qualify_referral(), flag_referral(),
--     or any other RPC — none are created here.
--   - Any Edge Function (auth-telegram is NOT modified by this
--     migration; start_param is not extracted or wired anywhere yet).
--   - referral_count on mining_state is NOT touched, incremented, or
--     referenced here — this table records relationships only, never
--     counters.
--   - Reward logic of any kind (m.PXN, miner, milestones, monthly
--     leaderboard) is NOT implemented here — this table has no reward
--     columns and no reward side effects.
--
-- Immutability: a referred account can have exactly one referrer, for
-- its entire lifetime. This is enforced below by a UNIQUE constraint
-- on referred_user_id alone (not a composite key) — a given
-- referred_user_id can appear at most once in this table, ever, so
-- there is no UPDATE path (now or later) that could ever re-point an
-- existing row's referrer_user_id; the relationship a row records is
-- permanent from the moment it is inserted.
--
-- Self-referral: made impossible at the database level by a CHECK
-- constraint (referrer_user_id <> referred_user_id), independent of
-- and in addition to whatever application-level check a future
-- record_pending_referral() RPC performs — even a bug in that future
-- RPC could not insert a self-referral row.
--
-- Trust model: every column here is server-authoritative. RLS is
-- enabled with ZERO policies for anon/authenticated — under Postgres
-- RLS, a table with RLS enabled and no matching policy denies that
-- role every operation (select/insert/update/delete) by default. This
-- table is therefore fully server-mediated: the only way any row is
-- ever created or transitioned is a future service_role-only RPC
-- (record_pending_referral / qualify_referral / flag_referral /
-- admin_review_referral — none of which exist yet), called from an
-- Edge Function using the service_role key, exactly like
-- public.admin_users and the write side of public.mining_state /
-- public.mining_inventory. No public read policy is added in this
-- migration — nothing in the locked design requires the client to
-- read this table directly yet (the frontend will eventually read a
-- player's referral progress via mining_state.referral_count, a
-- separate, already-existing column this migration does not touch).
--
-- qualification_eligible_at: intentionally NOT NULL with NO DEFAULT.
-- Per the locked design, this timestamp is computed by the future
-- record_pending_referral() RPC as
-- (created_at + referral_config.cooldown_hours) — a business value
-- that does not exist yet, since referral_config does not exist yet.
-- Adding any default here (e.g. now(), or now() + some hardcoded
-- interval) would silently encode a cooldown business rule into the
-- schema itself, ahead of and independent from referral_config —
-- exactly what this step must avoid. Leaving it NOT NULL with no
-- default is the safest option available now: it does not prevent
-- creating this (currently empty) table, and it forces every future
-- INSERT — i.e. record_pending_referral() once it exists — to supply
-- this value explicitly rather than silently inheriting a
-- schema-level guess.

create table public.referrals (
  id                          uuid        primary key default gen_random_uuid(),

  -- The inviter. Never changes after insert (see immutability note
  -- above) — there is no code path, now or planned, that updates this
  -- column.
  referrer_user_id            uuid        not null references public.users(id) on delete cascade,

  -- The invited (new) account. UNIQUE below: at most one referral row
  -- can ever exist per referred_user_id, for the lifetime of this
  -- table.
  referred_user_id            uuid        not null references public.users(id) on delete cascade,

  -- Raw referral code the referred user's session carried at signup
  -- (per the locked design, this is the referrer's own
  -- telegram_user_id as a decimal string) — stored verbatim for
  -- audit, never re-parsed as trusted input after insert.
  start_param_used            text        not null,

  -- Relationship lifecycle. See FINAL LOCKED DESIGN for the full
  -- state machine (pending -> qualified | flagged -> qualified |
  -- rejected). qualify_referral() is the only place referral_count
  -- (on mining_state, a different table, untouched here) is ever
  -- incremented, and only on the qualified transition — nothing about
  -- that logic exists yet as of this migration.
  status                      text        not null default 'pending'
                                check (status in ('pending', 'qualified', 'flagged', 'rejected')),

  created_at                  timestamptz not null default now(),

  -- Earliest moment this pending referral may be evaluated for
  -- qualification. NOT NULL, NO DEFAULT — see header comment. Must be
  -- supplied explicitly by the inserting caller (the future
  -- record_pending_referral() RPC) using the cooldown value in effect
  -- at insert time from the not-yet-existing referral_config table.
  qualification_eligible_at   timestamptz not null,

  qualified_at                timestamptz,
  rejected_at                 timestamptz,
  rejection_reason            text,
  flagged_at                  timestamptz,
  flag_reason                 text,

  -- Set only when an admin actions a flagged/rejected row via the
  -- (not yet implemented) admin review RPC. References auth.users(id)
  -- — the shared identity space every authenticated Supabase session
  -- uses — exactly like public.admin_users.user_id and
  -- mining_config.updated_by_admin, not public.users(id).
  reviewed_by_admin_user_id   uuid        references auth.users(id),
  reviewed_at                 timestamptz,

  -- Provenance marker only (which server process created this row).
  -- Not an authorization mechanism — RLS/service_role-only access is
  -- what actually restricts row creation.
  created_by                  text        not null default 'auth-telegram',

  -- One referred account, one referral relationship, ever.
  constraint referrals_referred_user_id_key unique (referred_user_id),

  -- Self-referral is impossible at the database level.
  constraint referrals_no_self_referral check (referrer_user_id <> referred_user_id)
);

comment on table public.referrals is
  'Immutable, one-time referral relationship between a referrer and a referred Telegram account. Schema only as of 0043_create_referrals.sql: no RPC, no Edge Function wiring, no reward logic, and referral_count (on public.mining_state) is neither read nor written here. A referred_user_id can appear at most once in this table for its entire lifetime (referrals_referred_user_id_key); referrer_user_id can never be re-pointed once inserted. Self-referral is blocked by referrals_no_self_referral. RLS is enabled with zero policies for anon/authenticated: every row is created and transitioned exclusively by future service_role-only RPCs (record_pending_referral / qualify_referral / flag_referral / admin_review_referral — none exist yet), never directly by a client.';

comment on column public.referrals.referrer_user_id is
  'The inviting player. Immutable once set — no UPDATE path exists or is planned for this column.';
comment on column public.referrals.referred_user_id is
  'The invited (new) player. Unique across this entire table (see referrals_referred_user_id_key): a given account can be referred at most once, ever.';
comment on column public.referrals.start_param_used is
  'Raw referral code seen at signup, stored verbatim for audit. Per the locked design this is the referrer''s own telegram_user_id as a decimal string — resolved to referrer_user_id by a future record_pending_referral() RPC, not re-parsed from this column after insert.';
comment on column public.referrals.status is
  'Lifecycle state: pending (just created, not yet evaluated) -> qualified (hard rules passed; the only status from which mining_state.referral_count is ever incremented, by future logic not present in this migration) | flagged (a soft fraud signal fired; awaits admin review) -> qualified | rejected (terminal).';
comment on column public.referrals.qualification_eligible_at is
  'Earliest moment this row may be evaluated for qualification. Intentionally NOT NULL with no schema-level default: the real value (created_at + a cooldown) depends on public.referral_config, which does not exist as of this migration. Must be supplied explicitly by the inserting caller.';
comment on column public.referrals.created_by is
  'Provenance marker only (e.g. ''auth-telegram''), not an authorization mechanism — access control is enforced entirely by RLS/service_role, not by this column.';

-- ---------------------------------------------------------------
-- Indexes.
-- ---------------------------------------------------------------

-- "Give me this referrer's referrals, optionally filtered by status"
-- — used by qualification/leaderboard logic added in later steps, and
-- by any future admin view of a single referrer's history.
create index referrals_referrer_user_id_status_idx
  on public.referrals (referrer_user_id, status);

-- "Give me pending rows whose cooldown has already elapsed" — the
-- exact access pattern a future qualification sweep needs. Partial,
-- so the index stays small and only ever contains currently-pending
-- rows.
create index referrals_pending_eligible_idx
  on public.referrals (status, qualification_eligible_at)
  where status = 'pending';

-- "Give me every flagged row" — the future admin review queue's
-- access pattern. Partial for the same reason as above.
create index referrals_flagged_idx
  on public.referrals (status)
  where status = 'flagged';

-- ---------------------------------------------------------------
-- Row Level Security.
-- ---------------------------------------------------------------

alter table public.referrals enable row level security;

-- No policy is created here for anon or authenticated, for any
-- operation (select/insert/update/delete). Under Postgres RLS, a
-- table with RLS enabled and no matching policy for a role denies
-- that role every operation by default — so no authenticated player,
-- referrer or referred, can read, insert, update, or delete rows in
-- this table directly, no matter what client-side code claims. Only
-- service_role (which bypasses RLS entirely, same as every other
-- privileged table in this schema — public.admin_users,
-- public.mpxn_ledger, the write side of public.mining_state /
-- public.mining_inventory) can ever touch this table, via future
-- RPCs called from Edge Functions. No public/authenticated read
-- policy is added in this migration either — nothing in the locked
-- design requires direct client reads of public.referrals; a
-- player's own referral progress is surfaced via
-- mining_state.referral_count, which this migration does not modify.

-- ---------------------------------------------------------------
-- No other table, function, policy, or grant is created, altered, or
-- dropped by this migration. No existing migration (0000-0042) is
-- modified. No row is seeded here — public.referrals starts empty
-- and stays empty until a future record_pending_referral() RPC (not
-- part of this migration) begins inserting into it.
-- ---------------------------------------------------------------
