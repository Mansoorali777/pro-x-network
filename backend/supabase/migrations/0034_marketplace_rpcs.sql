-- Pro-X Network — Marketplace RPC layer (m.PXN migration, final step).
--
-- Functions: public.marketplace_create_listing, marketplace_cancel_listing,
--            marketplace_buy_listing, marketplace_make_offer,
--            marketplace_cancel_offer, marketplace_accept_offer,
--            marketplace_reject_offer.
--
-- Context: 0032_marketplace_tables.sql created marketplace_listings /
-- marketplace_offers / marketplace_config as inert schema, and
-- 0033_marketplace_inventory_custody.sql added mining_inventory.is_listed
-- plus the PXN29 custody guard inside set_miner_applied/upgrade_miner so
-- a listed unit cannot be re-slotted or upgraded out from under a
-- listing. Both migrations explicitly deferred every marketplace
-- mutation to "a later migration". This is that migration: the seven
-- server-authoritative RPCs that create, cancel, browse-buy, and
-- offer/accept/reject/cancel against those tables — the ONLY
-- functions that ever write marketplace_listings, marketplace_offers,
-- or mining_inventory.is_listed.
--
-- Currency: every balance movement here goes through the existing
-- public.adjust_claimed_total() primitive (0030_mpxn_ledger_primitive.sql)
-- against mining_state.claimed_total (m.PXN). Nothing in this
-- migration reads or writes pxn_balance, and no second balance-mutation
-- primitive is created — adjust_claimed_total() remains the only one.
--
-- Trust model: identical to every other RPC in this schema
-- (claim_mining/purchase_miner/set_miner_applied/upgrade_miner/
-- adjust_claimed_total/level_up_mining) — p_user_id-shaped parameters
-- are supplied by the calling Edge Function from a verified identity,
-- never read from a request body by these functions themselves, and
-- every function additionally scopes its own lock/read/write to the
-- rows that identity actually owns, regardless of what the caller
-- passes.
--
-- Lock ordering (deadlock avoidance):
--   - marketplace_cancel_listing / marketplace_buy_listing: listing
--     row locked FIRST, then its mining_inventory row.
--   - marketplace_accept_offer: offer row locked FIRST, then the
--     listing row, then the mining_inventory row, then every OTHER
--     still-open offer on that listing.
--   - Whenever more than one player's mining_state row must be
--     touched in a single transaction (marketplace_buy_listing:
--     buyer + seller + treasury; marketplace_accept_offer: seller +
--     treasury + the buyers of every refunded competing offer), every
--     such row is locked (FOR UPDATE) up front in one pass, in a
--     single global order — ascending by user_id — before any m.PXN
--     is moved. Sorting by a fixed key rather than by "role" (buyer
--     then seller then treasury) means two concurrent sales that
--     happen to involve the same two accounts in swapped roles can
--     never form a lock cycle: both transactions always lock the
--     lower user_id first. adjust_claimed_total() then re-locks each
--     row when it is called, which is instant since this transaction
--     already holds it.
--
-- New SQLSTATEs (continuing the existing PXN01-PXN29 sequence):
--   PXN30 — required parameter is null                              -> 400
--   PXN31 — asking_price_mpxn / offer_price_mpxn is not > 0          -> 400
--   PXN32 — inventory item not found, or not owned by p_user_id      -> 404
--   PXN33 — inventory item is already listed (is_listed = true)      -> 409
--   PXN34 — inventory item is currently applied (is_applied = true)
--           and must be removed from an active mining slot (via
--           set_miner_applied) before it is eligible to be listed    -> 409
--   PXN35 — listing not found                                        -> 404
--   PXN36 — listing is not active (already sold/cancelled)           -> 409
--   PXN37 — caller is not the seller who owns this listing           -> 403
--   PXN38 — caller (buyer) cannot buy/offer on their own listing     -> 409
--   PXN39 — listing's mining_inventory_id is no longer listed by / no
--           longer owned by the listing's own seller_user_id (defensive
--           cross-table integrity check; should never trigger given
--           that only these RPCs ever move is_listed or ownership)    -> 409
--   PXN40 — offer not found                                          -> 404
--   PXN41 — offer is not open (already accepted/rejected/cancelled)  -> 409
--   PXN42 — caller is not the buyer who placed this offer            -> 403
--   PXN43 — caller is not the seller of the listing this offer is on -> 403
--   PXN44 — marketplace_config unseeded, or fee_recipient_user_id
--           (treasury) is not configured                             -> 500
--   PXN45 — marketplace_config.active = false (kill switch); refused
--           only for actions that CREATE a new listing/offer/sale —
--           cancelling, accepting, or rejecting an existing listing
--           or offer is still allowed while paused, so a player is
--           never trapped in a live commitment by a pause             -> 409
--   PXN46 — buyer already has an open offer on this listing (mirrors
--           marketplace_offers_one_open_per_buyer_listing, checked
--           explicitly here so the failure is this clear error rather
--           than a raw unique_violation)                              -> 409
--
-- Untouched by this migration: index.html, admin.html,
-- js/api-client.js, every existing migration and RPC (claim_mining,
-- purchase_miner, set_miner_applied, upgrade_miner, level_up_mining,
-- adjust_claimed_total, adjust_pxn_balance, set_updated_at), pxn_balance
-- anywhere, and every existing RLS policy. No Edge Function or
-- frontend code is created or modified — this migration is the RPC
-- layer only; wiring it up to an Edge Function is a later, separate
-- step.

-- ===================================================================
-- 1. public.marketplace_create_listing
-- ===================================================================
create or replace function public.marketplace_create_listing(
  p_user_id           uuid,
  p_inventory_id      uuid,
  p_asking_price_mpxn numeric
)
returns table (
  listing_id          uuid,
  seller_user_id      uuid,
  mining_inventory_id uuid,
  asking_price_mpxn   numeric(20,8),
  status              text,
  created_at          timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner      uuid;
  v_is_listed  boolean;
  v_is_applied boolean;
  v_active     boolean;
  v_listing_id uuid;
begin
  -- ---------------------------------------------------------------
  -- 1. Validate input. Defense in depth, same discipline as every
  --    other RPC in this schema.
  -- ---------------------------------------------------------------
  if p_user_id is null or p_inventory_id is null then
    raise exception 'marketplace_create_listing: p_user_id and p_inventory_id are required'
      using errcode = 'PXN30';
  end if;

  if p_asking_price_mpxn is null or p_asking_price_mpxn <= 0 then
    raise exception 'marketplace_create_listing: p_asking_price_mpxn must be greater than zero'
      using errcode = 'PXN31';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Marketplace kill switch. Creating a NEW listing is refused
  --    while paused; existing listings/offers are settled/withdrawn
  --    normally regardless (see the other six functions below).
  -- ---------------------------------------------------------------
  select c.active
    into v_active
    from public.marketplace_config as c
   where c.id = true;

  if not found or not v_active then
    raise exception 'marketplace_create_listing: marketplace is not currently active'
      using errcode = 'PXN45';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Lock the target inventory row. A single-row operation — no
  --    other player's row and no mining_state row is ever touched by
  --    listing creation, so there is no multi-row lock-order concern
  --    here (unlike buy/accept-offer below).
  -- ---------------------------------------------------------------
  select mi.user_id, mi.is_listed, mi.is_applied
    into v_owner, v_is_listed, v_is_applied
    from public.mining_inventory as mi
   where mi.id = p_inventory_id
     for update;

  if not found then
    raise exception 'marketplace_create_listing: inventory item % not found', p_inventory_id
      using errcode = 'PXN32';
  end if;

  if v_owner <> p_user_id then
    raise exception 'marketplace_create_listing: inventory item % does not belong to user_id %', p_inventory_id, p_user_id
      using errcode = 'PXN32';
  end if;

  if v_is_listed then
    raise exception 'marketplace_create_listing: inventory item % is already listed', p_inventory_id
      using errcode = 'PXN33';
  end if;

  -- Eligibility: a unit currently applied toward the player's own
  -- mining accrual cannot be listed out from under that accrual — the
  -- seller must remove it (set_miner_applied) first. This is the
  -- listing-side mirror of the 0033 custody guard, which blocks the
  -- opposite direction (applying/upgrading a unit that is listed).
  if v_is_applied then
    raise exception 'marketplace_create_listing: inventory item % is currently applied and must be removed from an active mining slot before it can be listed', p_inventory_id
      using errcode = 'PXN34';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Flip custody and create the listing. The partial unique index
  --    marketplace_listings_one_active_per_item (0032) is a second,
  --    independent backstop against two active listings ever existing
  --    for the same inventory row.
  -- ---------------------------------------------------------------
  update public.mining_inventory as mi
     set is_listed = true
   where mi.id = p_inventory_id
     and mi.user_id = p_user_id;

  insert into public.marketplace_listings (seller_user_id, mining_inventory_id, asking_price_mpxn, status)
  values (p_user_id, p_inventory_id, p_asking_price_mpxn, 'active')
  returning id into v_listing_id;

  return query
    select
      l.id,
      l.seller_user_id,
      l.mining_inventory_id,
      l.asking_price_mpxn,
      l.status,
      l.created_at
      from public.marketplace_listings as l
     where l.id = v_listing_id;
end;
$$;

comment on function public.marketplace_create_listing(uuid, uuid, numeric) is
  'Service-role-only: lists an owned mining_inventory unit for sale. Locks and verifies ownership of the inventory row, rejects if already listed (PXN33) or currently applied (PXN34 — must be un-applied first), validates asking_price_mpxn > 0 (PXN31), sets is_listed = true, and inserts an active marketplace_listings row. Moves no m.PXN. Refused while marketplace_config.active = false (PXN45). Not callable by anon/authenticated.';

revoke all on function public.marketplace_create_listing(uuid, uuid, numeric) from public;
revoke all on function public.marketplace_create_listing(uuid, uuid, numeric) from anon;
revoke all on function public.marketplace_create_listing(uuid, uuid, numeric) from authenticated;
grant execute on function public.marketplace_create_listing(uuid, uuid, numeric) to service_role;

-- ===================================================================
-- 2. public.marketplace_cancel_listing
-- ===================================================================
create or replace function public.marketplace_cancel_listing(
  p_user_id    uuid,
  p_listing_id uuid
)
returns table (
  listing_id          uuid,
  seller_user_id      uuid,
  mining_inventory_id uuid,
  status              text,
  updated_at          timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_seller    uuid;
  v_status    text;
  v_inventory uuid;
begin
  if p_user_id is null or p_listing_id is null then
    raise exception 'marketplace_cancel_listing: p_user_id and p_listing_id are required'
      using errcode = 'PXN30';
  end if;

  -- Fixed lock order: listing row first, then its inventory row —
  -- the same order marketplace_buy_listing and marketplace_accept_offer
  -- use, so no code path ever locks these two tables in the opposite
  -- order.
  select l.seller_user_id, l.status, l.mining_inventory_id
    into v_seller, v_status, v_inventory
    from public.marketplace_listings as l
   where l.id = p_listing_id
     for update;

  if not found then
    raise exception 'marketplace_cancel_listing: listing % not found', p_listing_id
      using errcode = 'PXN35';
  end if;

  if v_seller <> p_user_id then
    raise exception 'marketplace_cancel_listing: user_id % is not the seller of listing %', p_user_id, p_listing_id
      using errcode = 'PXN37';
  end if;

  if v_status <> 'active' then
    raise exception 'marketplace_cancel_listing: listing % is not active (status %)', p_listing_id, v_status
      using errcode = 'PXN36';
  end if;

  perform 1
    from public.mining_inventory as mi
   where mi.id = v_inventory
     for update;

  -- No m.PXN moves on cancellation (listing never held escrow).
  update public.marketplace_listings as l
     set status = 'cancelled'
   where l.id = p_listing_id;

  update public.mining_inventory as mi
     set is_listed = false
   where mi.id = v_inventory;

  return query
    select
      l.id,
      l.seller_user_id,
      l.mining_inventory_id,
      l.status,
      l.updated_at
      from public.marketplace_listings as l
     where l.id = p_listing_id;
end;
$$;

comment on function public.marketplace_cancel_listing(uuid, uuid) is
  'Service-role-only: withdraws the caller''s own active listing. Locks the listing then its inventory row (fixed order), verifies the caller is the seller (PXN37) and the listing is active (PXN36), sets status = cancelled and clears mining_inventory.is_listed. Moves no m.PXN — listing creation never escrows anything. Not callable by anon/authenticated.';

revoke all on function public.marketplace_cancel_listing(uuid, uuid) from public;
revoke all on function public.marketplace_cancel_listing(uuid, uuid) from anon;
revoke all on function public.marketplace_cancel_listing(uuid, uuid) from authenticated;
grant execute on function public.marketplace_cancel_listing(uuid, uuid) to service_role;

-- ===================================================================
-- 3. public.marketplace_buy_listing
-- ===================================================================
create or replace function public.marketplace_buy_listing(
  p_buyer_user_id uuid,
  p_listing_id    uuid
)
returns table (
  listing_id           uuid,
  inventory_id         uuid,
  seller_user_id       uuid,
  buyer_user_id        uuid,
  asking_price_mpxn    numeric(20,8),
  marketplace_fee_mpxn numeric(20,8),
  seller_proceeds_mpxn numeric(20,8),
  buyer_claimed_total  numeric(20,8),
  seller_claimed_total numeric(20,8),
  status               text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_seller         uuid;
  v_inventory      uuid;
  v_status         text;
  v_price          numeric(20,8);
  v_inv_owner      uuid;
  v_inv_listed     boolean;
  v_fee_bps        integer;
  v_treasury       uuid;
  v_fee            numeric(20,8);
  v_proceeds       numeric(20,8);
  v_buyer_balance  numeric(20,8);
  v_seller_balance numeric(20,8);
  v_lock_ids       uuid[];
  v_uid            uuid;
begin
  if p_buyer_user_id is null or p_listing_id is null then
    raise exception 'marketplace_buy_listing: p_buyer_user_id and p_listing_id are required'
      using errcode = 'PXN30';
  end if;

  -- ---------------------------------------------------------------
  -- 1. Lock the listing FIRST.
  -- ---------------------------------------------------------------
  select l.seller_user_id, l.mining_inventory_id, l.status, l.asking_price_mpxn
    into v_seller, v_inventory, v_status, v_price
    from public.marketplace_listings as l
   where l.id = p_listing_id
     for update;

  if not found then
    raise exception 'marketplace_buy_listing: listing % not found', p_listing_id
      using errcode = 'PXN35';
  end if;

  if v_status <> 'active' then
    raise exception 'marketplace_buy_listing: listing % is not active (status %)', p_listing_id, v_status
      using errcode = 'PXN36';
  end if;

  if v_seller = p_buyer_user_id then
    raise exception 'marketplace_buy_listing: user_id % cannot buy their own listing %', p_buyer_user_id, p_listing_id
      using errcode = 'PXN38';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the inventory row SECOND, and re-verify it is still
  --    listed and still owned by the seller recorded on the listing —
  --    a defensive cross-table integrity check.
  -- ---------------------------------------------------------------
  select mi.user_id, mi.is_listed
    into v_inv_owner, v_inv_listed
    from public.mining_inventory as mi
   where mi.id = v_inventory
     for update;

  if not found then
    raise exception 'marketplace_buy_listing: inventory item % not found', v_inventory
      using errcode = 'PXN32';
  end if;

  if v_inv_owner <> v_seller or not v_inv_listed then
    raise exception 'marketplace_buy_listing: inventory item % is no longer listed by seller %', v_inventory, v_seller
      using errcode = 'PXN39';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Marketplace fee configuration + treasury account. Fee is
  --    computed deterministically from marketplace_fee_bps — never
  --    hard-coded — and the treasury account is exactly
  --    marketplace_config.fee_recipient_user_id; a missing/null
  --    treasury is a hard server-misconfiguration error, not a
  --    "waive the fee".
  -- ---------------------------------------------------------------
  select c.marketplace_fee_bps, c.fee_recipient_user_id
    into v_fee_bps, v_treasury
    from public.marketplace_config as c
   where c.id = true;

  if not found then
    raise exception 'marketplace_buy_listing: marketplace_config is not seeded'
      using errcode = 'PXN44';
  end if;

  if v_treasury is null then
    raise exception 'marketplace_buy_listing: marketplace treasury (fee_recipient_user_id) is not configured'
      using errcode = 'PXN44';
  end if;

  v_fee      := round(v_price * v_fee_bps / 10000.0, 8);
  v_proceeds := v_price - v_fee;

  -- ---------------------------------------------------------------
  -- 4. Lock every mining_state row this sale will touch (buyer,
  --    seller, treasury) in one pass, in ascending user_id order,
  --    BEFORE moving any m.PXN. See header comment for why ascending
  --    order (not role order) prevents cross-transaction deadlocks.
  -- ---------------------------------------------------------------
  select array_agg(distinct u order by u)
    into v_lock_ids
    from unnest(array[p_buyer_user_id, v_seller, v_treasury]) as u;

  foreach v_uid in array v_lock_ids loop
    perform 1 from public.mining_state as ms where ms.user_id = v_uid for update;
    if not found then
      raise exception 'marketplace_buy_listing: no mining_state row for user_id %', v_uid
        using errcode = 'PXN25';
    end if;
  end loop;

  -- ---------------------------------------------------------------
  -- 5. Move m.PXN entirely through adjust_claimed_total(). Debit the
  --    buyer FIRST: if their balance is insufficient this raises
  --    PXN24 and the whole transaction — including the locks above —
  --    rolls back before the seller or treasury are touched at all.
  --    ref_type/ref_id = ('listing', p_listing_id) for every leg of
  --    this sale: a listing settles at most once (status flips off
  --    'active' here), so this triple is a safe, naturally-unique
  --    idempotency key for all three legs.
  -- ---------------------------------------------------------------
  v_buyer_balance := public.adjust_claimed_total(
    p_buyer_user_id, -v_price, 'market_buy_debit', 'listing', p_listing_id
  );

  v_seller_balance := public.adjust_claimed_total(
    v_seller, v_proceeds, 'market_sale_credit', 'listing', p_listing_id
  );

  if v_fee > 0 then
    perform public.adjust_claimed_total(
      v_treasury, v_fee, 'market_fee_treasury_credit', 'listing', p_listing_id
    );
  end if;

  -- ---------------------------------------------------------------
  -- 6. Settle the listing and transfer custody. is_applied is reset
  --    to false on transfer: a unit that was applied toward the
  --    SELLER's mining accrual must not silently count against the
  --    BUYER's own applied-slot limit (driven by the buyer's own
  --    mining_state.level) without the buyer explicitly re-applying
  --    it through set_miner_applied, which performs that slot-limit
  --    check. Every other inventory column (miner_tier, miner_name,
  --    miner_icon, miner_level, miner_speed, created_at) is preserved
  --    untouched — the row is updated in place, never deleted or
  --    recreated.
  -- ---------------------------------------------------------------
  update public.marketplace_listings as l
     set status        = 'sold',
         buyer_user_id = p_buyer_user_id,
         sold_at       = now()
   where l.id = p_listing_id;

  update public.mining_inventory as mi
     set user_id    = p_buyer_user_id,
         is_listed  = false,
         is_applied = false
   where mi.id = v_inventory;

  return query
    select
      p_listing_id,
      v_inventory,
      v_seller,
      p_buyer_user_id,
      v_price,
      v_fee,
      v_proceeds,
      v_buyer_balance,
      v_seller_balance,
      'sold'::text;
end;
$$;

comment on function public.marketplace_buy_listing(uuid, uuid) is
  'Service-role-only: buys an active listing outright at its asking price. Locks the listing then its inventory row, rejects self-purchase (PXN38), locks buyer/seller/treasury mining_state rows in ascending user_id order, debits the buyer, credits the seller net of the marketplace_config.marketplace_fee_bps fee, credits marketplace_config.fee_recipient_user_id (treasury) with the fee — all three exclusively via adjust_claimed_total() — then marks the listing sold and transfers mining_inventory ownership/custody to the buyer (is_listed and is_applied both cleared). Atomic and race-free: a second concurrent buy attempt on the same listing blocks on the listing row lock and then fails PXN36 once it observes status <> active. Never touches pxn_balance. Not callable by anon/authenticated.';

revoke all on function public.marketplace_buy_listing(uuid, uuid) from public;
revoke all on function public.marketplace_buy_listing(uuid, uuid) from anon;
revoke all on function public.marketplace_buy_listing(uuid, uuid) from authenticated;
grant execute on function public.marketplace_buy_listing(uuid, uuid) to service_role;

-- ===================================================================
-- 4. public.marketplace_make_offer
-- ===================================================================
create or replace function public.marketplace_make_offer(
  p_buyer_user_id    uuid,
  p_listing_id       uuid,
  p_offer_price_mpxn numeric
)
returns table (
  offer_id            uuid,
  listing_id          uuid,
  buyer_user_id       uuid,
  offer_price_mpxn    numeric(20,8),
  status              text,
  buyer_claimed_total numeric(20,8)
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_seller   uuid;
  v_status   text;
  v_active   boolean;
  v_offer_id uuid := gen_random_uuid();
  v_balance  numeric(20,8);
begin
  if p_buyer_user_id is null or p_listing_id is null then
    raise exception 'marketplace_make_offer: p_buyer_user_id and p_listing_id are required'
      using errcode = 'PXN30';
  end if;

  if p_offer_price_mpxn is null or p_offer_price_mpxn <= 0 then
    raise exception 'marketplace_make_offer: p_offer_price_mpxn must be greater than zero'
      using errcode = 'PXN31';
  end if;

  select c.active
    into v_active
    from public.marketplace_config as c
   where c.id = true;

  if not found or not v_active then
    raise exception 'marketplace_make_offer: marketplace is not currently active'
      using errcode = 'PXN45';
  end if;

  select l.seller_user_id, l.status
    into v_seller, v_status
    from public.marketplace_listings as l
   where l.id = p_listing_id
     for update;

  if not found then
    raise exception 'marketplace_make_offer: listing % not found', p_listing_id
      using errcode = 'PXN35';
  end if;

  if v_status <> 'active' then
    raise exception 'marketplace_make_offer: listing % is not active (status %)', p_listing_id, v_status
      using errcode = 'PXN36';
  end if;

  if v_seller = p_buyer_user_id then
    raise exception 'marketplace_make_offer: user_id % cannot offer on their own listing %', p_buyer_user_id, p_listing_id
      using errcode = 'PXN38';
  end if;

  -- Explicit, friendly check for the same condition the partial
  -- unique index marketplace_offers_one_open_per_buyer_listing (0032)
  -- enforces at the database level, so a duplicate open offer fails
  -- with a clear PXN46 rather than a raw unique_violation.
  if exists (
    select 1
      from public.marketplace_offers as o
     where o.listing_id = p_listing_id
       and o.buyer_user_id = p_buyer_user_id
       and o.status = 'open'
  ) then
    raise exception 'marketplace_make_offer: user_id % already has an open offer on listing %', p_buyer_user_id, p_listing_id
      using errcode = 'PXN46';
  end if;

  -- Escrow BEFORE inserting the offer row: if the buyer's claimed_total
  -- is insufficient, adjust_claimed_total() raises PXN24 and no offer
  -- row is ever created — there is no way to end up with an offer that
  -- is not fully backed by escrowed m.PXN.
  v_balance := public.adjust_claimed_total(
    p_buyer_user_id, -p_offer_price_mpxn, 'market_offer_escrow', 'offer', v_offer_id
  );

  insert into public.marketplace_offers (id, listing_id, buyer_user_id, offer_price_mpxn, status)
  values (v_offer_id, p_listing_id, p_buyer_user_id, p_offer_price_mpxn, 'open');

  return query
    select v_offer_id, p_listing_id, p_buyer_user_id, p_offer_price_mpxn, 'open'::text, v_balance;
end;
$$;

comment on function public.marketplace_make_offer(uuid, uuid, numeric) is
  'Service-role-only: places an escrowed offer on an active listing. Locks the listing, rejects self-offers (PXN38) and a second concurrent open offer from the same buyer on the same listing (PXN46), then escrows offer_price_mpxn out of the buyer''s claimed_total via adjust_claimed_total() (reason market_offer_escrow, ref_type offer, ref_id = the new offer id) BEFORE inserting the marketplace_offers row, so an insufficient balance (PXN24) never produces an unbacked offer. Offer visibility (buyer sees only their own; seller sees only offers on their own listings) is enforced by the marketplace_offers RLS policies from 0032, not by this function. Refused while marketplace_config.active = false (PXN45). Not callable by anon/authenticated.';

revoke all on function public.marketplace_make_offer(uuid, uuid, numeric) from public;
revoke all on function public.marketplace_make_offer(uuid, uuid, numeric) from anon;
revoke all on function public.marketplace_make_offer(uuid, uuid, numeric) from authenticated;
grant execute on function public.marketplace_make_offer(uuid, uuid, numeric) to service_role;

-- ===================================================================
-- 5. public.marketplace_cancel_offer
-- ===================================================================
create or replace function public.marketplace_cancel_offer(
  p_buyer_user_id uuid,
  p_offer_id      uuid
)
returns table (
  offer_id            uuid,
  refund_amount_mpxn  numeric(20,8),
  buyer_claimed_total numeric(20,8),
  status              text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_buyer   uuid;
  v_status  text;
  v_price   numeric(20,8);
  v_balance numeric(20,8);
begin
  if p_buyer_user_id is null or p_offer_id is null then
    raise exception 'marketplace_cancel_offer: p_buyer_user_id and p_offer_id are required'
      using errcode = 'PXN30';
  end if;

  select o.buyer_user_id, o.status, o.offer_price_mpxn
    into v_buyer, v_status, v_price
    from public.marketplace_offers as o
   where o.id = p_offer_id
     for update;

  if not found then
    raise exception 'marketplace_cancel_offer: offer % not found', p_offer_id
      using errcode = 'PXN40';
  end if;

  if v_buyer <> p_buyer_user_id then
    raise exception 'marketplace_cancel_offer: user_id % is not the buyer of offer %', p_buyer_user_id, p_offer_id
      using errcode = 'PXN42';
  end if;

  if v_status <> 'open' then
    raise exception 'marketplace_cancel_offer: offer % is not open (status %)', p_offer_id, v_status
      using errcode = 'PXN41';
  end if;

  -- Refund via the same primitive that escrowed it. ref_type/ref_id =
  -- ('offer', p_offer_id) is the SAME key marketplace_make_offer used
  -- for the escrow debit but with reason = market_offer_refund, a
  -- distinct reason — so this insert cannot collide with the escrow
  -- row's own idempotency key, while a RETRY of this exact cancel
  -- call collides with itself (same user_id/reason/ref_type/ref_id)
  -- and is rejected as PXN26 by adjust_claimed_total(), making a
  -- double refund of the same offer impossible.
  v_balance := public.adjust_claimed_total(
    v_buyer, v_price, 'market_offer_refund', 'offer', p_offer_id
  );

  update public.marketplace_offers as o
     set status = 'cancelled'
   where o.id = p_offer_id;

  return query
    select p_offer_id, v_price, v_balance, 'cancelled'::text;
end;
$$;

comment on function public.marketplace_cancel_offer(uuid, uuid) is
  'Service-role-only: withdraws the caller''s own open offer. Locks the offer, verifies the caller is its buyer (PXN42) and it is still open (PXN41), refunds offer_price_mpxn to the buyer via adjust_claimed_total() (reason market_offer_refund, ref_type offer, ref_id = this offer id — the ledger''s unique idempotency index makes a second refund of the same offer physically impossible), then marks it cancelled. Not callable by anon/authenticated.';

revoke all on function public.marketplace_cancel_offer(uuid, uuid) from public;
revoke all on function public.marketplace_cancel_offer(uuid, uuid) from anon;
revoke all on function public.marketplace_cancel_offer(uuid, uuid) from authenticated;
grant execute on function public.marketplace_cancel_offer(uuid, uuid) to service_role;

-- ===================================================================
-- 6. public.marketplace_accept_offer
-- ===================================================================
create or replace function public.marketplace_accept_offer(
  p_seller_user_id uuid,
  p_offer_id       uuid
)
returns table (
  listing_id           uuid,
  inventory_id         uuid,
  offer_id             uuid,
  seller_user_id       uuid,
  buyer_user_id        uuid,
  offer_price_mpxn     numeric(20,8),
  marketplace_fee_mpxn numeric(20,8),
  seller_proceeds_mpxn numeric(20,8),
  seller_claimed_total numeric(20,8),
  status               text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_buyer          uuid;
  v_offer_status   text;
  v_price          numeric(20,8);
  v_listing        uuid;
  v_seller         uuid;
  v_listing_status text;
  v_inventory      uuid;
  v_inv_owner      uuid;
  v_inv_listed     boolean;
  v_fee_bps        integer;
  v_treasury       uuid;
  v_fee            numeric(20,8);
  v_proceeds       numeric(20,8);
  v_seller_balance numeric(20,8);
  v_lock_ids       uuid[];
  v_uid            uuid;
  v_other          record;
  v_other_ids      uuid[] := '{}';
  v_other_buyers   uuid[] := '{}';
  v_other_prices   numeric(20,8)[] := '{}';
  i                integer;
begin
  if p_seller_user_id is null or p_offer_id is null then
    raise exception 'marketplace_accept_offer: p_seller_user_id and p_offer_id are required'
      using errcode = 'PXN30';
  end if;

  -- ---------------------------------------------------------------
  -- 1. Lock the offer FIRST.
  -- ---------------------------------------------------------------
  select o.buyer_user_id, o.status, o.offer_price_mpxn, o.listing_id
    into v_buyer, v_offer_status, v_price, v_listing
    from public.marketplace_offers as o
   where o.id = p_offer_id
     for update;

  if not found then
    raise exception 'marketplace_accept_offer: offer % not found', p_offer_id
      using errcode = 'PXN40';
  end if;

  if v_offer_status <> 'open' then
    raise exception 'marketplace_accept_offer: offer % is not open (status %)', p_offer_id, v_offer_status
      using errcode = 'PXN41';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Lock the listing SECOND.
  -- ---------------------------------------------------------------
  select l.seller_user_id, l.status, l.mining_inventory_id
    into v_seller, v_listing_status, v_inventory
    from public.marketplace_listings as l
   where l.id = v_listing
     for update;

  if not found then
    raise exception 'marketplace_accept_offer: listing % not found', v_listing
      using errcode = 'PXN35';
  end if;

  if v_seller <> p_seller_user_id then
    raise exception 'marketplace_accept_offer: user_id % is not the seller of listing %', p_seller_user_id, v_listing
      using errcode = 'PXN37';
  end if;

  if v_listing_status <> 'active' then
    raise exception 'marketplace_accept_offer: listing % is not active (status %)', v_listing, v_listing_status
      using errcode = 'PXN36';
  end if;

  -- ---------------------------------------------------------------
  -- 3. Lock the inventory row THIRD, and re-verify custody — same
  --    defensive cross-table check as marketplace_buy_listing.
  -- ---------------------------------------------------------------
  select mi.user_id, mi.is_listed
    into v_inv_owner, v_inv_listed
    from public.mining_inventory as mi
   where mi.id = v_inventory
     for update;

  if not found then
    raise exception 'marketplace_accept_offer: inventory item % not found', v_inventory
      using errcode = 'PXN32';
  end if;

  if v_inv_owner <> v_seller or not v_inv_listed then
    raise exception 'marketplace_accept_offer: inventory item % is no longer listed by seller %', v_inventory, v_seller
      using errcode = 'PXN39';
  end if;

  -- ---------------------------------------------------------------
  -- 4. Lock every OTHER still-open offer on this listing FOURTH
  --    (ordered by id for determinism) and collect them — they must
  --    all be refunded and closed out below once this listing sells,
  --    so no offer is ever left escrowed against a sold listing. The
  --    accepted offer's own buyer is excluded here: their m.PXN was
  --    already escrowed at offer time and is not touched again — it
  --    simply becomes the sale proceeds/fee below instead of being
  --    refunded.
  -- ---------------------------------------------------------------
  for v_other in
    select o.id, o.buyer_user_id, o.offer_price_mpxn
      from public.marketplace_offers as o
     where o.listing_id = v_listing
       and o.status = 'open'
       and o.id <> p_offer_id
     order by o.id
     for update
  loop
    v_other_ids    := v_other_ids || v_other.id;
    v_other_buyers := v_other_buyers || v_other.buyer_user_id;
    v_other_prices := v_other_prices || v_other.offer_price_mpxn;
  end loop;

  -- ---------------------------------------------------------------
  -- 5. Marketplace fee configuration + treasury account.
  -- ---------------------------------------------------------------
  select c.marketplace_fee_bps, c.fee_recipient_user_id
    into v_fee_bps, v_treasury
    from public.marketplace_config as c
   where c.id = true;

  if not found then
    raise exception 'marketplace_accept_offer: marketplace_config is not seeded'
      using errcode = 'PXN44';
  end if;

  if v_treasury is null then
    raise exception 'marketplace_accept_offer: marketplace treasury (fee_recipient_user_id) is not configured'
      using errcode = 'PXN44';
  end if;

  v_fee      := round(v_price * v_fee_bps / 10000.0, 8);
  v_proceeds := v_price - v_fee;

  -- ---------------------------------------------------------------
  -- 6. Lock every mining_state row this settlement will touch
  --    (seller, treasury, and every refunded competing buyer) in one
  --    pass, ascending by user_id, BEFORE moving any m.PXN — same
  --    reasoning as marketplace_buy_listing step 4. The accepted
  --    offer's own buyer is NOT included: no balance change happens
  --    for them in this function.
  -- ---------------------------------------------------------------
  select array_agg(distinct u order by u)
    into v_lock_ids
    from unnest(array[v_seller, v_treasury] || v_other_buyers) as u;

  foreach v_uid in array v_lock_ids loop
    perform 1 from public.mining_state as ms where ms.user_id = v_uid for update;
    if not found then
      raise exception 'marketplace_accept_offer: no mining_state row for user_id %', v_uid
        using errcode = 'PXN25';
    end if;
  end loop;

  -- ---------------------------------------------------------------
  -- 7. Credit seller net proceeds and treasury fee. The accepted
  --    buyer's offer_price_mpxn was already debited/escrowed at offer
  --    time (marketplace_make_offer) — it is NOT debited again here.
  --    ref_type/ref_id = ('offer', p_offer_id): an offer is accepted
  --    at most once (status leaves 'open' here), so this is a safe,
  --    naturally-unique idempotency key for both legs, distinct from
  --    marketplace_buy_listing's ('listing', ...) key used for the
  --    direct-buy path.
  -- ---------------------------------------------------------------
  v_seller_balance := public.adjust_claimed_total(
    v_seller, v_proceeds, 'market_sale_credit', 'offer', p_offer_id
  );

  if v_fee > 0 then
    perform public.adjust_claimed_total(
      v_treasury, v_fee, 'market_fee_treasury_credit', 'offer', p_offer_id
    );
  end if;

  -- ---------------------------------------------------------------
  -- 8. Refund and close out every other open offer on this listing —
  --    no offer may remain escrowed once the listing is sold.
  -- ---------------------------------------------------------------
  for i in 1 .. coalesce(array_length(v_other_ids, 1), 0) loop
    perform public.adjust_claimed_total(
      v_other_buyers[i], v_other_prices[i], 'market_offer_refund', 'offer', v_other_ids[i]
    );

    update public.marketplace_offers
       set status = 'rejected'
     where id = v_other_ids[i];
  end loop;

  -- ---------------------------------------------------------------
  -- 9. Settle: accepted offer, listing, inventory transfer. Same
  --    custody-transfer semantics as marketplace_buy_listing step 6
  --    (is_listed and is_applied both cleared; every other inventory
  --    column preserved in place).
  -- ---------------------------------------------------------------
  update public.marketplace_offers
     set status = 'accepted'
   where id = p_offer_id;

  update public.marketplace_listings
     set status        = 'sold',
         buyer_user_id = v_buyer,
         sold_at       = now()
   where id = v_listing;

  update public.mining_inventory
     set user_id    = v_buyer,
         is_listed  = false,
         is_applied = false
   where id = v_inventory;

  return query
    select
      v_listing,
      v_inventory,
      p_offer_id,
      v_seller,
      v_buyer,
      v_price,
      v_fee,
      v_proceeds,
      v_seller_balance,
      'sold'::text;
end;
$$;

comment on function public.marketplace_accept_offer(uuid, uuid) is
  'Service-role-only: accepts an open offer, selling the listing to that offer''s buyer at the offer''s price. Locks offer, then listing, then inventory, then every other open offer on the same listing (all fixed order), verifies the caller is the seller (PXN37) and everything is still active/open, credits the seller net of marketplace_config.marketplace_fee_bps and credits marketplace_config.fee_recipient_user_id (treasury) with the fee — the accepted buyer''s already-escrowed m.PXN is never debited again — refunds and rejects every other open offer on the listing so none remains escrowed, then marks the listing sold and transfers mining_inventory ownership/custody to the buyer (is_listed and is_applied both cleared). Atomic and race-free, including against a concurrent marketplace_buy_listing/marketplace_cancel_listing on the same listing (serialized by the listing row lock) and against concurrent marketplace_cancel_offer calls on the other refunded offers (serialized by locking them here). Never touches pxn_balance. Not callable by anon/authenticated.';

revoke all on function public.marketplace_accept_offer(uuid, uuid) from public;
revoke all on function public.marketplace_accept_offer(uuid, uuid) from anon;
revoke all on function public.marketplace_accept_offer(uuid, uuid) from authenticated;
grant execute on function public.marketplace_accept_offer(uuid, uuid) to service_role;

-- ===================================================================
-- 7. public.marketplace_reject_offer
-- ===================================================================
create or replace function public.marketplace_reject_offer(
  p_seller_user_id uuid,
  p_offer_id       uuid
)
returns table (
  offer_id            uuid,
  refund_amount_mpxn  numeric(20,8),
  buyer_claimed_total numeric(20,8),
  status              text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_buyer   uuid;
  v_status  text;
  v_price   numeric(20,8);
  v_listing uuid;
  v_seller  uuid;
  v_balance numeric(20,8);
begin
  if p_seller_user_id is null or p_offer_id is null then
    raise exception 'marketplace_reject_offer: p_seller_user_id and p_offer_id are required'
      using errcode = 'PXN30';
  end if;

  select o.buyer_user_id, o.status, o.offer_price_mpxn, o.listing_id
    into v_buyer, v_status, v_price, v_listing
    from public.marketplace_offers as o
   where o.id = p_offer_id
     for update;

  if not found then
    raise exception 'marketplace_reject_offer: offer % not found', p_offer_id
      using errcode = 'PXN40';
  end if;

  select l.seller_user_id
    into v_seller
    from public.marketplace_listings as l
   where l.id = v_listing;

  if not found or v_seller <> p_seller_user_id then
    raise exception 'marketplace_reject_offer: user_id % is not the seller of the listing for offer %', p_seller_user_id, p_offer_id
      using errcode = 'PXN43';
  end if;

  if v_status <> 'open' then
    raise exception 'marketplace_reject_offer: offer % is not open (status %)', p_offer_id, v_status
      using errcode = 'PXN41';
  end if;

  -- Same idempotent refund key discipline as marketplace_cancel_offer:
  -- ('offer', p_offer_id) with reason = market_offer_refund makes a
  -- second refund of this offer (from either function) impossible.
  v_balance := public.adjust_claimed_total(
    v_buyer, v_price, 'market_offer_refund', 'offer', p_offer_id
  );

  update public.marketplace_offers as o
     set status = 'rejected'
   where o.id = p_offer_id;

  return query
    select p_offer_id, v_price, v_balance, 'rejected'::text;
end;
$$;

comment on function public.marketplace_reject_offer(uuid, uuid) is
  'Service-role-only: declines an open offer on the caller''s own listing. Locks the offer, verifies the caller owns the listing it is on (PXN43) and the offer is still open (PXN41), refunds offer_price_mpxn to the buyer via adjust_claimed_total() (reason market_offer_refund, ref_type offer, ref_id = this offer id — same idempotency key marketplace_cancel_offer uses, so the same offer can never be refunded twice regardless of which of the two functions is retried), then marks it rejected. Not callable by anon/authenticated.';

revoke all on function public.marketplace_reject_offer(uuid, uuid) from public;
revoke all on function public.marketplace_reject_offer(uuid, uuid) from anon;
revoke all on function public.marketplace_reject_offer(uuid, uuid) from authenticated;
grant execute on function public.marketplace_reject_offer(uuid, uuid) to service_role;

-- ---------------------------------------------------------------
-- This migration creates ONLY the seven marketplace RPCs above. It
-- does not touch pxn_balance anywhere, does not create a second
-- balance-mutation primitive (every movement goes through the
-- existing adjust_claimed_total()), does not weaken or bypass any
-- existing RLS policy, and does not modify claim_mining,
-- purchase_miner, set_miner_applied, upgrade_miner, level_up_mining,
-- adjust_claimed_total, adjust_pxn_balance, or set_updated_at. No
-- Edge Function or frontend file (index.html, admin.html,
-- js/api-client.js) is created or modified — an Edge Function that
-- authenticates the real Supabase user and then calls these RPCs with
-- service-role credentials is a later, separate step.
-- ---------------------------------------------------------------
