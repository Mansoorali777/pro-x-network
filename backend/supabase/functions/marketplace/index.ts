// Pro-X Network — "marketplace" Edge Function.
//
// POST /functions/v1/marketplace
//
// Server-authoritative Marketplace router. This is the single HTTP
// entry point for all seven Marketplace actions (create/cancel a
// listing, buy a listing outright, make/cancel an offer, accept/
// reject an offer). It does not implement any Marketplace business
// logic itself — every ownership check, status check, balance
// movement, fee calculation, and inventory-custody transfer happens
// inside the corresponding SECURITY DEFINER Postgres RPC created by
// 0034_marketplace_rpcs.sql (which itself builds on
// 0032_marketplace_tables.sql and 0033_marketplace_inventory_custody.sql).
// This file's only jobs are: authenticate the caller, strictly
// validate the shape of the request body, dispatch to the right RPC
// with the authenticated user's id in the correct parameter slot, and
// translate the RPC's result (or PXNxx error code) into a clean JSON
// HTTP response. It does NOT touch mining_state, claimed_total,
// pxn_balance, mpxn_ledger, marketplace_listings, marketplace_offers,
// or mining_inventory directly — every one of those reads/writes
// happens inside the RPCs themselves.
//
// Currency: Marketplace uses m.PXN only — the authoritative gameplay
// balance is public.mining_state.claimed_total. This file never
// reads, writes, or references public.mining_state.pxn_balance, and
// never creates a second balance system.
//
// SUPPORTED ACTIONS (see the per-action parse* functions below for
// exact request shapes):
//   1. create_listing  -> public.marketplace_create_listing
//   2. cancel_listing  -> public.marketplace_cancel_listing
//   3. buy_listing     -> public.marketplace_buy_listing
//   4. make_offer      -> public.marketplace_make_offer
//   5. cancel_offer    -> public.marketplace_cancel_offer
//   6. accept_offer    -> public.marketplace_accept_offer
//   7. reject_offer    -> public.marketplace_reject_offer
//
// Authentication: identical pattern to functions/me,
// functions/purchase-miner, functions/upgrade-miner,
// functions/claim-mining, and functions/level-up-mining — a
// per-request, caller-scoped supabase-js client (anon key + the
// caller's own `Authorization: Bearer <token>` access token) is used,
// and `auth.getUser()` is the sole source of the caller's identity.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — the ONLY user id ever used in this function.
//   - This is the normal Supabase JWT/session mechanism. There is no
//     custom JWT/JWKS/private-JWK system anywhere in this file, no
//     Telegram initData is read or verified here, and
//     SUPABASE_JWT_SECRET is never read or referenced.
//   - The authenticated user's UUID is the ONLY identity ever passed
//     to an RPC — never a value from the request body. In
//     particular, this file never reads a user_id, seller_user_id, or
//     buyer_user_id field from the request body, and even if a
//     caller sends one it is ignored:
//       - create_listing / cancel_listing -> p_user_id        = authenticated user
//       - buy_listing                     -> p_buyer_user_id  = authenticated user
//       - make_offer / cancel_offer       -> p_buyer_user_id  = authenticated user
//       - accept_offer / reject_offer     -> p_seller_user_id = authenticated user
//
// Database access:
//   - getSupabaseAdmin() (service-role client) is used ONLY to call
//     the seven public.marketplace_* RPCs. It is never used to read
//     or write mining_state, claimed_total, pxn_balance,
//     mpxn_ledger, marketplace_listings, marketplace_offers, or
//     mining_inventory directly from this file — every one of those
//     reads/writes happens inside the single atomic transaction of
//     the SECURITY DEFINER function itself.
//   - Every public.marketplace_* RPC is GRANTed to service_role only
//     (REVOKEd from public/anon/authenticated), so only this Edge
//     Function — never a client calling the PostgREST RPC endpoint
//     directly — can invoke them.
//
// Request validation performed HERE (before any database call):
//   - `action` is present and is one of the seven supported strings.
//   - Every uuid-shaped field (inventory_id, listing_id, offer_id) is
//     present and is a syntactically valid UUID.
//   - Every price field (asking_price_mpxn, offer_price_mpxn) is
//     present, a JSON number, finite, and > 0.
//   - No business/security check (ownership, listing/offer status,
//     balance sufficiency, marketplace kill switch, treasury
//     configuration, concurrency, double-spend protection) is
//     performed here — every one of those remains the RPC's
//     responsibility, exactly as instructed. This file only rejects
//     requests that are malformed at the JSON-shape level.
//
// Error handling: every PXNxx SQLSTATE the 0034 RPCs can raise is
// mapped below to a clean application error code and a safe,
// user-facing message. Raw PostgreSQL/database error text is never
// forwarded to the client — unrecognized codes fall back to a
// generic 500.
//
// Response shape (both success and error use this same envelope,
// as requested):
//   Success: { "success": true, "data": <RPC result, field names
//              preserved, numeric(20,8) columns coerced to JS
//              numbers> }
//   Error:   { "success": false, "error": { "code": "<application
//              code>", "message": "<safe user-facing message>" } }
//
// HTTP: POST only. OPTIONS returns the shared CORS response. Any
// other method is rejected with 405 before the body is even read.
//
// Never logs the access token, the service-role key, or any other
// secret. Never exposes a raw database error message to the client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
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

// --- UUID validation (same pattern as functions/level-up-mining) ------

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value);
}

/**
 * Strict validation for a "price" field (asking_price_mpxn /
 * offer_price_mpxn): must be present, a JSON number, finite, and
 * strictly greater than zero. Never coerces strings/booleans/null.
 */
function isPositiveFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

// --- Request shape validation -------------------------------------------
//
// Only the seven shapes below are ever accepted. No field other than
// the ones listed for each action is ever read from the body — in
// particular, there is no user_id/seller_user_id/buyer_user_id field
// accepted from any of them (see the header comment above).

type ParsedAction =
  | { action: "create_listing"; inventory_id: string; asking_price_mpxn: number }
  | { action: "cancel_listing"; listing_id: string }
  | { action: "buy_listing"; listing_id: string }
  | { action: "make_offer"; listing_id: string; offer_price_mpxn: number }
  | { action: "cancel_offer"; offer_id: string }
  | { action: "accept_offer"; offer_id: string }
  | { action: "reject_offer"; offer_id: string };

type ParseResult =
  | { ok: true; value: ParsedAction }
  | { ok: false; message: string };

const SUPPORTED_ACTIONS = new Set([
  "create_listing",
  "cancel_listing",
  "buy_listing",
  "make_offer",
  "cancel_offer",
  "accept_offer",
  "reject_offer",
]);

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
        "action must be one of: create_listing, cancel_listing, buy_listing, make_offer, cancel_offer, accept_offer, reject_offer",
    };
  }

  switch (action) {
    case "create_listing": {
      if (!isUuid(rec.inventory_id)) {
        return { ok: false, message: "inventory_id must be a valid UUID" };
      }
      if (!isPositiveFiniteNumber(rec.asking_price_mpxn)) {
        return { ok: false, message: "asking_price_mpxn must be a number greater than zero" };
      }
      return {
        ok: true,
        value: {
          action,
          inventory_id: rec.inventory_id,
          asking_price_mpxn: rec.asking_price_mpxn,
        },
      };
    }

    case "cancel_listing": {
      if (!isUuid(rec.listing_id)) {
        return { ok: false, message: "listing_id must be a valid UUID" };
      }
      return { ok: true, value: { action, listing_id: rec.listing_id } };
    }

    case "buy_listing": {
      if (!isUuid(rec.listing_id)) {
        return { ok: false, message: "listing_id must be a valid UUID" };
      }
      return { ok: true, value: { action, listing_id: rec.listing_id } };
    }

    case "make_offer": {
      if (!isUuid(rec.listing_id)) {
        return { ok: false, message: "listing_id must be a valid UUID" };
      }
      if (!isPositiveFiniteNumber(rec.offer_price_mpxn)) {
        return { ok: false, message: "offer_price_mpxn must be a number greater than zero" };
      }
      return {
        ok: true,
        value: {
          action,
          listing_id: rec.listing_id,
          offer_price_mpxn: rec.offer_price_mpxn,
        },
      };
    }

    case "cancel_offer": {
      if (!isUuid(rec.offer_id)) {
        return { ok: false, message: "offer_id must be a valid UUID" };
      }
      return { ok: true, value: { action, offer_id: rec.offer_id } };
    }

    case "accept_offer": {
      if (!isUuid(rec.offer_id)) {
        return { ok: false, message: "offer_id must be a valid UUID" };
      }
      return { ok: true, value: { action, offer_id: rec.offer_id } };
    }

    case "reject_offer": {
      if (!isUuid(rec.offer_id)) {
        return { ok: false, message: "offer_id must be a valid UUID" };
      }
      return { ok: true, value: { action, offer_id: rec.offer_id } };
    }

    default: {
      // Unreachable — SUPPORTED_ACTIONS.has(action) already narrowed
      // action to one of the seven cases above.
      const exhaustive: never = action as never;
      return { ok: false, message: `Unsupported action: ${String(exhaustive)}` };
    }
  }
}

// --- PXNxx -> clean application error mapping ---------------------------
//
// Every SQLSTATE the 0034 RPCs can raise (PXN30-PXN46), plus the
// pre-existing PXN24/PXN25/PXN26 codes from adjust_claimed_total()
// (0030_mpxn_ledger_primitive.sql) that marketplace_buy_listing,
// marketplace_make_offer, marketplace_accept_offer, and
// marketplace_cancel_offer / marketplace_reject_offer can also
// surface via their own calls into that primitive. Never forwards a
// raw PostgreSQL error message to the client.

function mapPgError(code: string | undefined, rawMessage: string): { status: number; error: AppError } {
  switch (code) {
    // --- adjust_claimed_total() codes, reachable through several
    //     marketplace RPCs (buy_listing, make_offer, accept_offer's
    //     refund loop, cancel_offer, reject_offer). ---
    case "PXN24":
      return {
        status: 400,
        error: { code: "INSUFFICIENT_BALANCE", message: "Insufficient m.PXN balance" },
      };
    case "PXN25":
      return {
        status: 404,
        error: {
          code: "NO_MINING_STATE",
          message: "Mining data is not initialized for one of the accounts in this transaction",
        },
      };
    case "PXN26":
      return {
        status: 409,
        error: { code: "DUPLICATE_REQUEST", message: "This request was already processed" },
      };

    // --- 0034 marketplace-specific codes. ---
    case "PXN30":
      return {
        status: 400,
        error: { code: "VALIDATION_ERROR", message: "A required field was missing" },
      };
    case "PXN31":
      return {
        status: 400,
        error: { code: "VALIDATION_ERROR", message: "Price must be greater than zero" },
      };
    case "PXN32":
      return {
        status: 404,
        error: {
          code: "INVENTORY_NOT_FOUND",
          message: "Inventory item not found or not owned by you",
        },
      };
    case "PXN33":
      return {
        status: 409,
        error: { code: "ALREADY_LISTED", message: "This item is already listed" },
      };
    case "PXN34":
      return {
        status: 409,
        error: {
          code: "ITEM_APPLIED",
          message: "Remove this item from its active mining slot before listing it",
        },
      };
    case "PXN35":
      return {
        status: 404,
        error: { code: "LISTING_NOT_FOUND", message: "Listing not found" },
      };
    case "PXN36":
      return {
        status: 409,
        error: { code: "LISTING_NOT_ACTIVE", message: "This listing is no longer active" },
      };
    case "PXN37":
      return {
        status: 403,
        error: { code: "NOT_LISTING_OWNER", message: "You do not own this listing" },
      };
    case "PXN38":
      return {
        status: 409,
        error: {
          code: "CANNOT_TRADE_OWN_LISTING",
          message: "You cannot buy or make an offer on your own listing",
        },
      };
    case "PXN39":
      return {
        status: 409,
        error: {
          code: "LISTING_INVENTORY_MISMATCH",
          message: "This listing's item is no longer available",
        },
      };
    case "PXN40":
      return {
        status: 404,
        error: { code: "OFFER_NOT_FOUND", message: "Offer not found" },
      };
    case "PXN41":
      return {
        status: 409,
        error: { code: "OFFER_NOT_OPEN", message: "This offer is no longer open" },
      };
    case "PXN42":
      return {
        status: 403,
        error: { code: "NOT_OFFER_BUYER", message: "You did not place this offer" },
      };
    case "PXN43":
      return {
        status: 403,
        error: {
          code: "NOT_LISTING_OWNER",
          message: "You do not own the listing this offer was made on",
        },
      };
    case "PXN44":
      console.error("[marketplace] marketplace_config unseeded or treasury not configured:", rawMessage);
      return {
        status: 500,
        error: {
          code: "MARKETPLACE_MISCONFIGURED",
          message: "Marketplace is temporarily unavailable",
        },
      };
    case "PXN45":
      return {
        status: 409,
        error: { code: "MARKETPLACE_PAUSED", message: "Marketplace is currently paused" },
      };
    case "PXN46":
      return {
        status: 409,
        error: {
          code: "DUPLICATE_OFFER",
          message: "You already have an open offer on this listing",
        },
      };
    default:
      console.error("[marketplace] unmapped RPC error:", code, rawMessage);
      return {
        status: 500,
        error: { code: "INTERNAL_ERROR", message: "Could not complete marketplace request" },
      };
  }
}

// --- Numeric coercion helper for RPC result rows -------------------------
//
// numeric(20,8) columns can come back from postgres-js as strings;
// every numeric field returned to the client is coerced to a JS
// number here so the frontend never has to guess.

function toNumber(value: unknown): number {
  return typeof value === "number" ? value : Number(value);
}

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

  // --- Parse and strictly validate the request body BEFORE touching
  // auth or the database. ---
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
      "[marketplace] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(500, "SERVICE_UNAVAILABLE", "Service temporarily unavailable");
  }

  // Per-request, caller-scoped client — used ONLY for the identity
  // check below, exactly like functions/me, functions/purchase-miner,
  // functions/upgrade-miner, functions/claim-mining, and
  // functions/level-up-mining. Never used for any database read or
  // write in this function.
  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  // --- Validate the token via the normal Supabase Auth mechanism. ---
  // getUser() asks Supabase's Auth server to verify the token; we
  // never decode or trust the JWT's claims ourselves, and the
  // resulting user id is the ONLY identity used anywhere below —
  // never a value from the request body.
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return UNAUTHORIZED();
  }
  const userId = authData.user.id;

  // Service-role client — the only client that may call the
  // public.marketplace_* RPCs (each GRANTed to service_role only).
  // Every ownership check, status check, balance movement, fee
  // calculation, and custody transfer happens inside that single RPC
  // call, not in this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[marketplace] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(500, "SERVICE_UNAVAILABLE", "Service temporarily unavailable");
  }

  // --- Dispatch to the correct RPC, with the authenticated user's id
  // in the correct parameter slot. No value from the request body is
  // ever used as a user identity — see the header comment above for
  // the full p_user_id / p_buyer_user_id / p_seller_user_id mapping.
  let rpcName: string;
  let rpcParams: Record<string, unknown>;

  switch (parsedAction.action) {
    case "create_listing":
      rpcName = "marketplace_create_listing";
      rpcParams = {
        p_user_id: userId,
        p_inventory_id: parsedAction.inventory_id,
        p_asking_price_mpxn: parsedAction.asking_price_mpxn,
      };
      break;
    case "cancel_listing":
      rpcName = "marketplace_cancel_listing";
      rpcParams = { p_user_id: userId, p_listing_id: parsedAction.listing_id };
      break;
    case "buy_listing":
      rpcName = "marketplace_buy_listing";
      rpcParams = { p_buyer_user_id: userId, p_listing_id: parsedAction.listing_id };
      break;
    case "make_offer":
      rpcName = "marketplace_make_offer";
      rpcParams = {
        p_buyer_user_id: userId,
        p_listing_id: parsedAction.listing_id,
        p_offer_price_mpxn: parsedAction.offer_price_mpxn,
      };
      break;
    case "cancel_offer":
      rpcName = "marketplace_cancel_offer";
      rpcParams = { p_buyer_user_id: userId, p_offer_id: parsedAction.offer_id };
      break;
    case "accept_offer":
      rpcName = "marketplace_accept_offer";
      rpcParams = { p_seller_user_id: userId, p_offer_id: parsedAction.offer_id };
      break;
    case "reject_offer":
      rpcName = "marketplace_reject_offer";
      rpcParams = { p_seller_user_id: userId, p_offer_id: parsedAction.offer_id };
      break;
  }

  const { data: rpcData, error: rpcError } = await admin.rpc(rpcName, rpcParams).maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;
    const mapped = mapPgError(code, rpcError.message);
    return errorResponse(mapped.status, mapped.error.code, mapped.error.message);
  }

  if (!rpcData) {
    console.error(`[marketplace] ${rpcName} RPC returned no row`);
    return errorResponse(500, "INTERNAL_ERROR", "Could not complete marketplace request");
  }

  const row = rpcData as Record<string, unknown>;

  // --- Shape the response per action. Field names are preserved from
  // the RPC's RETURNS TABLE; numeric(20,8) columns are coerced to JS
  // numbers so the frontend never has to guess whether it received a
  // string or a number. ---
  let data: Record<string, unknown>;

  switch (parsedAction.action) {
    case "create_listing":
      data = {
        listing_id: row.listing_id,
        seller_user_id: row.seller_user_id,
        mining_inventory_id: row.mining_inventory_id,
        asking_price_mpxn: toNumber(row.asking_price_mpxn),
        status: row.status,
        created_at: row.created_at,
      };
      break;
    case "cancel_listing":
      data = {
        listing_id: row.listing_id,
        seller_user_id: row.seller_user_id,
        mining_inventory_id: row.mining_inventory_id,
        status: row.status,
        updated_at: row.updated_at,
      };
      break;
    case "buy_listing":
      data = {
        listing_id: row.listing_id,
        inventory_id: row.inventory_id,
        seller_user_id: row.seller_user_id,
        buyer_user_id: row.buyer_user_id,
        asking_price_mpxn: toNumber(row.asking_price_mpxn),
        marketplace_fee_mpxn: toNumber(row.marketplace_fee_mpxn),
        seller_proceeds_mpxn: toNumber(row.seller_proceeds_mpxn),
        buyer_claimed_total: toNumber(row.buyer_claimed_total),
        seller_claimed_total: toNumber(row.seller_claimed_total),
        status: row.status,
      };
      break;
    case "make_offer":
      data = {
        offer_id: row.offer_id,
        listing_id: row.listing_id,
        buyer_user_id: row.buyer_user_id,
        offer_price_mpxn: toNumber(row.offer_price_mpxn),
        status: row.status,
        buyer_claimed_total: toNumber(row.buyer_claimed_total),
      };
      break;
    case "cancel_offer":
      data = {
        offer_id: row.offer_id,
        refund_amount_mpxn: toNumber(row.refund_amount_mpxn),
        buyer_claimed_total: toNumber(row.buyer_claimed_total),
        status: row.status,
      };
      break;
    case "accept_offer":
      data = {
        listing_id: row.listing_id,
        inventory_id: row.inventory_id,
        offer_id: row.offer_id,
        seller_user_id: row.seller_user_id,
        buyer_user_id: row.buyer_user_id,
        offer_price_mpxn: toNumber(row.offer_price_mpxn),
        marketplace_fee_mpxn: toNumber(row.marketplace_fee_mpxn),
        seller_proceeds_mpxn: toNumber(row.seller_proceeds_mpxn),
        seller_claimed_total: toNumber(row.seller_claimed_total),
        status: row.status,
      };
      break;
    case "reject_offer":
      data = {
        offer_id: row.offer_id,
        refund_amount_mpxn: toNumber(row.refund_amount_mpxn),
        buyer_claimed_total: toNumber(row.buyer_claimed_total),
        status: row.status,
      };
      break;
  }

  return jsonResponse({ success: true, data }, 200);
});
