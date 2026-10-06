-- Pro-X Network — Friends Referral system: qualification/snapshot
-- configuration.
--
-- Table: public.referral_config.
--
-- Context: per the FINAL LOCKED referral design (Design Revision v2),
-- this migration implements ONLY the server-controlled configuration
-- table that later referral logic will read. This is SCHEMA (+ one
-- seed row) ONLY: no RPC, no Edge Function, and no wiring into any
-- caller is created by this migration. The columns below are read
-- by, but not yet referenced from:
--   - record_pending_referral()          (does not exist yet)
--   - qualify_referral()                 (does not exist yet)
--   - the referral-qualification-sweep Edge Function (does not exist yet)
--   - snapshot_monthly_referrals()       (does not exist yet)
-- None of the above are created, altered, or called by this
-- migration. 0043_create_referrals.sql is not modified. No other
-- existing migration (0000-0043) is modified.
--
-- Explicitly NOT touched by this migration: public.users,
-- public.mining_state, public.mining_config, public.referrals,
-- public.mpxn_ledger, public.miner_catalog, public.mining_inventory.
-- No referral_count, reward, monthly-leaderboard, or milestone column
-- is added anywhere by this migration — this table holds qualification
-- THRESHOLDS and snapshot SIZING only, never counters, never rewards.
-- Telegram start_param handling is also not touched here — that lives
-- entirely in the (not yet modified) auth-telegram function and the
-- (not yet created) record_pending_referral() RPC.
--
-- Singleton pattern: this table is intended to hold exactly one
-- global configuration row. Rather than mining_config's
-- append-only/is_active history (appropriate there because past
-- mining-formula values must remain reconstructable for dispute
-- resolution), this follows the OTHER singleton convention already
-- established in this schema by public.marketplace_config
-- (0032_marketplace_tables.sql): `id boolean primary key default true
-- check (id = true)` physically prevents a second row from ever being
-- inserted (there is only one possible primary key value), and
-- "changing the config" means UPDATE-in-place on that one row, with
-- updated_at/updated_by_admin_user_id recording the most recent
-- change. This is the right choice here because, unlike mining-formula
-- values, referral qualification thresholds have no per-referral
-- historical-reconstruction requirement in the locked design — each
-- pending referral instead freezes the specific values it needs
-- (e.g. qualification_eligible_at, computed from cooldown_hours) onto
-- itself at insert time (see 0043_create_referrals.sql), so the
-- config row itself does not need to preserve prior versions.
--
-- Access model: exactly like mining_config (0003) and
-- marketplace_config (0032), this is an admin/service-role-only
-- concern. RLS is enabled with ZERO policies for anon/authenticated —
-- under Postgres RLS this denies every operation (select included) to
-- those roles by default. The frontend never needs to read
-- referral_config directly today: nothing in the locked design
-- surfaces raw threshold values to the player (a player's own
-- referral progress is read from mining_state.referral_count, a
-- different, already-existing column, untouched here). Only
-- service_role (inside future Edge Functions/RPCs) can ever read or
-- write this table.
--
-- snapshot_pool_size: controls how many top-ranked candidates a
-- future snapshot_monthly_referrals() freezes into the monthly review
-- pool (per the locked design's promotion mechanism: rank 1-10 are
-- paid, ranks past 10 up to snapshot_pool_size sit in reserve so a
-- rejected top-10 entry can be deterministically replaced from an
-- already-frozen list). The value read here at the moment a given
-- month's snapshot is taken becomes fixed on that period's frozen
-- rows going forward — a later change to this column never resizes
-- a month that has already been snapshotted. None of that
-- snapshot/promotion logic is implemented by this migration; only the
-- configuration knob itself is created here.

create table public.referral_config (
  -- Physically forces exactly one row: boolean has only two possible
  -- values, and the CHECK further restricts it to true, so a second
  -- INSERT can only ever collide with this same primary key.
  id                          boolean       primary key default true
                                check (id = true),

  -- ---- qualification thresholds (read by the future
  --      qualify_referral() / qualification-sweep) ----

  -- Minimum age (hours) of the REFERRED account before its referral
  -- can qualify. Configuration only; no qualification code reads this
  -- yet.
  min_account_age_hours       integer       not null default 24
                                check (min_account_age_hours >= 0),

  -- Minimum time (hours) between a referrals row's created_at and the
  -- earliest moment it may be evaluated. The future
  -- record_pending_referral() RPC is expected to compute
  -- referrals.qualification_eligible_at as created_at + this value,
  -- read at insert time — not implemented by this migration.
  cooldown_hours               integer       not null default 24
                                check (cooldown_hours >= 0),

  -- Minimum public.mining_state.claim_count the referred user must
  -- have reached to qualify.
  min_claim_count              integer       not null default 1
                                check (min_claim_count >= 0),

  -- Minimum public.mining_state.level the referred user must have
  -- reached to qualify.
  min_level                    integer       not null default 1
                                check (min_level >= 1),

  -- Minimum public.mining_state.mined_balance_total the referred user
  -- must have accrued to qualify. numeric(20,8) matches
  -- mining_state.mined_balance_total's own column type
  -- (0013_mining_state.sql) so a future comparison never needs an
  -- implicit cast.
  min_mined_balance_total      numeric(20,8) not null default 0
                                check (min_mined_balance_total >= 0),

  -- Whether a banned referrer or referred user (public.users.is_banned)
  -- permanently blocks qualification. Stored as a toggle rather than
  -- hardcoded true in application logic solely so the rule is visible
  -- and auditable alongside every other qualification setting here —
  -- the locked design treats bans as a hard rule, not a product
  -- decision expected to ever be turned off in practice.
  exclude_banned                boolean       not null default true,

  -- ---- burst/fraud-flagging thresholds (read by the future
  --      qualification sweep) ----

  -- Rolling window (minutes) used to detect referral bursts from a
  -- single referrer.
  burst_window_minutes          integer       not null default 60
                                check (burst_window_minutes >= 1),

  -- Maximum new pending referrals a single referrer may accumulate
  -- within burst_window_minutes before further referrals in that
  -- burst are flagged rather than auto-qualified.
  burst_max_referrals           integer       not null default 10
                                check (burst_max_referrals >= 1),

  -- ---- monthly snapshot sizing (read by the future
  --      snapshot_monthly_referrals()) ----

  -- How many top-ranked candidates are frozen into the monthly review
  -- pool. Must be at least 10, since ranks 1-10 are always the paid
  -- slots per the locked design; values above 10 are the reserve pool
  -- available for promotion if a top-10 entry is later rejected.
  snapshot_pool_size             integer       not null default 15
                                check (snapshot_pool_size >= 10),

  -- ---- audit / admin bookkeeping ----

  created_at                     timestamptz   not null default now(),
  updated_at                     timestamptz   not null default now(),

  -- Which admin (if any) most recently updated this row via a future
  -- admin config-update RPC. References auth.users(id) — the shared
  -- identity space every authenticated Supabase session uses — the
  -- same pattern already established by mining_config.updated_by_admin
  -- (0041_admin_mining_config_control.sql). Null for this migration's
  -- system seed row, since no admin action produced it.
  updated_by_admin_user_id       uuid          references auth.users(id)
);

comment on table public.referral_config is
  'Singleton (id is always true — the primary key + CHECK physically forbid a second row) server-controlled configuration for referral qualification and monthly snapshot sizing. Every value here is a configuration DEFAULT/THRESHOLD only, not qualification or reward logic itself: no RPC or Edge Function reads or writes this table as of 0044_create_referral_config.sql. Read-only for future qualification/sweep/snapshot logic; never written by anon/authenticated (RLS enabled, zero client policies).';
comment on column public.referral_config.cooldown_hours is
  'Minimum hours between a referrals row''s created_at and its earliest possible qualification evaluation. A future record_pending_referral() RPC is expected to compute referrals.qualification_eligible_at from this value at insert time; that RPC does not exist as of this migration.';
comment on column public.referral_config.exclude_banned is
  'Whether a banned referrer or referred user (public.users.is_banned) permanently blocks qualification. A configuration toggle, exposed for auditability alongside the other thresholds here, not application-hardcoded logic.';
comment on column public.referral_config.snapshot_pool_size is
  'How many top-ranked candidates a future snapshot_monthly_referrals() freezes into the monthly review pool (ranks 1-10 are always the paid slots; ranks above 10 up to this value are the reserve pool used for deterministic promotion if a top-10 entry is later rejected). The value in effect at the moment a given period is snapshotted is what freezes onto that period''s rows — a later change to this column never resizes an already-snapshotted month. Not read by any function created in this migration.';
comment on column public.referral_config.updated_by_admin_user_id is
  'auth.users(id) of the admin who most recently updated this row via a future admin config-update RPC, for audit purposes only — mirrors mining_config.updated_by_admin''s role (0041_admin_mining_config_control.sql). Null on this migration''s system seed row.';

-- Reuse the existing shared trigger function from 0001_helpers.sql —
-- the same one already attached to public.marketplace_config
-- (0032_marketplace_tables.sql), the other singleton-config table in
-- this schema — rather than redefining update-timestamp logic here.
create trigger referral_config_set_updated_at
  before update on public.referral_config
  for each row execute function public.set_updated_at();

alter table public.referral_config enable row level security;

-- No SELECT/INSERT/UPDATE/DELETE policy for anon/authenticated on
-- this table at all — the same "RLS enabled, zero policies = default
-- deny for those roles" pattern as mining_config (0003) and
-- marketplace_config (0032). Referral configuration is an
-- admin/service-role concern only; the frontend does not need to read
-- this row directly (a player's own referral progress is surfaced via
-- mining_state.referral_count, a separate, already-existing column
-- this migration does not touch). Only service_role, from inside a
-- future Edge Function/RPC, can ever read or write this table.

-- Seed the single required config row, using the FINAL LOCKED DESIGN
-- defaults verbatim. Written with explicit values (rather than
-- relying solely on column defaults) so this migration's seed data is
-- self-documenting and independent of the column defaults ever being
-- edited by a later migration. ON CONFLICT (id) DO NOTHING makes this
-- insert safe to re-run (e.g. if this migration were ever replayed
-- against a database where the row already exists) without erroring
-- or overwriting a value an admin may have already changed via a
-- future config RPC.
insert into public.referral_config (
  id, min_account_age_hours, cooldown_hours, min_claim_count, min_level,
  min_mined_balance_total, exclude_banned, burst_window_minutes,
  burst_max_referrals, snapshot_pool_size
) values (
  true, 24, 24, 1, 1,
  0, true, 60,
  10, 15
)
on conflict (id) do nothing;

-- ---------------------------------------------------------------
-- No other table, function, policy, or grant is created, altered, or
-- dropped by this migration. No existing migration (0000-0043) is
-- modified. Nothing calls or reads public.referral_config yet — that
-- begins only once record_pending_referral() / qualify_referral() /
-- the qualification sweep / snapshot_monthly_referrals() are
-- implemented in later, separate steps.
-- ---------------------------------------------------------------
