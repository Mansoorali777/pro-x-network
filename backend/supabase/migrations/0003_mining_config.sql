-- Pro-X Network — Authoritative mining configuration.
--
-- Table: mining_config.
--
-- This is schema only, per the approved architecture review. It does
-- NOT create mining_state or mining_inventory (later steps), does NOT
-- create any Edge Function, and does NOT change any value the game
-- currently uses — every default below is copied verbatim from the
-- live client code (index.html REWARDS_CONFIG / DEFAULT_UPGRADES /
-- DEFAULT_BASE_SPEED, and admin.html's mirrored defaults) so that,
-- once an Edge Function reads from this table instead of the client
-- computing locally, player-visible behavior does not change.
--
-- Design: append-only history, not update-in-place. Config "changes"
-- are modeled as inserting a new row and flipping is_active, so there
-- is always an audit trail of exactly what values were live at any
-- point in time (useful if a claim is ever disputed). Rows are never
-- expected to be UPDATEd after insert.
--
-- Access model: every numeric value here feeds directly into accrual,
-- claim, or level-up math (or, in ad_sim_seconds' case, ships as part
-- of the same REWARDS_CONFIG object today) — see the architecture
-- report's "security-critical values" section. Per that report, NO
-- client role (anon or authenticated) may read or write this table
-- directly. RLS is enabled with zero policies for those roles, which
-- means Postgres denies all access to them by default. Only
-- service_role (used exclusively inside Edge Functions, per the
-- 0001_helpers.sql auth-assumption comment) can read or write, since
-- service_role bypasses RLS entirely by design.

create table public.mining_config (
  id                        uuid        primary key default gen_random_uuid(),

  -- ---- accrual / speed (from index.html DEFAULT_BASE_SPEED + REWARDS_CONFIG) ----

  -- Fixed baseline mining speed every player has for free, regardless
  -- of owned miner tiers. index.html: DEFAULT_BASE_SPEED = 0.10.
  base_speed                numeric(10,4) not null default 0.1000
                              check (base_speed >= 0),

  -- One-time PXN credit paid per referral. REWARDS_CONFIG.referralInstant = 50.
  referral_instant_pxn      numeric(12,2) not null default 50.00
                              check (referral_instant_pxn >= 0),

  -- Mining-speed add per referral. REWARDS_CONFIG.referralSpeedBonus = 0.05.
  referral_speed_bonus      numeric(10,4) not null default 0.0500
                              check (referral_speed_bonus >= 0),

  -- Generic boost multiplier + duration. REWARDS_CONFIG.boostMultiplier = 2,
  -- boostDurationMin = 30.
  boost_multiplier          numeric(6,2)  not null default 2.00
                              check (boost_multiplier > 0),
  boost_duration_min        integer       not null default 30
                              check (boost_duration_min > 0),

  -- Tap-triggered boost. REWARDS_CONFIG.tapBoostMultiplier = 2,
  -- tapBoostDurationSec = 10.
  tap_boost_multiplier      numeric(6,2)  not null default 2.00
                              check (tap_boost_multiplier > 0),
  tap_boost_duration_sec    integer       not null default 10
                              check (tap_boost_duration_sec > 0),

  -- Ad-boost eligibility + effect. REWARDS_CONFIG.adsRequiredForBoost = 5,
  -- adBoostMultiplier = 2, adBoostDurationHours = 8.
  ads_required_for_boost    integer       not null default 5
                              check (ads_required_for_boost > 0),
  ad_boost_multiplier       numeric(6,2)  not null default 2.00
                              check (ad_boost_multiplier > 0),
  ad_boost_duration_hours   integer       not null default 8
                              check (ad_boost_duration_hours > 0),

  -- Simulated ad length. REWARDS_CONFIG.adSimSeconds = 5. UX timing
  -- only (no currency impact) but kept here since it ships as part of
  -- the same REWARDS_CONFIG object today — preserved, not invented.
  ad_sim_seconds            integer       not null default 5
                              check (ad_sim_seconds >= 0),

  -- Leveling. REWARDS_CONFIG.levelUpCostPxn = 100,
  -- levelBoostPercent = 0.05 (stored as a fraction, matching current usage).
  level_up_cost_pxn         numeric(12,2) not null default 100.00
                              check (level_up_cost_pxn >= 0),
  level_boost_percent       numeric(6,4)  not null default 0.0500
                              check (level_boost_percent >= 0),

  -- Offline-accrual cap. index.html MAX_OFFLINE_ACCRUAL_SEC = 24*3600.
  max_offline_accrual_sec   integer       not null default 86400
                              check (max_offline_accrual_sec > 0),

  -- PXN swap rate. index.html/admin.html PXN_SWAP_RATE / token.pxnSwapRate = 1.
  pxn_swap_rate             numeric(10,4) not null default 1.0000
                              check (pxn_swap_rate >= 0),

  -- ---- miner tiers (from index.html DEFAULT_UPGRADES / admin.html DEFAULT_MINERS) ----
  --
  -- All 7 current tiers, {level, name, cost, speed} only. `icon` is
  -- intentionally excluded: it is cosmetic (a data-URI image) and has
  -- no bearing on mining math, so it does not belong in an
  -- authoritative security-critical config table.
  miner_tiers               jsonb       not null default '[
    {"level": 1, "name": "Miner Power",           "cost": 0,     "speed": 0.10},
    {"level": 2, "name": "Reinforced Bore Rig",   "cost": 200,   "speed": 0.22},
    {"level": 3, "name": "Cryo-Cooled Extractor", "cost": 650,   "speed": 0.45},
    {"level": 4, "name": "Plasma Cutter Array",   "cost": 1800,  "speed": 0.90},
    {"level": 5, "name": "Quantum Drill Core",    "cost": 4500,  "speed": 1.75},
    {"level": 6, "name": "Deep Vein Harvester",   "cost": 11000, "speed": 3.40},
    {"level": 7, "name": "Fusion Mining Node",    "cost": 26000, "speed": 6.50}
  ]'::jsonb
                              check (jsonb_typeof(miner_tiers) = 'array'),

  -- ---- bookkeeping ----

  -- Whether this is the currently-live configuration. Exactly one row
  -- may have is_active = true at any time (enforced below).
  is_active                 boolean     not null default true,

  -- Which admin (if any) created this row via the future admin
  -- config-update Edge Function. Null for this migration's system
  -- seed row, since no admin action produced it.
  created_by                uuid        references public.users(id),

  created_at                timestamptz not null default now()
);

comment on table public.mining_config is
  'Authoritative, append-only mining configuration. Every column here is security-critical input to server-side accrual/claim/level-up math. No anon/authenticated access — service_role only, via Edge Functions.';
comment on column public.mining_config.is_active is
  'Exactly one row is active at a time; "updating config" means inserting a new row and deactivating the old one, never editing values in place.';
comment on column public.mining_config.miner_tiers is
  'Array of {level, name, cost, speed}. icon is intentionally excluded — cosmetic only, not authoritative.';

-- Enforce "exactly one active row" at the database level: a partial
-- unique index on a constant expression, scoped to is_active = true,
-- means a second `is_active = true` row cannot be inserted without
-- first deactivating the current one.
create unique index mining_config_one_active_idx
  on public.mining_config ((true))
  where is_active;

alter table public.mining_config enable row level security;

-- No policies are created for anon or authenticated on purpose: with
-- RLS enabled and zero policies, Postgres denies all access to those
-- roles by default. service_role bypasses RLS entirely and is the
-- only way this table is ever read or written, from inside Edge
-- Functions.

-- Seed exactly one active row using the defaults declared above (i.e.
-- today's live game values). No explicit column list values are
-- overridden here — this INSERT relies on the column defaults so the
-- seeded row and the schema defaults can never drift apart.
insert into public.mining_config (created_by) values (null);
