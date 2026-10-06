-- Pro-X Network — only the HIGHEST open offer on a listing may be
-- accepted.
--
-- Does NOT modify 0034_marketplace_rpcs.sql (already applied). This is
-- a CREATE OR REPLACE of public.marketplace_accept_offer with the
-- EXACT SAME signature and return type as 0034 — every existing line
-- of that function is preserved verbatim; the only addition is one new
-- validation block (marked below) inserted after the existing
-- "offer is open" / "caller is seller" / "listing is active" / custody
-- checks and before any adjust_claimed_total() call or inventory
-- transfer, per the required placement.
--
-- New SQLSTATE (continuing the existing PXN01-PXN46 sequence from
-- 0034's header):
--   PXN47 — accept_offer_attempted_on_non_highest_offer: caller tried
--           to accept an open offer that is not the highest open offer
--           on the listing (by offer_price_mpxn desc, created_at asc,
--           id asc)                                           -> 409
--
-- Unchanged by this migration: marketplace_make_offer,
-- marketplace_cancel_offer, marketplace_reject_offer,
-- marketplace_create_listing, marketplace_cancel_listing,
-- marketplace_buy_listing (direct buy-at-asking-price is not an offer
-- and is not touched), every other PXN30-PXN46 error meaning,
-- marketplace_fee_bps/treasury/seller-credit logic, the refund logic
-- for losing offers, the marketplace_offers RLS policies, and
-- mining_inventory custody handling elsewhere.

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
  v_buyer            uuid;
  v_offer_status     text;
  v_price            numeric(20,8);
  v_listing          uuid;
  v_seller           uuid;
  v_listing_status   text;
  v_inventory        uuid;
  v_inv_owner        uuid;
  v_inv_listed       boolean;
  v_fee_bps          integer;
  v_treasury         uuid;
  v_fee              numeric(20,8);
  v_proceeds         numeric(20,8);
  v_seller_balance   numeric(20,8);
  v_lock_ids         uuid[];
  v_uid              uuid;
  v_other            record;
  v_other_ids        uuid[] := '{}';
  v_other_buyers     uuid[] := '{}';
  v_other_prices     numeric(20,8)[] := '{}';
  i                  integer;
  v_highest_offer_id uuid;
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
  -- NEW (0056): only the highest open offer on this listing may be
  -- accepted. Recomputed here, under the offer's own row lock from
  -- step 1 plus the listing lock from step 2, so this reflects the
  -- true state at execution time — not whatever the client last saw.
  -- Tie-break: offer_price_mpxn desc, then created_at asc (earliest
  -- of equal-price offers wins), then id asc as a final deterministic
  -- tie-breaker for the (extremely unlikely) case of identical price
  -- AND identical created_at. This is a read-only comparison — no
  -- balance or inventory movement has happened yet, and none happens
  -- below if this check fails.
  -- ---------------------------------------------------------------
  select o.id
    into v_highest_offer_id
    from public.marketplace_offers as o
   where o.listing_id = v_listing
     and o.status = 'open'
   order by o.offer_price_mpxn desc, o.created_at asc, o.id asc
   limit 1;

  if v_highest_offer_id is distinct from p_offer_id then
    raise exception 'marketplace_accept_offer: only the highest open offer can be accepted (offer %, highest %, listing %)',
      p_offer_id, v_highest_offer_id, v_listing
      using errcode = 'PXN47';
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
  'Service-role-only: accepts an open offer, selling the listing to that offer''s buyer at the offer''s price. Locks offer, then listing, then inventory, then every other open offer on the same listing (all fixed order), verifies the caller is the seller (PXN37) and everything is still active/open, verifies the offer being accepted is the HIGHEST open offer on the listing by offer_price_mpxn desc / created_at asc / id asc (PXN47 if not — added in 0056, re-checked live under lock so a stale client view is always rejected), credits the seller net of marketplace_config.marketplace_fee_bps and credits marketplace_config.fee_recipient_user_id (treasury) with the fee — the accepted buyer''s already-escrowed m.PXN is never debited again — refunds and rejects every other open offer on the listing so none remains escrowed, then marks the listing sold and transfers mining_inventory ownership/custody to the buyer (is_listed and is_applied both cleared). Atomic and race-free, including against a concurrent marketplace_buy_listing/marketplace_cancel_listing on the same listing (serialized by the listing row lock) and against concurrent marketplace_cancel_offer calls on the other refunded offers (serialized by locking them here). Never touches pxn_balance. Not callable by anon/authenticated.';

revoke all on function public.marketplace_accept_offer(uuid, uuid) from public;
revoke all on function public.marketplace_accept_offer(uuid, uuid) from anon;
revoke all on function public.marketplace_accept_offer(uuid, uuid) from authenticated;
grant execute on function public.marketplace_accept_offer(uuid, uuid) to service_role;
