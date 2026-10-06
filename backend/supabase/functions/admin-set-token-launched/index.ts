// Pro-X Network — "admin-set-token-launched" Edge Function.
//
// POST /functions/v1/admin-set-token-launched
//
// Body: { "launched": <boolean> }
//
// Admin-only: flips the global token-launched flag used by
// public.swap_mpxn_to_pxn() to gate whether m.PXN -> PXN swaps are
// enabled (PXN100 "Token not launched yet").
//
// Authentication & authorization — identical pattern to
// functions/admin-withdrawals:
//   - Request body parsed/validated FIRST, before any auth or database
//     call.
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     caller's own Authorization bearer token) is used for TWO things
//     only: auth.getUser() (identity) and the EXISTING
//     public.is_current_user_admin() RPC (authorization). If either
//     fails: 401/403.
//   - Only after both checks pass does this file use the service-role
//     client, and only to call admin_set_token_launched — which ALSO
//     independently re-verifies admin_users membership server-side
//     (defense in depth: this file's own check is not the only gate).
//
// This file does NOT implement any state mutation logic itself — that
// lives inside the SECURITY DEFINER RPC it calls. It does NOT touch
// mining_state, player_wallets, or any config table directly.
//
// The admin_set_token_launched() RPC returns a boolean scalar directly.
//
// Response envelope:
//   success: { "success": true, "token_launched": <boolean> }
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
const FORBIDDEN = () => errorResponse(403, "FORBIDDEN", "Forbidden");

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

// Maps admin_set_token_launched()'s PXNxx SQLSTATEs to a clean
// application error. Never forwards a raw PostgreSQL error message.
function mapPgError(code: string | undefined, rawMessage: string): { status: number; error: AppError } {
  switch (code) {
    case "PXN61":
      return { status: 403, error: { code: "FORBIDDEN", message: "Forbidden" } };
    default:
      console.error("[admin-set-token-launched] unrecognized database error:", code, rawMessage);
      return { status: 500, error: { code: "INTERNAL_ERROR", message: "Something went wrong. Please try again." } };
  }
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse(405, "METHOD_NOT_ALLOWED", "Method not allowed");
  }

  let body: unknown = {};
  try {
    const text = await req.text();
    if (text) body = JSON.parse(text);
  } catch {
    return errorResponse(400, "VALIDATION_ERROR", "Request body must be valid JSON");
  }
  const rec = (typeof body === "object" && body !== null ? body : {}) as Record<string, unknown>;

  if (typeof rec.launched !== "boolean") {
    return errorResponse(400, "VALIDATION_ERROR", "launched must be a boolean");
  }
  const launched = rec.launched;

  const accessToken = extractBearerToken(req);
  if (!accessToken) return UNAUTHORIZED();

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error("[admin-set-token-launched] server misconfigured:", err instanceof Error ? err.message : "unknown error");
    return errorResponse(500, "INTERNAL_ERROR", "Service temporarily unavailable");
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) return UNAUTHORIZED();
  const callerId = authData.user.id;

  // Existing admin authorization mechanism, reused as-is — called AS the
  // caller so it evaluates auth.uid() = caller.
  const { data: isAdmin, error: adminCheckError } = await userClient.rpc(
    "is_current_user_admin",
  );
  if (adminCheckError || isAdmin !== true) return FORBIDDEN();

  const admin = getSupabaseAdmin();
  const { data, error } = await admin.rpc("admin_set_token_launched", {
    p_admin_user_id: callerId,
    p_launched: launched,
  });

  if (error) {
    const mapped = mapPgError((error as { code?: string }).code, error.message);
    return errorResponse(mapped.status, mapped.error.code, mapped.error.message);
  }

  // admin_set_token_launched() returns boolean directly.
  return jsonResponse(
    {
      success: true,
      token_launched: data === true,
    },
    200,
  );
});