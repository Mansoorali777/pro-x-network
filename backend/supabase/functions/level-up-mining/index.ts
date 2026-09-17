// Pro-X Network — "level-up-mining" Edge Function.
//
// POST /functions/v1/level-up-mining
//
// Server-authoritative Mining Level Up. This is the write path that
// raises a player's mining_state.level by delegating the entire lock
// / level-cap check / cost lookup / atomic-deduct / increment /
// idempotency sequence to a single atomic SECURITY DEFINER Postgres
// function, public.level_up_mining (see 0031_level_up_mining.sql,
// which itself calls public.adjust_claimed_total from
// 0030_mpxn_ledger_primitive.sql). This function does NOT implement
// any of that logic itself, does NOT touch mining accrual
// (accrue-mining/index.ts is untouched), claim (claim-mining/index.ts
// is untouched), miner purchase (purchase-miner/index.ts is
// untouched), miner upgrade (upgrade-miner/index.ts is untouched),
// apply/remove (set-miner-applied/index.ts is untouched), and does
// NOT modify any existing file.
//
// Currency: level_up_mining() deducts m.PXN
// (public.mining_state.claimed_total) — see 0031_level_up_mining.sql.
// This file never reads, writes, or references pxn_balance in any
// way, and never touches mining_state directly; every read/lock/
// write of mining_state happens inside the RPC.
//
// Request body: a single, OPTIONAL JSON object:
//   { "requestId": <uuid string> }
//   - requestId is the client-generated idempotency key for this
//     level-up attempt (see 0031_level_up_mining.sql's header for why
//     it exists — a dropped response after a server-side commit can
//     be safely retried with the same requestId without double-
//     charging or double-leveling).
//   - If the field is present, it must be a JSON string that is a
//     syntactically valid UUID — anything else (wrong type, malformed
//     UUID) is rejected with 400 before the database is touched.
//   - If the field is absent (or the body itself is absent/empty),
//     this function generates a UUID server-side with
//     crypto.randomUUID() and uses that instead — a client is never
//     required to supply one for the request to succeed exactly once.
//   - No other field in the request body is ever read. In
//     particular, there is no userId field, and even if the caller
//     sends one it is ignored — the only source of identity is
//     auth.getUser() below. There is also no level/cost field
//     accepted from the client; both are computed entirely
//     server-side inside the RPC from mining_config and the caller's
//     locked mining_state row.
//
// Authentication: identical pattern to functions/me,
// functions/claim-mining, functions/purchase-miner, and
// functions/upgrade-miner — a per-request, caller-scoped supabase-js
// client (anon key + the caller's own `Authorization: Bearer <token>`
// access token) is used, and `auth.getUser()` is the sole source of
// the caller's identity.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — the ONLY user id ever used in this function, and the value
//     passed as p_user_id to the RPC. It is NEVER read from the
//     request body — a malicious client cannot level up another
//     user's mining_state by supplying a different userId, because no
//     such field is ever consulted.
//   - This is the normal Supabase JWT/session mechanism. There is no
//     custom JWT/JWKS/private-JWK system anywhere in this file, and
//     SUPABASE_JWT_SECRET / PXN_JWT_SECRET are never read or
//     referenced.
//
// Database access:
//   - getSupabaseAdmin() (service-role client) is used ONLY to call
//     the public.level_up_mining RPC. It is never used to read or
//     write mining_state, mining_config, or mpxn_ledger directly from
//     this file — every one of those reads/locks/writes happens
//     inside the single atomic transaction of the SECURITY DEFINER
//     function itself.
//   - public.level_up_mining is GRANTed to service_role only
//     (REVOKEd from public/anon/authenticated), so only this Edge
//     Function — never a client calling the PostgREST RPC endpoint
//     directly — can invoke it.
//
// Concurrency & idempotency: public.level_up_mining locks the
// caller's mining_state row (SELECT ... FOR UPDATE) before reading
// level/claimed_total, and treats a repeated requestId as a no-op
// replay of an already-committed result rather than a new charge —
// see 0031_level_up_mining.sql for the full guarantee. This file does
// not add any locking or deduplication logic of its own; it only
// passes requestId through.
//
// Response 200: { success: true, new_level: <int>, mpxn_cost:
//                 <number>, claimed_total: <number>,
//                 request_id: <uuid string> }
//   (request_id is echoed back — either the caller's own value, or
//   the one generated server-side when none was supplied — so a
//   client that didn't send one can still retry safely using the
//   value from this response.)
// Response 400: { success: false, message: "..." }
//   (missing/invalid requestId, insufficient m.PXN, or already at
//   the maximum level)
// Response 401: { success: false, message: "Unauthorized" }
// Response 404: { success: false, message: "..." }
//   (no mining_state row for this player yet)
// Response 405: method not allowed
// Response 409: { success: false, message: "..." }
//   (this requestId was already processed — see PG_ERR_DUPLICATE
//   below; included for completeness, though level_up_mining's own
//   idempotency fast path normally returns 200 for this case instead)
// Response 500: server misconfiguration, no active mining_config row,
//   or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret. Database errors are never forwarded verbatim to the
// client — only a small set of recognized error codes are mapped to
// specific messages; everything else becomes a generic 500.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;

// Custom SQLSTATEs raised by public.level_up_mining /
// public.adjust_claimed_total (see 0030_mpxn_ledger_primitive.sql,
// 0031_level_up_mining.sql). Mapped below to the HTTP status that
// best reflects each failure mode. Continues the existing PXN
// error-code sequence (PXN01-PXN23: earlier functions; PXN24-PXN26:
// adjust_claimed_total; PXN27-PXN28: level_up_mining).
const PG_ERR_INSUFFICIENT_BALANCE = "PXN24";
const PG_ERR_NO_MINING_STATE = "PXN25";
const PG_ERR_DUPLICATE = "PXN26";
const PG_ERR_NO_ACTIVE_CONFIG = "PXN27";
const PG_ERR_MAX_LEVEL = "PXN28";

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
 * Strict validation for the optional requestId body field: if
 * present, must be a JSON string that is a syntactically valid UUID.
 * Never coerces. Returns:
 *   - { ok: true, value: <string | null> } — value is the validated
 *     requestId, or null if the field was simply absent (caller
 *     should then generate one).
 *   - { ok: false } — the field was present but malformed; caller
 *     should reject the request with 400.
 * This is the ONLY field ever read from the request body — there is
 * no userId, level, or cost field this function accepts.
 */
function parseOptionalRequestId(body: unknown): { ok: true; value: string | null } | { ok: false } {
  if (body === null || typeof body !== "object") {
    // No body, or a non-object body (e.g. the client sent nothing,
    // or sent `{}`-equivalent via an empty request) — treat as "no
    // requestId supplied".
    return { ok: true, value: null };
  }
  const raw = (body as Record<string, unknown>).requestId;
  if (raw === undefined || raw === null) {
    return { ok: true, value: null };
  }
  if (typeof raw !== "string" || !UUID_RE.test(raw)) {
    return { ok: false };
  }
  return { ok: true, value: raw };
}

interface LevelUpMiningRow {
  new_level: number;
  mpxn_cost: number | string;
  claimed_total: number | string;
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

  // --- Parse (optional) request body. A missing/empty body is valid
  // — it just means "generate a requestId for me". A malformed
  // requestId, if one was supplied, is rejected before the database
  // is touched. ---
  let parsedBody: unknown = null;
  const rawBody = await req.text();
  if (rawBody.trim().length > 0) {
    try {
      parsedBody = JSON.parse(rawBody);
    } catch {
      return jsonResponse({ success: false, message: "Invalid request body" }, 400);
    }
  }

  const requestIdResult = parseOptionalRequestId(parsedBody);
  if (!requestIdResult.ok) {
    return jsonResponse({ success: false, message: "Invalid requestId" }, 400);
  }
  // Server-generated fallback: a client is never required to supply
  // its own requestId for the call to succeed exactly once — see the
  // header comment above and 0031_level_up_mining.sql's idempotency
  // design.
  const requestId = requestIdResult.value ?? crypto.randomUUID();

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[level-up-mining] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the identity
  // check below, exactly like functions/me, functions/claim-mining,
  // functions/purchase-miner, and functions/upgrade-miner. Never used
  // for any database read or write in this function.
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
  // public.level_up_mining (GRANTed to service_role only). Every row
  // lock, cap check, cost lookup, deduction, and level increment
  // happens inside that single RPC call, not in this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[level-up-mining] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  const { data: rpcData, error: rpcError } = await admin
    .rpc("level_up_mining", { p_user_id: userId, p_request_id: requestId })
    .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_INSUFFICIENT_BALANCE:
        return jsonResponse(
          { success: false, message: "Not enough m.PXN to level up" },
          400,
        );
      case PG_ERR_MAX_LEVEL:
        return jsonResponse(
          { success: false, message: "Already at the maximum level" },
          400,
        );
      case PG_ERR_NO_MINING_STATE:
        return jsonResponse(
          { success: false, message: "No mining data found for this player" },
          404,
        );
      case PG_ERR_DUPLICATE:
        // level_up_mining's own idempotency fast path normally
        // absorbs a retried requestId and returns 200 instead of
        // reaching this branch — this is the race-condition backstop
        // (see 0031_level_up_mining.sql step 2's comment) surfacing
        // as an error rather than a replayed success.
        return jsonResponse(
          { success: false, message: "This level-up request was already processed" },
          409,
        );
      case PG_ERR_NO_ACTIVE_CONFIG:
        console.error("[level-up-mining] no active mining_config row");
        return jsonResponse(
          { success: false, message: "Could not process level up" },
          500,
        );
      default:
        // Never expose the raw database error message to the client.
        console.error("[level-up-mining] level_up_mining RPC failed:", rpcError.message);
        return jsonResponse({ success: false, message: "Could not process level up" }, 500);
    }
  }

  const row = rpcData as LevelUpMiningRow | null;
  if (!row) {
    console.error("[level-up-mining] level_up_mining RPC returned no row");
    return jsonResponse({ success: false, message: "Could not process level up" }, 500);
  }

  return jsonResponse(
    {
      success: true,
      new_level: row.new_level,
      mpxn_cost: Number(row.mpxn_cost),
      claimed_total: Number(row.claimed_total),
      request_id: requestId,
    },
    200,
  );
});
