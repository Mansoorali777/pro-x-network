// Pro-X Network — "swap-mpxn-to-pxn" Edge Function.
//
// POST /functions/v1/swap-mpxn-to-pxn
//
// Body: { "amount_mpxn": <number> }
//
// Server-authoritative: this file never reads user_id from the request
// body. The amount is the ONLY thing read from the caller; everything
// else (user identity, balance debit, conversion rate, token-launch
// gate, PXN credit) happens inside public.swap_mpxn_to_pxn(), which
// this file calls via the service-role client and passes only the
// authenticated user's id (from auth.getUser()) and the requested
// amount.
//
// Authentication: identical pattern to functions/withdrawals —
// per-request user-scoped client for auth.getUser(), service-role
// client only for the privileged RPC call.
//
// The swap_mpxn_to_pxn() RPC returns the new PXN balance as a numeric
// scalar directly (not a row/composite). amount_mpxn_swapped in the
// response is therefore the caller-supplied, already-validated amount.
//
// Response envelope:
//   success: { "success": true, "new_pxn_balance": <number>,
//              "amount_mpxn_swapped": <number> }
//   error:   { "success": false, "error": { "code", "message" } }

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

// Maps public.swap_mpxn_to_pxn()'s PXNxx SQLSTATEs to a clean
// application error. Never forwards a raw PostgreSQL error message.
function mapPgError(code: string | undefined, rawMessage: string): { status: number; error: AppError } {
  switch (code) {
    case "PXN80":
      return { status: 400, error: { code: "INVALID_USER", message: "Invalid user" } };
    case "PXN100":
      return { status: 400, error: { code: "TOKEN_NOT_LAUNCHED", message: "Token not launched yet" } };
    case "PXN101":
      return { status: 400, error: { code: "INVALID_AMOUNT", message: "Invalid amount" } };
    case "PXN102":
      return { status: 400, error: { code: "INSUFFICIENT_BALANCE", message: "Insufficient m.PXN balance" } };
    case "PXN89":
      console.error("[swap-mpxn-to-pxn] server misconfiguration:", rawMessage);
      return { status: 500, error: { code: "SERVER_MISCONFIGURATION", message: "Server misconfiguration" } };
    default:
      console.error("[swap-mpxn-to-pxn] unrecognized database error:", code, rawMessage);
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
    console.error("[swap-mpxn-to-pxn] server misconfigured:", err instanceof Error ? err.message : "unknown error");
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

  if (!isPositiveFiniteNumber(rec.amount_mpxn)) {
    return errorResponse(400, "VALIDATION_ERROR", "amount_mpxn must be a number greater than zero");
  }

  const admin = getSupabaseAdmin();
  const { data, error } = await admin.rpc("swap_mpxn_to_pxn", {
    p_user_id: userId,
    p_amount_mpxn: rec.amount_mpxn,
  });

  if (error) {
    const mapped = mapPgError((error as { code?: string }).code, error.message);
    return errorResponse(mapped.status, mapped.error.code, mapped.error.message);
  }

  // swap_mpxn_to_pxn() returns numeric (the new pxn_balance directly).
  return jsonResponse(
    {
      success: true,
      new_pxn_balance: Number(data),
      amount_mpxn_swapped: rec.amount_mpxn,
    },
    200,
  );
});