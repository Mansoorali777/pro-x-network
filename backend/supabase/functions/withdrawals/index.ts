// Pro-X Network — "withdrawals" Edge Function.
//
// POST /functions/v1/withdrawals
//
// Three actions:
//   Create a request: { "action": "create", "amount_mpxn": <number> }
//   List own history:  { "action": "list" }                (default if omitted)
//   Read safe config:  { "action": "config" }              (token_launched, rate, etc.)
//
// Server-authoritative: this file never reads user_id, status,
// wallet_address, or amount_pxn from the request body. The amount is
// the ONLY thing "create" reads from the caller; everything else
// (wallet address, conversion, balance debit, duplicate-request check)
// happens inside public.create_withdrawal_request()
// (0052_player_wallet_and_withdrawals.sql), which this file calls via
// the service-role client and passes only the authenticated user's id
// (from auth.getUser()) and the requested amount.
//
// "list" reads the caller's own rows directly through the user-scoped
// client, relying entirely on the existing withdrawals_select_own RLS
// policy — never the service-role client — so a caller can only ever
// see their own withdrawal history, enforced by Postgres itself.
//
// Authentication: identical pattern to functions/marketplace,
// functions/player-profile — per-request user-scoped client for
// auth.getUser(), service-role client only for the privileged RPC call.
//
// Response envelope:
//   create success: { "success": true, "withdrawal": {...} }
//   list success:   { "success": true, "withdrawals": [...] }
//   error:          { "success": false, "error": { "code", "message" } }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

interface AppError {
  code: string;
  message: string;
}

function errorResponse(status: number, code: string, message: string): Response {
  return jsonResponse({ success: false, error: { code, message } as AppError }, status);
}

const UNAUTHORIZED = () => errorResponse(401, "UNAUTHORIZED", "Unauthorized");

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

function isPositiveFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

// Maps public.create_withdrawal_request()'s PXNxx SQLSTATEs (see
// 0052_player_wallet_and_withdrawals.sql section 6), plus the
// pre-existing adjust_claimed_total codes (PXN24/25/26) it can also
// surface, to a clean application error. Never forwards a raw
// PostgreSQL error message.
function mapPgError(code: string | undefined, rawMessage: string): { status: number; error: AppError } {
  switch (code) {
    case "PXN24":
      return { status: 400, error: { code: "INSUFFICIENT_BALANCE", message: "Insufficient m.PXN balance" } };
    case "PXN25":
      return { status: 404, error: { code: "NO_MINING_STATE", message: "Mining data is not initialized for this account" } };
    case "PXN26":
      return { status: 409, error: { code: "DUPLICATE_REQUEST", message: "This request was already processed" } };
    case "PXN83":
      return { status: 400, error: { code: "VALIDATION_ERROR", message: "amount_mpxn must be a positive number" } };
    case "PXN84":
      return { status: 400, error: { code: "WALLET_REQUIRED", message: "Connect a wallet before requesting a withdrawal" } };
    case "PXN85":
      return { status: 403, error: { code: "WITHDRAWAL_PAUSED", message: "Withdrawals are currently paused" } };
    case "PXN86":
      return { status: 400, error: { code: "BELOW_MINIMUM", message: "Amount is below the minimum withdrawal" } };
    case "PXN87":
      return { status: 409, error: { code: "DUPLICATE_WITHDRAWAL", message: "You already have a pending withdrawal request" } };
    case "PXN89":
      console.error("[withdrawals] withdrawal_config misconfigured:", rawMessage);
      return { status: 500, error: { code: "INVALID_CONVERSION", message: "Withdrawals are temporarily unavailable" } };
    default:
      console.error("[withdrawals] unrecognized database error:", code, rawMessage);
      return { status: 500, error: { code: "INTERNAL_ERROR", message: "Something went wrong. Please try again." } };
  }
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse(405, "METHOD_NOT_ALLOWED", "Method not allowed");
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) return UNAUTHORIZED();

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error("[withdrawals] server misconfigured:", err instanceof Error ? err.message : "unknown error");
    return errorResponse(500, "INTERNAL_ERROR", "Service temporarily unavailable");
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) return UNAUTHORIZED();
  const userId = authData.user.id;

  let body: unknown = {};
  try {
    const text = await req.text();
    if (text) body = JSON.parse(text);
  } catch {
    return errorResponse(400, "VALIDATION_ERROR", "Request body must be valid JSON");
  }
  const rec = (typeof body === "object" && body !== null ? body : {}) as Record<string, unknown>;
  const action = typeof rec.action === "string" ? rec.action : "list";

  if (action === "list") {
    // withdrawals_select_own RLS is the actual security boundary here;
    // the .eq() below is belt-and-suspenders, not the enforcement.
    const { data, error } = await userClient
      .from("withdrawals")
      .select(
        "id, wallet_address, wallet_network, amount_mpxn, amount_pxn, status, rejection_reason, tx_hash, created_at, updated_at",
      )
      .eq("user_id", userId)
      .order("created_at", { ascending: false });

    if (error) {
      console.error("[withdrawals] list failed:", error.message);
      return errorResponse(500, "INTERNAL_ERROR", "Could not load withdrawal history");
    }
    return jsonResponse({ success: true, withdrawals: data ?? [] }, 200);
  }
  if (action === "config") {
    // Public read of the safe subset of withdrawal_config (no secrets).
    // Goes through the get_withdrawal_config_public() RPC (SECURITY DEFINER),
    // because withdrawal_config itself has no client-readable RLS policy.
    const { data, error } = await userClient.rpc("get_withdrawal_config_public");

    if (error) {
      console.error("[withdrawals] config failed:", error.message);
      return errorResponse(500, "INTERNAL_ERROR", "Could not load withdrawal config");
    }

    // RPC returns a table — unwrap the first row.
    const row = Array.isArray(data) ? data[0] : data;
    return jsonResponse({ success: true, config: row ?? null }, 200);
  }

  if (action === "create") {
    if (!isPositiveFiniteNumber(rec.amount_mpxn)) {
      return errorResponse(400, "VALIDATION_ERROR", "amount_mpxn must be a number greater than zero");
    }

    const admin = getSupabaseAdmin();
    const { data, error } = await admin.rpc("create_withdrawal_request", {
      p_user_id: userId,
      p_amount_mpxn: rec.amount_mpxn,
    });

    if (error) {
      const mapped = mapPgError((error as { code?: string }).code, error.message);
      return errorResponse(mapped.status, mapped.error.code, mapped.error.message);
    }

    return jsonResponse({ success: true, withdrawal: data }, 200);
  }

  return errorResponse(400, "VALIDATION_ERROR", "action must be one of: create, list, config");
});
