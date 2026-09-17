-- Pro-X Network — Marketplace schema foundation (m.PXN migration, step 1 of N).
--
-- Tables: public.marketplace_listings, public.marketplace_offers,
--         public.marketplace_config.
--
-- Context: the Telegram Mini App Marketplace currently runs entirely
-- client-side against localStorage-tracked PXN — no server table
-- backs a listing or an offer today, and no balance movement it
-- causes is authoritative. This migration lays the server-authoritative
-- database foundation for that feature, priced and settled in m.PXN
-- (mining_state.claimed_total via public.adjust_claimed_total(),
-- 0030_mpxn_ledger_primitive.sql) rather than the separate/legacy
-- pxn_balance column (0015_pxn_balance_security.sql) — the two
-- currencies must never share a code path, and this migration does
-- not reference pxn_balance anywhere.
--
-- Scope of THIS migration (schema only, mirroring the discipline of
-- 0013_mining_state.sql / 0014_mining_inventory.sql / the
-- 0030_mpxn_ledger_primitive.sql "inert on arrival" pattern):
--   - Creates the three marketplace tables below.
--   - Enables RLS on all three and adds safe, read-only SELECT
--     policies only (see the per-table RLS notes).
--   - Adds the indexes the intended query patterns need.
--   - Seeds nothing except the single required marketplace_config row.
--
-- Explicitly OUT of scope for this migration (per the approved plan —
-- later steps, not this file):
--   - No marketplace RPCs (list/offer/accept/cancel/buy) are created
--     here. All marketplace mutations will be SECURITY DEFINER,
--     service-role-only functions added in a later migration, calling
--     public.adjust_claimed_total() for every m.PXN movement — exactly
--     as level_up_mining() (0031) already does. Until that migration
--     lands, these tables are inert: nothing reads or writes them.
--   - No INSERT/UPDATE/DELETE policy is added for anon or authenticated
--     on any of these three tables. With RLS enabled and no such
--     policy, Postgres denies those operations to those roles by
--     default — the same "service_role bypasses RLS, is the only
--     writer" pattern already used by mining_inventory (0014),
--     mining_state (0013), and mpxn_ledger (0030).
--   - No existing table, column, function, or RLS policy is touched.
--     claim_mining (0027), purchase_miner (0028), upgrade_miner
--     (0029), level_up_mining (0031), and adjust_claimed_total (0030)
--     are all unmodified.
--   - No change to index.html or js/api-client.js.
--
-- Marketplace fee destination: per product decision, the marketplace
-- fee is credited to TREASURY (a single designated user's
-- mining_state.claimed_total, via adjust_claimed_total() with reason
-- 'market_fee_treasury_credit' in the later RPC migration) —
-- marketplace_config.fee_recipient_user_id names that treasury
-- account. It is nullable here only because this migration does not
-- know the treasury account's id yet; the later RPC migration's
-- sell/accept-offer function should treat a null fee_recipient_user_id
-- as a hard server-misconfiguration error, not as "skip the fee".
--
-- Offer privacy (enforced below via RLS, not application logic):
--   - A buyer may read only the offers they themselves placed
--     (buyer_user_id = auth.uid()).
--   - A seller may read the offers placed on their own listings
--     (via a join back to marketplace_listings.seller_user_id).
--   - No other authenticated user, and no anon caller, can read any
--     offer row. There is deliberately no "select all offers" policy.

-- ---------------------------------------------------------------
-- public.marketplace_listings
-- ---------------------------------------------------------------
create table public.marketplace_listings (
  id                    uuid          primary key default gen_random_uuid(),

  -- Who is selling. Not on delete cascade from the seller's
  -- perspective alone — see the FK comment below — but the column
  -- itself always identifies the seller.
  seller_user_id        uuid          not null references public.users(id) on delete cascade,

  -- The specific owned miner unit (public.mining_inventory, see
  -- 0014_mining_inventory.sql) being listed. One inventory row can be
  -- referenced by at most one ACTIVE listing at a time — enforced by
  -- the partial unique index below, not by a CHECK here, since
  -- "active" is a runtime status, not a static property of the row.
  mining_inventory_id   uuid          not null references public.mining_inventory(id) on delete cascade,

  -- Seller's asking price, in m.PXN (mining_state.claimed_total
  -- terms) — never pxn_balance. Named *_mpxn, not pxn_*, throughout
  -- this migration specifically so it can never be confused with the
  -- legacy/future pxn_balance currency.
  asking_price_mpxn     numeric(20,8) not null
                          check (asking_price_mpxn > 0),

  status                text          not null default 'active'
                          check (status in ('active', 'sold', 'cancelled')),

  -- Populated only when status = 'sold'. Not a foreign key constraint
  -- forcing non-null together with status by itself — that pairing is
  -- the responsibility of the later sell/accept-offer RPC, which sets
  -- buyer_user_id, sold_at, and status atomically in one statement.
  buyer_user_id         uuid          references public.users(id) on delete set null,
  sold_at               timestamptz,

  created_at            timestamptz   not null default now(),
  updated_at            timestamptz   not null default now()
);

comment on table public.marketplace_listings is
  'Server-authoritative marketplace listings, priced and (eventually) settled in m.PXN (mining_state.claimed_total via adjust_claimed_total()) — never pxn_balance. Schema only as of this migration: no RPC yet creates, cancels, or settles a listing, and no INSERT/UPDATE/DELETE policy exists for anon/authenticated — all mutations will go through service-role-only SECURITY DEFINER functions added in a later migration.';
comment on column public.marketplace_listings.mining_inventory_id is
  'The specific owned miner unit (public.mining_inventory) being sold. At most one ACTIVE listing may reference a given inventory row at a time — see marketplace_listings_one_active_per_item below.';
comment on column public.marketplace_listings.asking_price_mpxn is
  'Seller''s asking price in m.PXN (mining_state.claimed_total terms). Never pxn_balance.';
comment on column public.marketplace_listings.status is
  'active: currently for sale. sold: settled (buyer_user_id/sold_at set). cancelled: withdrawn by the seller before any sale.';
comment on column public.marketplace_listings.buyer_user_id is
  'Set only when status = sold. ON DELETE SET NULL (not CASCADE) so a sold listing''s historical record survives the buyer account being removed; the seller''s own record of the sale is unaffected either way.';

-- At most one ACTIVE listing per inventory item — a player cannot
-- list the same owned miner unit for sale twice concurrently. Scoped
-- to status = 'active' (not a plain unique index) so a sold or
-- cancelled listing never blocks a later, brand-new listing of the
-- same (re-eligible) inventory row.
create unique index marketplace_listings_one_active_per_item
  on public.marketplace_listings (mining_inventory_id)
  where status = 'active';

-- Browse/query indexes for the intended access patterns: the
-- marketplace browse view filters on status = 'active' (and will
-- commonly order by created_at/asking_price_mpxn, both covered by
-- this composite index); a seller's "my listings" view and a buyer's
-- "who am I buying from" lookup both filter on the respective
-- *_user_id column.
create index marketplace_listings_active_idx
  on public.marketplace_listings (status, created_at desc)
  where status = 'active';

create index marketplace_listings_seller_user_id_idx
  on public.marketplace_listings (seller_user_id);

create index marketplace_listings_buyer_user_id_idx
  on public.marketplace_listings (buyer_user_id)
  where buyer_user_id is not null;

create trigger marketplace_listings_set_updated_at
  before update on public.marketplace_listings
  for each row execute function public.set_updated_at();

alter table public.marketplace_listings enable row level security;

-- Active listings are the public storefront: any authenticated player
-- can browse them, regardless of who is selling. This does not leak
-- anything sensitive — a listing's own columns (price, item, seller)
-- are exactly what a marketplace browse view is supposed to show.
create policy "marketplace_listings_select_active"
  on public.marketplace_listings
  for select
  to authenticated
  using (status = 'active');

-- A seller can additionally see their own listings regardless of
-- status (sold/cancelled included) — e.g. for a "my listings" /
-- sale-history view. Combined with the policy above via OR (Postgres
-- evaluates all matching permissive policies as an OR), this does not
-- narrow what an active listing's own seller can see.
create policy "marketplace_listings_select_own_seller"
  on public.marketplace_listings
  for select
  to authenticated
  using (auth.uid() = seller_user_id);

-- A buyer can see the (now sold) listing they bought, even though it
-- is no longer status = 'active' and even though they are not its
-- seller — needed for a "my purchases" view.
create policy "marketplace_listings_select_own_buyer"
  on public.marketplace_listings
  for select
  to authenticated
  using (auth.uid() = buyer_user_id);

-- No INSERT, UPDATE, or DELETE policy for anon/authenticated: listing
-- creation, cancellation, and sale settlement are all
-- service-role-only SECURITY DEFINER RPCs, added in a later
-- migration, exactly as purchase_miner/upgrade_miner/level_up_mining
-- are the only writers of their respective tables.

-- ---------------------------------------------------------------
-- public.marketplace_offers
-- ---------------------------------------------------------------
create table public.marketplace_offers (
  id                uuid          primary key default gen_random_uuid(),

  listing_id        uuid          not null references public.marketplace_listings(id) on delete cascade,

  buyer_user_id     uuid          not null references public.users(id) on delete cascade,

  -- Buyer's proposed price, in m.PXN — independent of (and may be
  -- below, at, or above) the listing's asking_price_mpxn. The later
  -- accept-offer RPC, not a CHECK here, decides whether/what
  -- relationship to asking_price_mpxn is required.
  offer_price_mpxn  numeric(20,8) not null
                      check (offer_price_mpxn > 0),

  status            text          not null default 'open'
                      check (status in ('open', 'accepted', 'rejected', 'cancelled')),

  created_at        timestamptz   not null default now(),
  updated_at        timestamptz   not null default now()
);

comment on table public.marketplace_offers is
  'Buyer-submitted offers against a marketplace_listings row, priced in m.PXN. PRIVATE by design: RLS below lets a buyer see only their own offers and a seller see only the offers on their own listings — no policy exposes any offer to an unrelated authenticated user. Schema only as of this migration: no RPC yet creates, accepts, rejects, or cancels an offer, and no INSERT/UPDATE/DELETE policy exists for anon/authenticated.';
comment on column public.marketplace_offers.offer_price_mpxn is
  'Buyer''s proposed price in m.PXN (mining_state.claimed_total terms). Never pxn_balance. Independent of the listing''s asking_price_mpxn.';
comment on column public.marketplace_offers.status is
  'open: awaiting seller decision. accepted: seller accepted (triggers settlement in the later RPC). rejected: seller declined. cancelled: withdrawn by the buyer before a decision.';

-- A given buyer may have at most one OPEN offer per listing — repeat
-- "bidding" against yourself on the same item is a superseding
-- update, not a second row, for the (later) offer RPC to enforce
-- against. Scoped to status = 'open' so a buyer whose earlier offer
-- was rejected/cancelled can freely place a new one.
create unique index marketplace_offers_one_open_per_buyer_listing
  on public.marketplace_offers (listing_id, buyer_user_id)
  where status = 'open';

-- Query indexes: a listing's seller needs "all open offers on this
-- listing" (listing_id, filtered/ordered by status); a buyer needs
-- "all of my own offers" (buyer_user_id); and the general
-- "offers for this listing" / "open offers system-wide" patterns are
-- covered by listing_id alone and the partial open-offers index
-- respectively.
create index marketplace_offers_listing_id_idx
  on public.marketplace_offers (listing_id);

create index marketplace_offers_buyer_user_id_idx
  on public.marketplace_offers (buyer_user_id);

create index marketplace_offers_open_idx
  on public.marketplace_offers (listing_id, created_at desc)
  where status = 'open';

create trigger marketplace_offers_set_updated_at
  before update on public.marketplace_offers
  for each row execute function public.set_updated_at();

alter table public.marketplace_offers enable row level security;

-- Buyer sees only their own offers (any status) — "my offers sent".
create policy "marketplace_offers_select_own_buyer"
  on public.marketplace_offers
  for select
  to authenticated
  using (auth.uid() = buyer_user_id);

-- Seller sees only the offers placed on listings THEY own — "offers
-- received". This is the join that keeps offers private to the
-- seller: an authenticated user who is neither the offer's buyer nor
-- the owning listing's seller matches neither this policy nor the one
-- above, and RLS default-denies them the row.
create policy "marketplace_offers_select_own_seller"
  on public.marketplace_offers
  for select
  to authenticated
  using (
    exists (
      select 1
        from public.marketplace_listings as l
       where l.id = marketplace_offers.listing_id
         and l.seller_user_id = auth.uid()
    )
  );

-- No INSERT, UPDATE, or DELETE policy for anon/authenticated: placing,
-- accepting, rejecting, and cancelling an offer are all
-- service-role-only SECURITY DEFINER RPCs, added in a later
-- migration.

-- ---------------------------------------------------------------
-- public.marketplace_config
-- ---------------------------------------------------------------
-- Single-row configuration table, following the exact
-- boolean-primary-key-defaulting-to-true pattern used wherever this
-- schema needs "exactly one settings row" (see mining_config's
-- analogous singleton convention) — the `primary key default true`
-- physically prevents a second row from ever being inserted.
create table public.marketplace_config (
  id                      boolean      primary key default true
                            check (id = true),

  -- Marketplace fee, in basis points (1 bps = 0.01%) of the sale
  -- price, taken out of the seller's proceeds and credited to
  -- fee_recipient_user_id (treasury) — computed and applied by the
  -- later settlement RPC, not by this migration.
  marketplace_fee_bps     integer      not null
                            check (marketplace_fee_bps >= 0 and marketplace_fee_bps <= 10000),

  -- Treasury account credited with the marketplace fee. Nullable
  -- here only because this migration does not itself seed a treasury
  -- user id (none is created by this migration) — the later
  -- settlement RPC must treat a null value here as a hard
  -- server-misconfiguration error, not as "waive the fee".
  fee_recipient_user_id   uuid         references public.users(id) on delete set null,

  active                  boolean      not null default true,

  updated_at              timestamptz  not null default now()
);

comment on table public.marketplace_config is
  'Singleton marketplace configuration row (id is always true — the primary key + CHECK physically forbids a second row). Read by the later marketplace RPCs to compute the treasury fee on a sale and to gate whether the marketplace is active; never written by anon/authenticated.';
comment on column public.marketplace_config.marketplace_fee_bps is
  'Marketplace fee in basis points (1 bps = 0.01%) of the sale price, deducted from the seller''s proceeds and credited to fee_recipient_user_id (treasury) by the later settlement RPC.';
comment on column public.marketplace_config.fee_recipient_user_id is
  'Treasury account (public.users.id) credited with the marketplace fee via adjust_claimed_total() in the later settlement RPC. A null value here must be treated by that RPC as a server-misconfiguration error, not as "no fee".';
comment on column public.marketplace_config.active is
  'Marketplace kill switch. When false, the later listing/offer/buy RPCs should refuse to create new listings/offers (existing rows are unaffected by this flag alone).';

create trigger marketplace_config_set_updated_at
  before update on public.marketplace_config
  for each row execute function public.set_updated_at();

alter table public.marketplace_config enable row level security;

-- No SELECT/INSERT/UPDATE/DELETE policy for anon/authenticated on
-- this table at all — same "RLS enabled, zero policies = default
-- deny for those roles" pattern as mining_config (0003) and
-- mpxn_ledger (0030). Marketplace configuration is an
-- admin/service-role concern only; the frontend never needs to read
-- this row directly (the later listing/browse RPCs read it
-- server-side and surface only what's needed, e.g. an effective
-- price after fee, to the client).

-- Seed the single required config row. fee_recipient_user_id is left
-- null here (no treasury user id is created by this migration) — an
-- admin path in a later migration is expected to set it before the
-- settlement RPC is ever exercised in production. marketplace_fee_bps
-- defaults to 250 (2.5%), a placeholder the product owner can update
-- via that same admin path; it is NOT NULL so a value must exist from
-- the moment this table exists.
insert into public.marketplace_config (id, marketplace_fee_bps, fee_recipient_user_id, active)
values (true, 250, null, true);

-- ---------------------------------------------------------------
-- Nothing calls or reads these tables yet. This migration is
-- intentionally inert, mirroring 0030_mpxn_ledger_primitive.sql: it
-- adds three new tables (with RLS and safe read-only policies) and
-- touches no existing table, column, RLS policy, or function.
-- claim_mining (0027), purchase_miner (0028), upgrade_miner (0029),
-- level_up_mining (0031), and adjust_claimed_total (0030) are all
-- unmodified. The marketplace RPCs that create/mutate rows in these
-- tables — and that call adjust_claimed_total() for every escrow,
-- sale, and fee movement — are a later migration (0033+), not this
-- one.
-- ---------------------------------------------------------------
