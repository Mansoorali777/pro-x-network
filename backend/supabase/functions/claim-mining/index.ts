// Pro-X Network — "claim-mining" Edge Function.
//
// POST /functions/v1/claim-mining
//
// Server-authoritative Claim m.PXN. This is the write counterpart to
// accrue-mining: it moves a player's already-accrued pending_claim
// into claimed_total by delegating the entire lock / verify /
// nothing-to-claim-check / update sequence to a single SECURITY
// DEFINER Postgres function, public.claim_mining (see
// 0027_secure_mpxn_claim.sql). This function does NOT implement any
// of that logic itself, does NOT touch mining accrual
// (accrue-mining/index.ts is untouched), miner purchase, miner
// upgrade, or any admin function, and does NOT modify any existing
// file.
//
// m.PXN vs PXN: this endpoint claims m.PXN (the in-game mining
// currency: mined_balance_total / pending_claim / claimed_total). It
// never reads, writes, or converts anything into pxn_balance (the
// separate, future blockchain token) — that column is untouched by
// both this file and the RPC it calls.
//
// Request body: none required. The claim always applies to the
// caller's own row — there is no field in the request body that
// identifies which player or which amount to claim.
//
// Authentication: identical pattern to functions/me,
// functions/accrue-mining, and functions/set-miner-applied — a
// per-request, caller-scoped supabase-js client (anon key + the
// caller's own `Authorization: Bearer <token>` access token) is
// used, and `auth.getUser()` is the sole source of the caller's
// identity.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — the ONLY user id ever used in this function, and the value
//     passed as p_user_id to the RPC. It is NEVER read from the
//     request body — a malicious client cannot claim another user's
//     m.PXN by supplying a different userId, because no such field
//     is ever consulted.
//   - This is the normal Supabase JWT/session mechanism. There is no
//     custom JWT/JWKS/private-JWK system anywhere in this file, and
//     SUPABASE_JWT_SECRET / PXN_JWT_SECRET are never read or
//     referenced.
//
// Database access:
//   - getSupabaseAdmin() (service-role client) is used ONLY to call
//     the public.claim_mining RPC. It is never used to read or write
//     mining_state directly from this file — the row lock, the
//     nothing-to-claim check, and the update all happen inside the
//     RPC itself.
//   - public.claim_mining is GRANTed to service_role only (REVOKEd
//     from public/anon/authenticated), so only this Edge Function —
//     never a client calling the PostgREST RPC endpoint directly —
//     can invoke it.
//
// Concurrency: public.claim_mining locks the caller's mining_state
// row (SELECT ... FOR UPDATE) before reading pending_claim, so two
// simultaneous claim requests for the same player cannot both claim
// the same pending amount — the second call serializes behind the
// first and then observes pending_claim = 0 (already claimed by the
// first call) and is rejected with 409.
//
// Response 200: { success: true, user_id, claimed_amount,
//                 pending_claim, claimed_total, claim_count }
// Response 401: { success: false, message: "Unauthorized" }
// Response 405: method not allowed
// Response 409: { success: false, message: "..." }
//   (no mining_state row yet, or pending_claim is 0 — nothing to claim)
// Response 500: server misconfiguration or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret. Never exposes a raw database error message to the client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;

// Custom SQLSTATEs raised by public.claim_mining (see
// 0027_secure_mpxn_claim.sql). Mapped below to the HTTP status that
// best reflects each failure mode.
const PG_ERR_INVALID_INPUT = "PXN22";
const PG_ERR_NOTHING_TO_CLAIM = "PXN23";

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

interface ClaimMiningRow {
  user_id: string;
  claimed_amount: number | string;
  pending_claim: number | string;
  claimed_total: number | string;
  claim_count: number;
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

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[claim-mining] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the identity
  // check below, exactly like functions/me, functions/accrue-mining,
  // and functions/set-miner-applied. Never used for any database
  // read or write in this function.
  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  // --- Validate the token via the normal Supabase Auth mechanism. ---
  // getUser() asks Supabase's Auth server to verify the token; we
  // never decode or trust the JWT's claims ourselves, and the
  // resulting user id is the ONLY identity used anywhere below —
  // never a value from the request body (this endpoint doesn't even
  // read a request body).
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }
  const userId = authData.user.id;

  // Service-role client — the only client that may call
  // public.claim_mining (GRANTed to service_role only). Every row
  // lock, nothing-to-claim check, and balance update happens inside
  // that single RPC call, not in this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[claim-mining] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  const { data: rpcData, error: rpcError } = await admin
    .rpc("claim_mining", { p_user_id: userId })
    .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_INVALID_INPUT:
        return jsonResponse({ success: false, message: "Invalid request" }, 400);
      case PG_ERR_NOTHING_TO_CLAIM:
        return jsonResponse(
          { success: false, message: "Nothing available to claim" },
          409,
        );
      default:
        // Never expose the raw database error message to the client.
        console.error("[claim-mining] claim_mining RPC failed:", rpcError.message);
        return jsonResponse({ success: false, message: "Could not process claim" }, 500);
    }
  }

  const row = rpcData as ClaimMiningRow | null;
  if (!row) {
    console.error("[claim-mining] claim_mining RPC returned no row");
    return jsonResponse({ success: false, message: "Could not process claim" }, 500);
  }

  return jsonResponse(
    {
      success: true,
      user_id: row.user_id,
      claimed_amount: Number(row.claimed_amount),
      pending_claim: Number(row.pending_claim),
      claimed_total: Number(row.claimed_total),
      claim_count: row.claim_count,
    },
    200,
  );
});
