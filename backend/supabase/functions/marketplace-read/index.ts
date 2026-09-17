// Pro-X Network — "marketplace-read" Edge Function.
//
// POST /functions/v1/marketplace-read
//
// READ-ONLY companion to the "marketplace" Edge Function
// (marketplace/index.ts). That function owns every Marketplace
// MUTATION (create/cancel a listing, buy, make/cancel/accept/reject
// an offer) via the seven service-role-only public.marketplace_*
// RPCs (0034_marketplace_rpcs.sql). This file owns every Marketplace
// READ the frontend needs to render Browse / My Listings / My Offers
// / Offers Received — and nothing else.
//
// This file NEVER:
//   - calls any public.marketplace_* RPC (create_listing, cancel_listing,
//     buy_listing, make_offer, cancel_offer, accept_offer, reject_offer)
//   - calls public.adjust_claimed_total or public.adjust_pxn_balance
//   - calls public.level_up_mining, public.claim_mining,
//     public.purchase_miner, public.upgrade_miner, or
//     public.set_miner_applied
//   - INSERTs, UPDATEs, or DELETEs any row in any table
//   - reads or writes public.mining_state.claimed_total (m.PXN) or
//     public.mining_state.pxn_balance (PXN) directly — it never
//     touches public.mining_state at all
//   - reads or writes public.mining_inventory.is_listed,
//     miner_level, miner_speed, or is_applied — it only ever reads
//     the small set of display columns listed below, for rows
//     already legitimized by a listing/offer the caller is allowed
//     to see (see the "Why service_role is used, narrowly" note
//     below)
//
// Currency: every price returned by this function (asking_price_mpxn,
// offer_price_mpxn) is m.PXN, matching marketplace_listings and
// marketplace_offers' own column names and comments
// (0032_marketplace_tables.sql). This file never reads pxn_balance
// and never labels anything it returns as plain "PXN".
//
// Authentication: identical pattern to functions/me,
// functions/marketplace, functions/level-up-mining, and every other
// player-data function in this project — a per-request,
// caller-scoped supabase-js client (anon key + the caller's own
// `Authorization: Bearer <token>` access token) is created, and
// `auth.getUser()` is the SOLE source of the caller's identity.
//   - `verify_jwt = true` should be set for this function in
//     config.toml (see the note at the end of this file) so the
//     Supabase platform already rejects missing/malformed/expired
//     tokens before this code runs. The explicit getUser() call below
//     is a second, independent check inside the function itself
//     (defense in depth), exactly like every sibling function.
//   - The authenticated user's UUID is the ONLY identity ever used to
//     decide what this function returns. No field named user_id,
//     buyer_user_id, or seller_user_id is ever read from the request
//     body — even if a caller sends one, it is ignored for
//     authorization purposes.
//
// Database access — two different clients, used for two different
// purposes:
//
//   1. A per-request, caller-scoped client (anon key + caller's own
//      access token) is used for every read of marketplace_listings
//      and marketplace_offers. These two tables already carry the
//      exact RLS policies this function needs
//      (0032_marketplace_tables.sql):
//        - marketplace_listings: "active" rows are visible to any
//          authenticated user; a caller's own listings (any status)
//          are visible to them as seller; a caller's own completed
//          purchase is visible to them as buyer.
//        - marketplace_offers: a caller sees their own offers (as
//          buyer), and offers placed on listings THEY own (as
//          seller) — no policy exposes any other offer.
//      Going through the caller-scoped client (not service_role) for
//      these two tables means Postgres' own RLS engine — not this
//      file's logic — is what actually enforces "no unrelated user's
//      private offer is ever returned". This is the strongest
//      privacy guarantee available and is used wherever the schema
//      makes it possible.
//
//   2. getSupabaseAdmin() (service-role client) is used ONLY to fetch
//      a small set of DISPLAY columns from public.mining_inventory
//      (miner_tier, miner_name, miner_icon, miner_level, miner_speed)
//      for items referenced by rows the caller-scoped client has
//      ALREADY legitimately returned in step 1 above. This is
//      necessary because mining_inventory's own RLS policy
//      (0014_mining_inventory.sql) only lets a user read THEIR OWN
//      inventory rows — but Browse and "offers received"/"offers
//      sent" all need to display the *seller's* item (name/icon/tier)
//      to a buyer who is not that seller, which the caller-scoped
//      client structurally cannot do. The service-role lookup below
//      is deliberately narrow: it is always scoped to an explicit
//      `id in (...)` list built ONLY from mining_inventory_id values
//      already present on rows that step 1 already authorized for
//      this caller — never a free-form or caller-suppliable filter.
//      No other table is ever read with the service-role client in
//      this file.
//
// Response shape (matches marketplace/index.ts exactly):
//   Success: { "success": true, "data": <action-specific payload> }
//   Error:   { "success": false, "error": { "code": "...", "message": "..." } }
//
// HTTP: POST only. OPTIONS returns the shared CORS response. Any
// other method is rejected with 405 before the body is even read.
//
// Never logs the access token, the service-role key, or any other
// secret. Never exposes a raw database error message to the client.

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

// --- Generic error envelope helpers -----------------------------------

interface AppError {
  code: string;
  message: string;
}

function errorResponse(status: number, code: string, message: string): Response {
  return jsonResponse({ success: false, error: { code, message } as AppError }, status);
}

const UNAUTHORIZED = () => errorResponse(401, "UNAUTHORIZED", "Unauthorized");

// --- UUID validation (same pattern as functions/marketplace) ----------

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

/** Coerces a numeric(20,8) column (which postgres-js may return as a string) to a JS number. */
function toNumber(value: unknown): number {
  return typeof value === "number" ? value : Number(value);
}

// --- Request shape validation -------------------------------------------

type ParsedAction =
  | { action: "list_active_listings"; limit: number; before: string | null }
  | { action: "get_listing"; listing_id: string }
  | { action: "get_my_listings"; limit: number; status: string | null }
  | { action: "get_my_offers"; limit: number; status: string | null }
  | { action: "get_seller_offers"; limit: number; listing_id: string | null };

type ParseResult =
  | { ok: true; value: ParsedAction }
  | { ok: false; message: string };

const SUPPORTED_ACTIONS = new Set([
  "list_active_listings",
  "get_listing",
  "get_my_listings",
  "get_my_offers",
  "get_seller_offers",
]);

const LISTING_STATUSES = new Set(["active", "sold", "cancelled"]);
const OFFER_STATUSES = new Set(["open", "accepted", "rejected", "cancelled"]);

const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 50;

/** Strict, defensive parsing of an optional "limit" field: a JSON integer in [1, MAX_LIMIT], defaulting to DEFAULT_LIMIT. Never coerces strings. */
function parseLimit(value: unknown): { ok: true; value: number } | { ok: false } {
  if (value === undefined || value === null) {
    return { ok: true, value: DEFAULT_LIMIT };
  }
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > MAX_LIMIT) {
    return { ok: false };
  }
  return { ok: true, value };
}

/** Strict, defensive parsing of an optional "before" cursor: a JSON string that parses as a valid date. Used to page created_at DESC. */
function parseBefore(value: unknown): { ok: true; value: string | null } | { ok: false } {
  if (value === undefined || value === null) {
    return { ok: true, value: null };
  }
  if (typeof value !== "string" || Number.isNaN(Date.parse(value))) {
    return { ok: false };
  }
  return { ok: true, value };
}

function parseRequest(body: unknown): ParseResult {
  if (typeof body !== "object" || body === null) {
    return { ok: false, message: "Request body must be a JSON object" };
  }
  const rec = body as Record<string, unknown>;
  const action = rec.action;

  if (typeof action !== "string" || !SUPPORTED_ACTIONS.has(action)) {
    return {
      ok: false,
      message:
        "action must be one of: list_active_listings, get_listing, get_my_listings, get_my_offers, get_seller_offers",
    };
  }

  switch (action) {
    case "list_active_listings": {
      const limitResult = parseLimit(rec.limit);
      if (!limitResult.ok) return { ok: false, message: "limit must be an integer between 1 and 50" };
      const beforeResult = parseBefore(rec.before);
      if (!beforeResult.ok) return { ok: false, message: "before must be a valid ISO timestamp string" };
      return { ok: true, value: { action, limit: limitResult.value, before: beforeResult.value } };
    }

    case "get_listing": {
      if (!isUuid(rec.listing_id)) {
        return { ok: false, message: "listing_id must be a valid UUID" };
      }
      return { ok: true, value: { action, listing_id: rec.listing_id } };
    }

    case "get_my_listings": {
      const limitResult = parseLimit(rec.limit);
      if (!limitResult.ok) return { ok: false, message: "limit must be an integer between 1 and 50" };
      if (rec.status !== undefined && rec.status !== null) {
        if (typeof rec.status !== "string" || !LISTING_STATUSES.has(rec.status)) {
          return { ok: false, message: "status must be one of: active, sold, cancelled" };
        }
      }
      return {
        ok: true,
        value: { action, limit: limitResult.value, status: (rec.status as string) ?? null },
      };
    }

    case "get_my_offers": {
      const limitResult = parseLimit(rec.limit);
      if (!limitResult.ok) return { ok: false, message: "limit must be an integer between 1 and 50" };
      if (rec.status !== undefined && rec.status !== null) {
        if (typeof rec.status !== "string" || !OFFER_STATUSES.has(rec.status)) {
          return { ok: false, message: "status must be one of: open, accepted, rejected, cancelled" };
        }
      }
      return {
        ok: true,
        value: { action, limit: limitResult.value, status: (rec.status as string) ?? null },
      };
    }

    case "get_seller_offers": {
      const limitResult = parseLimit(rec.limit);
      if (!limitResult.ok) return { ok: false, message: "limit must be an integer between 1 and 50" };
      if (rec.listing_id !== undefined && rec.listing_id !== null && !isUuid(rec.listing_id)) {
        return { ok: false, message: "listing_id must be a valid UUID when provided" };
      }
      return {
        ok: true,
        value: {
          action,
          limit: limitResult.value,
          listing_id: (rec.listing_id as string) ?? null,
        },
      };
    }

    default: {
      const exhaustive: never = action as never;
      return { ok: false, message: `Unsupported action: ${String(exhaustive)}` };
    }
  }
}

// --- mining_inventory display-field lookup (service_role, narrowly scoped) --

interface InventoryDisplayRow {
  id: string;
  miner_tier: number;
  miner_name: string;
  miner_icon: string | null;
  miner_level: number;
  miner_speed: number | string;
}

interface InventoryDisplay {
  mining_inventory_id: string;
  miner_tier: number;
  miner_name: string;
  miner_icon: string | null;
  miner_level: number;
  miner_speed: number;
}

/**
 * Fetches ONLY the display columns (miner_tier, miner_name, miner_icon,
 * miner_level, miner_speed) for a caller-supplied set of
 * mining_inventory ids, and returns them keyed by id.
 *
 * SECURITY NOTE: this is the only place in this file that uses the
 * service-role client, and it is deliberately narrow — `ids` must
 * always be built by the caller of this helper from
 * mining_inventory_id values already present on marketplace_listings
 * or marketplace_offers rows that the caller-scoped (RLS-enforced)
 * client already returned to THIS authenticated user in the same
 * request. This function never accepts a caller-suppliable id list
 * from the request body directly, and never queries any column
 * beyond the five listed above (in particular: never is_listed,
 * is_applied, or user_id).
 */
async function fetchInventoryDisplayMap(
  admin: SupabaseClient,
  ids: string[],
): Promise<Map<string, InventoryDisplay>> {
  const map = new Map<string, InventoryDisplay>();
  const uniqueIds = Array.from(new Set(ids)).filter(isUuid);
  if (uniqueIds.length === 0) return map;

  const { data, error } = await admin
    .from("mining_inventory")
    .select("id, miner_tier, miner_name, miner_icon, miner_level, miner_speed")
    .in("id", uniqueIds);

  if (error || !data) {
    // Display enrichment is best-effort: a lookup failure here should
    // never break the listing/offer read itself. Callers get back
    // whatever rows DID resolve (possibly none), never an error.
    console.error("[marketplace-read] inventory display lookup failed:", error?.message);
    return map;
  }

  for (const row of data as InventoryDisplayRow[]) {
    map.set(row.id, {
      mining_inventory_id: row.id,
      miner_tier: row.miner_tier,
      miner_name: row.miner_name,
      miner_icon: row.miner_icon,
      miner_level: row.miner_level,
      miner_speed: toNumber(row.miner_speed),
    });
  }
  return map;
}

// --- Row shaping helpers --------------------------------------------------

interface ListingRow {
  id: string;
  seller_user_id: string;
  mining_inventory_id: string;
  asking_price_mpxn: number | string;
  status: string;
  buyer_user_id: string | null;
  sold_at: string | null;
  created_at: string;
  updated_at: string;
}

interface OfferRow {
  id: string;
  listing_id: string;
  buyer_user_id: string;
  offer_price_mpxn: number | string;
  status: string;
  created_at: string;
  updated_at: string;
}

/**
 * Shapes a marketplace_listings row for the client. Never returns any
 * column beyond what's listed here — in particular, no telegram
 * identity or other public.users field is ever joined in or exposed;
 * seller/buyer are surfaced only as their opaque user_id (uuid),
 * which is already the caller's own everyday PLAYER_ID concept.
 */
function shapeListing(
  row: ListingRow,
  callerId: string,
  item: InventoryDisplay | undefined,
) {
  return {
    listing_id: row.id,
    seller_user_id: row.seller_user_id,
    is_own_listing: row.seller_user_id === callerId,
    mining_inventory_id: row.mining_inventory_id,
    asking_price_mpxn: toNumber(row.asking_price_mpxn),
    status: row.status,
    buyer_user_id: row.buyer_user_id,
    is_own_purchase: row.buyer_user_id === callerId,
    sold_at: row.sold_at,
    created_at: row.created_at,
    item: item ?? null,
  };
}

/** Shapes a marketplace_offers row for the client. Never exposes any field beyond these. */
function shapeOffer(
  row: OfferRow,
  callerId: string,
  listing: ListingRow | undefined,
  item: InventoryDisplay | undefined,
) {
  return {
    offer_id: row.id,
    listing_id: row.listing_id,
    buyer_user_id: row.buyer_user_id,
    is_own_offer: row.buyer_user_id === callerId,
    offer_price_mpxn: toNumber(row.offer_price_mpxn),
    status: row.status,
    created_at: row.created_at,
    updated_at: row.updated_at,
    listing: listing
      ? {
          listing_id: listing.id,
          seller_user_id: listing.seller_user_id,
          asking_price_mpxn: toNumber(listing.asking_price_mpxn),
          status: listing.status,
        }
      : null,
    item: item ?? null,
  };
}

// --- Main handler ----------------------------------------------------------

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse(405, "METHOD_NOT_ALLOWED", "Method not allowed");
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return UNAUTHORIZED();
  }

  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return errorResponse(400, "VALIDATION_ERROR", "Request body must be valid JSON");
  }

  const parsed = parseRequest(rawBody);
  if (!parsed.ok) {
    return errorResponse(400, "VALIDATION_ERROR", parsed.message);
  }
  const parsedAction = parsed.value;

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[marketplace-read] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(500, "SERVICE_UNAVAILABLE", "Service temporarily unavailable");
  }

  // Per-request, caller-scoped client. Used for BOTH the identity
  // check below AND every read of marketplace_listings /
  // marketplace_offers, so that Postgres' own RLS policies — not this
  // file's logic — decide which rows come back. Never used to read
  // mining_inventory (that table's RLS would incorrectly restrict a
  // browsing buyer to only their own items — see the service-role
  // note above).
  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return UNAUTHORIZED();
  }
  const userId = authData.user.id;

  let admin: SupabaseClient;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[marketplace-read] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(500, "SERVICE_UNAVAILABLE", "Service temporarily unavailable");
  }

  try {
    switch (parsedAction.action) {
      // -----------------------------------------------------------------
      // list_active_listings — public Browse tab. RLS's own "active rows
      // are visible to any authenticated user" policy does the real
      // filtering; the explicit .eq("status","active") below is
      // defense-in-depth so this action never accidentally returns a
      // caller's own non-active listing via the OTHER policies that
      // also apply to this table.
      // -----------------------------------------------------------------
      case "list_active_listings": {
        let query = userClient
          .from("marketplace_listings")
          .select("*")
          .eq("status", "active")
          .order("created_at", { ascending: false })
          .limit(parsedAction.limit);

        if (parsedAction.before) {
          query = query.lt("created_at", parsedAction.before);
        }

        const { data, error } = await query;
        if (error) {
          console.error("[marketplace-read] list_active_listings failed:", error.message);
          return errorResponse(500, "INTERNAL_ERROR", "Could not load marketplace listings");
        }

        const rows = (data ?? []) as ListingRow[];
        const itemMap = await fetchInventoryDisplayMap(
          admin,
          rows.map((r) => r.mining_inventory_id),
        );
        const listings = rows.map((r) => shapeListing(r, userId, itemMap.get(r.mining_inventory_id)));

        return jsonResponse({ success: true, data: { listings } }, 200);
      }

      // -----------------------------------------------------------------
      // get_listing — a single listing. RLS allows this caller to see it
      // if it's active, OR they are its seller, OR they are its buyer
      // (a completed purchase). Any other listing_id resolves to zero
      // rows here — never a 403 that would confirm the row exists.
      // -----------------------------------------------------------------
      case "get_listing": {
        const { data, error } = await userClient
          .from("marketplace_listings")
          .select("*")
          .eq("id", parsedAction.listing_id)
          .maybeSingle();

        if (error) {
          console.error("[marketplace-read] get_listing failed:", error.message);
          return errorResponse(500, "INTERNAL_ERROR", "Could not load listing");
        }
        if (!data) {
          return errorResponse(404, "LISTING_NOT_FOUND", "Listing not found");
        }

        const row = data as ListingRow;
        const itemMap = await fetchInventoryDisplayMap(admin, [row.mining_inventory_id]);
        const listing = shapeListing(row, userId, itemMap.get(row.mining_inventory_id));

        return jsonResponse({ success: true, data: { listing } }, 200);
      }

      // -----------------------------------------------------------------
      // get_my_listings — "My Listings" tab. Explicit
      // .eq("seller_user_id", userId) is defense-in-depth on top of the
      // "marketplace_listings_select_own_seller" RLS policy, which
      // already guarantees this query can never return another
      // player's listing. mining_inventory rows here belong to the
      // caller themselves (they're the seller), so this data was
      // actually already readable via the caller-scoped client too —
      // the shared display-lookup helper is reused anyway for a single
      // consistent code path.
      // -----------------------------------------------------------------
      case "get_my_listings": {
        let query = userClient
          .from("marketplace_listings")
          .select("*")
          .eq("seller_user_id", userId)
          .order("created_at", { ascending: false })
          .limit(parsedAction.limit);

        if (parsedAction.status) {
          query = query.eq("status", parsedAction.status);
        }

        const { data, error } = await query;
        if (error) {
          console.error("[marketplace-read] get_my_listings failed:", error.message);
          return errorResponse(500, "INTERNAL_ERROR", "Could not load your listings");
        }

        const rows = (data ?? []) as ListingRow[];
        const itemMap = await fetchInventoryDisplayMap(
          admin,
          rows.map((r) => r.mining_inventory_id),
        );
        const listings = rows.map((r) => shapeListing(r, userId, itemMap.get(r.mining_inventory_id)));

        return jsonResponse({ success: true, data: { listings } }, 200);
      }

      // -----------------------------------------------------------------
      // get_my_offers — "My Sent Offers" tab. Explicit
      // .eq("buyer_user_id", userId) is defense-in-depth on top of the
      // "marketplace_offers_select_own_buyer" RLS policy. The
      // associated listing may belong to ANOTHER player (the seller),
      // so it — and its item — are fetched via a second, narrowly
      // scoped read: the listing_ids come only from offer rows this
      // caller already legitimately owns.
      // -----------------------------------------------------------------
      case "get_my_offers": {
        let query = userClient
          .from("marketplace_offers")
          .select("*")
          .eq("buyer_user_id", userId)
          .order("created_at", { ascending: false })
          .limit(parsedAction.limit);

        if (parsedAction.status) {
          query = query.eq("status", parsedAction.status);
        }

        const { data, error } = await query;
        if (error) {
          console.error("[marketplace-read] get_my_offers failed:", error.message);
          return errorResponse(500, "INTERNAL_ERROR", "Could not load your offers");
        }

        const offerRows = (data ?? []) as OfferRow[];
        const listingIds = Array.from(new Set(offerRows.map((o) => o.listing_id))).filter(isUuid);

        // Narrow, service-role listing lookup: restricted to exactly the
        // listing_ids referenced by this caller's own offers (already
        // authorized above via RLS on marketplace_offers). This is
        // needed because a sold-to-someone-else listing is no longer
        // readable to this buyer via marketplace_listings' own RLS.
        let listingMap = new Map<string, ListingRow>();
        if (listingIds.length > 0) {
          const { data: listingRows, error: listingError } = await admin
            .from("marketplace_listings")
            .select("*")
            .in("id", listingIds);
          if (listingError) {
            console.error("[marketplace-read] get_my_offers listing lookup failed:", listingError.message);
          } else {
            listingMap = new Map((listingRows as ListingRow[]).map((l) => [l.id, l]));
          }
        }

        const itemMap = await fetchInventoryDisplayMap(
          admin,
          Array.from(listingMap.values()).map((l) => l.mining_inventory_id),
        );

        const offers = offerRows.map((o) => {
          const listing = listingMap.get(o.listing_id);
          const item = listing ? itemMap.get(listing.mining_inventory_id) : undefined;
          return shapeOffer(o, userId, listing, item);
        });

        return jsonResponse({ success: true, data: { offers } }, 200);
      }

      // -----------------------------------------------------------------
      // get_seller_offers — "Offers Received" — offers placed on
      // listings THIS caller owns as seller. The
      // "marketplace_offers_select_own_seller" RLS policy (an EXISTS
      // join back to marketplace_listings.seller_user_id = auth.uid())
      // is exactly the check this action needs, so this read is fully
      // RLS-native — no service-role read of marketplace_offers itself
      // is ever performed. The listing/item info is fetchable directly
      // by the caller too, since they are its seller.
      // -----------------------------------------------------------------
      case "get_seller_offers": {
        let query = userClient
          .from("marketplace_offers")
          .select("*")
          .order("created_at", { ascending: false })
          .limit(parsedAction.limit);

        if (parsedAction.listing_id) {
          query = query.eq("listing_id", parsedAction.listing_id);
        }

        const { data, error } = await query;
        if (error) {
          console.error("[marketplace-read] get_seller_offers failed:", error.message);
          return errorResponse(500, "INTERNAL_ERROR", "Could not load offers on your listings");
        }

        const offerRows = (data ?? []) as OfferRow[];
        const listingIds = Array.from(new Set(offerRows.map((o) => o.listing_id))).filter(isUuid);

        let listingMap = new Map<string, ListingRow>();
        if (listingIds.length > 0) {
          const { data: listingRows, error: listingError } = await userClient
            .from("marketplace_listings")
            .select("*")
            .in("id", listingIds);
          if (listingError) {
            console.error("[marketplace-read] get_seller_offers listing lookup failed:", listingError.message);
          } else {
            listingMap = new Map((listingRows as ListingRow[]).map((l) => [l.id, l]));
          }
        }

        const itemMap = await fetchInventoryDisplayMap(
          admin,
          Array.from(listingMap.values()).map((l) => l.mining_inventory_id),
        );

        const offers = offerRows.map((o) => {
          const listing = listingMap.get(o.listing_id);
          const item = listing ? itemMap.get(listing.mining_inventory_id) : undefined;
          return shapeOffer(o, userId, listing, item);
        });

        return jsonResponse({ success: true, data: { offers } }, 200);
      }

      default: {
        const exhaustive: never = parsedAction;
        console.error("[marketplace-read] unreachable action:", exhaustive);
        return errorResponse(500, "INTERNAL_ERROR", "Could not process request");
      }
    }
  } catch (err) {
    console.error(
      "[marketplace-read] unexpected error:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(500, "INTERNAL_ERROR", "Could not process request");
  }
});

// ---------------------------------------------------------------------
// Deployment note (informational only — this migration/config change
// is NOT made by this file): like accrue-mining and
// get-mining-inventory, this function reads the caller's own
// player-owned data (and, transitively, other players' public
// listing data), so it should get its own
//   [functions.marketplace-read]
//   verify_jwt = true
// block in backend/supabase/config.toml, matching the existing
// convention documented there. That edit is left for the person
// deploying this function — no existing file is modified by this
// change.
// ---------------------------------------------------------------------
