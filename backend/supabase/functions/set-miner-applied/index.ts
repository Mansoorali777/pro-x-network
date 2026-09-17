// Pro-X Network — "set-miner-applied" Edge Function.
//
// POST /functions/v1/set-miner-applied
//
// Server-authoritative apply/remove of an owned miner unit. This is
// the write counterpart to get-mining-inventory: it is the ONLY
// place a mining_inventory row's is_applied flag may be flipped, and
// it does so by delegating the entire ownership-check /
// already-applied-or-removed-check / slot-limit-check / update
// sequence to a single SECURITY DEFINER Postgres function,
// public.set_miner_applied (see 0018_secure_miner_apply_remove.sql).
// This function does NOT implement any of that logic itself, does
// NOT touch mining accrual (accrue-mining/index.ts is untouched),
// and does NOT modify any existing file.
//
// Request body: { "inventoryId": <uuid>, "isApplied": <boolean> }
//   - inventoryId must be a JSON string that is a valid UUID.
//   - isApplied must be a JSON boolean (true or false).
//   - Anything else (missing, wrong type, malformed UUID) is
//     rejected with 400 before the database is touched.
//   - No other field in the request body is ever read. In
//     particular, there is no user_id/userId field, and even if the
//     caller sends one it is ignored — the only source of identity
//     is auth.getUser() below.
//
// Authentication: identical pattern to functions/me,
// functions/purchase-miner, functions/accrue-mining, and
// functions/get-mining-inventory — a per-request, caller-scoped
// supabase-js client (anon key + the caller's own
// `Authorization: Bearer <token>` access token) is used, and
// `auth.getUser()` is the sole source of the caller's identity.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — the ONLY user id ever used in this function, and the value
//     passed as p_user_id to the RPC. It is never read from the
//     request body.
//   - This is the normal Supabase JWT/session mechanism. There is no
//     custom JWT/JWKS/private-JWK system anywhere in this file, and
//     SUPABASE_JWT_SECRET / PXN_JWT_SECRET are never read or
//     referenced.
//
// Database access:
//   - getSupabaseAdmin() (service-role client) is used ONLY to call
//     the public.set_miner_applied RPC. It is never used to read or
//     write mining_inventory or mining_state directly from this
//     file — every one of those reads/locks/writes happens inside
//     the RPC itself.
//   - public.set_miner_applied is GRANTed to service_role only
//     (REVOKEd from public/anon/authenticated), so only this Edge
//     Function — never a client calling the PostgREST RPC endpoint
//     directly — can invoke it.
//
// Response 200: { success: true, inventory: { id, user_id,
//                 miner_tier, miner_name, miner_icon, miner_level,
//                 miner_speed, is_applied, created_at, updated_at } }
// Response 400: { success: false, message: "..." }
//   (missing/invalid inventoryId or isApplied, or applied slots full)
// Response 401: { success: false, message: "Unauthorized" }
// Response 404: { success: false, message: "..." }
//   (no mining_state row for this player yet, or the inventory item
//   does not exist / does not belong to this player)
// Response 405: method not allowed
// Response 409: { success: false, message: "..." }
//   (miner already applied, or already removed)
// Response 500: server misconfiguration or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;

// Custom SQLSTATEs raised by public.set_miner_applied (see
// 0018_secure_miner_apply_remove.sql). Mapped below to the HTTP
// status that best reflects each failure mode.
const PG_ERR_INVALID_INPUT = "PXN06";
const PG_ERR_NO_MINING_STATE = "PXN07";
const PG_ERR_INVENTORY_NOT_FOUND = "PXN08";
const PG_ERR_ALREADY_APPLIED = "PXN09";
const PG_ERR_ALREADY_REMOVED = "PXN10";
const PG_ERR_SLOTS_FULL = "PXN11";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

/**
 * Strict validation for inventoryId: must be present, a JSON
 * string, and a syntactically valid UUID. Never coerces.
 */
function parseInventoryId(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const raw = (body as Record<string, unknown>).inventoryId;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!UUID_RE.test(trimmed)) return null;
  return trimmed;
}

/**
 * Strict validation for isApplied: must be present and a JSON
 * boolean. Rejects strings ("true"), numbers (1/0), null, and
 * missing values — never coerces.
 */
function parseIsApplied(body: unknown): boolean | null {
  if (typeof body !== "object" || body === null) return null;
  const raw = (body as Record<string, unknown>).isApplied;
  if (typeof raw !== "boolean") return null;
  return raw;
}

interface SetMinerAppliedRow {
  id: string;
  user_id: string;
  miner_tier: number;
  miner_name: string;
  miner_icon: string | null;
  miner_level: number;
  miner_speed: number;
  is_applied: boolean;
  created_at: string;
  updated_at: string;
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

  const inventoryId = parseInventoryId(rawBody);
  if (inventoryId === null) {
    return jsonResponse(
      { success: false, message: "inventoryId must be a valid UUID" },
      400,
    );
  }

  const isApplied = parseIsApplied(rawBody);
  if (isApplied === null) {
    return jsonResponse(
      { success: false, message: "isApplied must be a boolean" },
      400,
    );
  }

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[set-miner-applied] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the identity
  // check below, exactly like functions/me, functions/purchase-miner,
  // and functions/accrue-mining. Never used for any database read or
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
  // public.set_miner_applied (GRANTed to service_role only). Every
  // ownership check, state check, slot-limit check, and update
  // happens inside that single RPC call, not in this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[set-miner-applied] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  const { data: rpcData, error: rpcError } = await admin
    .rpc("set_miner_applied", {
      p_user_id: userId,
      p_inventory_id: inventoryId,
      p_is_applied: isApplied,
    })
    .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_INVALID_INPUT:
        return jsonResponse({ success: false, message: "Invalid request" }, 400);
      case PG_ERR_NO_MINING_STATE:
        return jsonResponse(
          { success: false, message: "Mining state not initialized for this player" },
          404,
        );
      case PG_ERR_INVENTORY_NOT_FOUND:
        return jsonResponse({ success: false, message: "Miner not found" }, 404);
      case PG_ERR_ALREADY_APPLIED:
        return jsonResponse({ success: false, message: "Miner is already applied" }, 409);
      case PG_ERR_ALREADY_REMOVED:
        return jsonResponse({ success: false, message: "Miner is already removed" }, 409);
      case PG_ERR_SLOTS_FULL:
        return jsonResponse({ success: false, message: "No applied miner slots available" }, 400);
      default:
        console.error("[set-miner-applied] set_miner_applied RPC failed:", rpcError.message);
        return jsonResponse({ success: false, message: "Could not update miner" }, 500);
    }
  }

  const row = rpcData as SetMinerAppliedRow | null;
  if (!row) {
    console.error("[set-miner-applied] set_miner_applied RPC returned no row");
    return jsonResponse({ success: false, message: "Could not update miner" }, 500);
  }

  return jsonResponse(
    {
      success: true,
      inventory: {
        id: row.id,
        user_id: row.user_id,
        miner_tier: row.miner_tier,
        miner_name: row.miner_name,
        miner_icon: row.miner_icon,
        miner_level: row.miner_level,
        miner_speed: row.miner_speed,
        is_applied: row.is_applied,
        created_at: row.created_at,
        updated_at: row.updated_at,
      },
    },
    200,
  );
});
