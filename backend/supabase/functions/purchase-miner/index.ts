// Pro-X Network — "purchase-miner" Edge Function.
//
// POST /functions/v1/purchase-miner
//
// Server-authoritative miner purchase. This is the write counterpart
// to get-mining-inventory: it is the ONLY place a new
// public.mining_inventory row may be created from a purchase, and it
// does so by delegating the entire read-catalog / verify-balance /
// deduct-m.PXN / insert-inventory sequence to a single atomic
// SECURITY DEFINER Postgres function, public.purchase_miner (see
// 0016_secure_miner_purchase.sql, 0017_fix_purchase_miner_created_at.sql,
// 0022_miner_catalog_purchase_source.sql, and
// 0028_purchase_miner_use_mpxn.sql). This function does NOT implement
// marketplace logic, does NOT touch mining accrual
// (accrue-mining/index.ts is untouched), and does NOT modify any
// existing file.
//
// Currency: as of 0028_purchase_miner_use_mpxn.sql, purchases are
// charged in m.PXN — public.mining_state.claimed_total — NOT in PXN
// (public.mining_state.pxn_balance, which is locked/Coming Soon
// until token launch and is never read or written by this flow).
//
// Request body: { "minerTier": <integer> }
//   - minerTier must be a JSON integer >= 1. Anything else (missing,
//     non-integer, non-finite, < 1, or of the wrong type) is rejected
//     with 400 before the database is touched.
//   - No other field in the request body is ever read. In
//     particular, there is no user_id field, and even if the caller
//     sends one it is ignored — the only source of identity is
//     auth.getUser() below. There is also no price/speed/name/icon
//     field accepted from the client; every one of those values is
//     looked up server-side from public.miner_catalog inside the
//     RPC.
//
// Authentication: identical pattern to functions/me,
// functions/accrue-mining, functions/claim-mining, and
// functions/get-mining-inventory — a per-request, caller-scoped
// supabase-js client (anon key + the caller's own
// `Authorization: Bearer <token>` access token) is used, and
// `auth.getUser()` is the sole source of the caller's identity.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — the ONLY user id ever used in this function.
//   - This is the normal Supabase JWT/session mechanism. There is no
//     custom JWT/JWKS/private-JWK system anywhere in this file, and
//     SUPABASE_JWT_SECRET is never read or referenced.
//   - The authenticated user's UUID is the ONLY value ever passed as
//     p_user_id to the RPC — never a value from the request body. A
//     malicious client cannot purchase against, or deduct m.PXN
//     from, another user's balance, because no userId field from the
//     body is ever consulted.
//
// Database access:
//   - getSupabaseAdmin() (service-role client) is used ONLY to call
//     the public.purchase_miner RPC. It is never used to read or
//     write miner_catalog, mining_state, or mining_inventory
//     directly from this file — every one of those reads/writes
//     happens inside the single atomic transaction of the
//     SECURITY DEFINER function itself, which is exactly what makes
//     the purchase atomic and safe under concurrent requests (see
//     the migration's comments for why).
//   - public.purchase_miner is GRANTed to service_role only (REVOKEd
//     from public/anon/authenticated), so only this Edge Function —
//     never a client calling the PostgREST RPC endpoint directly —
//     can invoke it.
//
// Response 200: { success: true, inventory: { id, miner_tier,
//                 miner_name, miner_icon, miner_level, miner_speed,
//                 is_applied, created_at, updated_at },
//                 claimed_total: <number> }
//   NOTE: the m.PXN balance is returned to the frontend under the
//   honest key "claimed_total", never as "pxn_balance" — even though
//   the underlying RPC's output column is still literally named
//   new_pxn_balance (a legacy name that 0028_purchase_miner_use_mpxn.sql
//   could not rename without a breaking DROP FUNCTION). Its value is
//   mining_state.claimed_total, not the separate, untouched
//   mining_state.pxn_balance — this file re-labels it before it ever
//   reaches the client.
// Response 400: { success: false, message: "..." }
//   (missing/invalid minerTier, or unknown miner tier, or
//   insufficient m.PXN balance)
// Response 401: { success: false, message: "Unauthorized" }
// Response 404: { success: false, message: "...", }
//   (no mining_state row for this player yet — call accrue-mining or
//   the player's normal init flow first)
// Response 405: method not allowed
// Response 500: server misconfiguration or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret. Never exposes a raw database error message to the client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;

// Custom SQLSTATEs raised by public.purchase_miner (see
// 0016_secure_miner_purchase.sql / 0022_miner_catalog_purchase_source.sql /
// 0028_purchase_miner_use_mpxn.sql — meanings unchanged by 0028).
// Mapped below to the HTTP status that best reflects each failure
// mode.
const PG_ERR_INVALID_INPUT = "PXN04";
const PG_ERR_UNKNOWN_TIER = "PXN01";
const PG_ERR_INSUFFICIENT_BALANCE = "PXN02";
const PG_ERR_NO_MINING_STATE = "PXN03";
const PG_ERR_NO_ACTIVE_CONFIG = "PXN05";

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

/**
 * Strict validation for minerTier: must be present, a JSON number,
 * a safe integer, and >= 1. Rejects strings, floats, NaN, Infinity,
 * booleans, null, and missing values — never coerces.
 */
function parseMinerTier(body: unknown): number | null {
  if (typeof body !== "object" || body === null) return null;
  const raw = (body as Record<string, unknown>).minerTier;
  if (typeof raw !== "number") return null;
  if (!Number.isInteger(raw)) return null;
  if (!Number.isSafeInteger(raw)) return null;
  if (raw < 1) return null;
  return raw;
}

interface PurchaseMinerRow {
  inventory_id: string;
  miner_tier: number;
  miner_name: string;
  miner_icon: string | null;
  miner_level: number;
  miner_speed: number;
  is_applied: boolean;
  created_at: string;
  updated_at: string;
  // NOTE: this column name is a legacy holdover from when purchases
  // deducted PXN (see 0016/0017/0022). As of
  // 0028_purchase_miner_use_mpxn.sql, the RPC's RETURNS TABLE
  // signature is left unchanged (CREATE OR REPLACE FUNCTION cannot
  // safely change an existing function's output columns), so the
  // column is still literally named new_pxn_balance — but the value
  // it now carries is the player's new claimed_total (m.PXN), NOT
  // pxn_balance, which this RPC never reads or writes. Do not read
  // this as an actual PXN balance.
  new_pxn_balance: number;
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ success: false, message: "Method not allowed" }, 405);
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return jsonResponse(UNAUTHORIZED, 401);
  }

  // --- Parse and strictly validate the request body BEFORE touching auth or the database. ---
  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return jsonResponse({ success: false, message: "Request body must be valid JSON" }, 400);
  }

  const minerTier = parseMinerTier(rawBody);
  if (minerTier === null) {
    return jsonResponse(
      { success: false, message: "minerTier must be an integer >= 1" },
      400,
    );
  }

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[purchase-miner] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the identity
  // check below, exactly like functions/me, functions/accrue-mining,
  // and functions/claim-mining. Never used for any database read or
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
    return jsonResponse(UNAUTHORIZED, 401);
  }
  const userId = authData.user.id;

  // Service-role client — the only client that may call
  // public.purchase_miner (GRANTed to service_role only). Every
  // catalog lookup, balance check, deduction, and inventory insert
  // happens inside that single atomic RPC call, not in this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[purchase-miner] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  const { data: rpcData, error: rpcError } = await admin
    .rpc("purchase_miner", {
      p_user_id: userId,
      p_miner_tier: minerTier,
    })
    .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_INVALID_INPUT:
        return jsonResponse({ success: false, message: "Invalid miner tier" }, 400);
      case PG_ERR_UNKNOWN_TIER:
        return jsonResponse({ success: false, message: "Unknown miner tier" }, 404);
      case PG_ERR_INSUFFICIENT_BALANCE:
        return jsonResponse({ success: false, message: "Insufficient m.PXN balance" }, 400);
      case PG_ERR_NO_MINING_STATE:
        return jsonResponse(
          { success: false, message: "Mining state not initialized for this player" },
          404,
        );
      case PG_ERR_NO_ACTIVE_CONFIG:
        console.error("[purchase-miner] no active mining_config row");
        return jsonResponse({ success: false, message: "Mining configuration unavailable" }, 500);
      default:
        console.error("[purchase-miner] purchase_miner RPC failed:", rpcError.message);
        return jsonResponse({ success: false, message: "Could not complete purchase" }, 500);
    }
  }

  const row = rpcData as PurchaseMinerRow | null;
  if (!row) {
    console.error("[purchase-miner] purchase_miner RPC returned no row");
    return jsonResponse({ success: false, message: "Could not complete purchase" }, 500);
  }

  return jsonResponse(
    {
      success: true,
      inventory: {
        id: row.inventory_id,
        miner_tier: row.miner_tier,
        miner_name: row.miner_name,
        miner_icon: row.miner_icon,
        miner_level: row.miner_level,
        miner_speed: row.miner_speed,
        is_applied: row.is_applied,
        created_at: row.created_at,
        updated_at: row.updated_at,
      },
      // row.new_pxn_balance is the RPC's legacy output column name
      // (see the PurchaseMinerRow comment above) — its value is the
      // player's new claimed_total (m.PXN), not pxn_balance. It is
      // deliberately surfaced to the frontend under the honest key
      // "claimed_total", never as "pxn_balance".
      claimed_total: row.new_pxn_balance,
    },
    200,
  );
});
