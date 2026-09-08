-- Pro-X Network — Per-player miner inventory.
--
-- Table: mining_inventory.
--
-- Context: public.mining_config.miner_tiers (see 0003_mining_config.sql)
-- is the GLOBAL miner catalog only — it describes what miner tiers
-- exist in the game, not what any individual player owns. This
-- migration adds the missing per-player ownership table: one row per
-- miner UNIT a player owns.
--
-- This is schema only, per the approved architecture review. It does
-- NOT implement purchase, level-up, "apply to state", or any other
-- write logic — those are later steps, each targeting one system at
-- a time (mirroring 0013_mining_state.sql). It does NOT touch
-- index.html, js/api-client.js, js/auth-client.js,
-- accrue-mining/index.ts, PLAYER_ID, Telegram auth, TON/PXN wallet
-- logic, claim/rewards logic, mining_config, or mining_state.
--
-- Identity: user_id is auth.uid(), i.e. public.users.id — the real,
-- Telegram-signature-verified identity (see 0001_helpers.sql's
-- auth-assumption comment).
--
-- Cardinality: intentionally many-rows-per-player. Unlike
-- mining_state (exactly one row per player), a player can own
-- multiple miner units of the same tier — e.g. three Tier-2 miners —
-- so there is deliberately NO unique constraint on (user_id,
-- miner_tier). Each row is one owned miner unit.
--
-- Trust model: every column here is server-authoritative. No client
-- role may ever insert, update, or delete a row directly — a
-- player's inventory rows are created/mutated later by backend
-- Edge Functions (purchase, level-up, apply, etc.) using the
-- service_role key, which bypasses RLS entirely by design — the same
-- pattern already used for public.users, public.mining_config, and
-- public.mining_state.

create table public.mining_inventory (
  -- Surrogate primary key. Unlike mining_state, this table is not
  -- 1:1 with players — a player can own many miner units — so
  -- user_id cannot itself be the primary key.
  id                uuid        primary key default gen_random_uuid(),

  -- Owning player. Always equals auth.uid() for that player once RLS
  -- is enforced below.
  user_id           uuid        not null references public.users(id) on delete cascade,

  -- Which catalog tier (public.mining_config.miner_tiers) this unit
  -- was purchased/granted as. Stored as a plain integer, not a
  -- foreign key, per this step's scope (schema only for inventory;
  -- cross-referencing the catalog table is left to the
  -- server-side logic that writes these rows).
  miner_tier        integer     not null
                      check (miner_tier >= 1),

  -- Denormalized display fields, captured at grant/purchase time so
  -- the frontend can render an owned miner without an extra join
  -- back to the (server-writable-only) catalog.
  miner_name        text        not null,
  miner_icon        text,

  -- Per-unit progression. A player can level up individual owned
  -- miners independently of the global catalog tier definition.
  miner_level       integer     not null default 1
                      check (miner_level >= 1),

  -- Per-unit mining speed contribution. Server-computed and
  -- server-written only; never accepted as a client-supplied value.
  miner_speed       numeric(20,8) not null default 0
                      check (miner_speed >= 0),

  -- Whether this specific unit is currently applied/active toward
  -- the player's mining_state accrual. Whatever "only N slots
  -- applied at once" rule (if any) the game design settles on is
  -- enforced by the server-side write path, not by a constraint in
  -- this migration.
  is_applied        boolean     not null default false,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table public.mining_inventory is
  'Per-player miner ownership: one row per owned miner unit, keyed by user_id = auth.uid() (= public.users.id). A player may own multiple units of the same miner_tier — there is no unique constraint on (user_id, miner_tier) by design. Every column is server-authoritative: the client must never directly write miner_tier, miner_level, miner_speed, or is_applied. Rows are created/mutated later by backend Edge Functions, not seeded by this migration and not insertable/updatable by the client.';
comment on column public.mining_inventory.miner_tier is
  'References the catalog tier defined in public.mining_config.miner_tiers, but is stored as a plain integer (not a foreign key) in this step.';
comment on column public.mining_inventory.is_applied is
  'Whether this owned miner unit is currently active toward the player''s mining_state accrual. Server-written only.';

-- Reuse the existing shared trigger function from 0001_helpers.sql —
-- confirmed present there (public.set_updated_at()) — rather than
-- redefining it here.
create trigger mining_inventory_set_updated_at
  before update on public.mining_inventory
  for each row execute function public.set_updated_at();

-- Lookup indexes. Every expected query pattern for this table is
-- "give me this player's inventory" (user_id) or "give me this
-- player's currently-applied miners" (user_id + is_applied).
create index mining_inventory_user_id_idx
  on public.mining_inventory (user_id);

create index mining_inventory_user_id_is_applied_idx
  on public.mining_inventory (user_id, is_applied);

alter table public.mining_inventory enable row level security;

-- A player may read their own inventory rows (needed by the frontend
-- to render owned miners once wired up in a later step). No INSERT,
-- UPDATE, or DELETE policy is created for authenticated or anon:
-- with RLS enabled and no matching policy, Postgres denies those
-- operations to those roles by default. All mutations happen via
-- service_role inside future Edge Functions (purchase, level-up,
-- apply, etc.), which bypass RLS entirely by design — the same
-- pattern already used for public.users, public.mining_config, and
-- public.mining_state.
create policy "mining_inventory_select_own"
  on public.mining_inventory
  for select
  to authenticated
  using (auth.uid() = user_id);

-- No rows are seeded here. mining_inventory starts empty for every
-- player and is populated later by the backend (e.g. on purchase),
-- not by this migration.
