// Pro-X Network — "admin-set-mining-speed" Edge Function.
//
// POST /functions/v1/admin-set-mining-speed
//
// Admin-only: sets or clears a specific player's admin-controlled
// mining speed override (public.mining_state.admin_speed_override —
// see 0020_admin_mining_speed_control.sql). This is the ONLY entry
// point for that column; it does NOT implement any general-purpose
// balance/state update endpoint, does NOT touch pxn_balance,
// mining_inventory, referrals, level, or purchase data, and does NOT
// modify accrue-mining's own auth/accrual logic beyond reading this
// one column (see accrue-mining/index.ts, updated alongside this
// file). Every actual validation/write happens inside
// public.admin_set_mining_speed / public.admin_clear_mining_speed_override
// (both SECURITY DEFINER, service_role-only) — this file only
// authenticates and authorizes the CALLER, validates the request
// shape, and delegates.
//
// Request body — two forms, both requiring "userId":
//   Set:   { "userId": <uuid>, "speed": <number> }
//   Clear: { "userId": <uuid>, "clear": true }
//   - userId must be a JSON string that is a valid UUID (the TARGET
//     player's auth.users id, i.e. public.users.id — see
//     0020_admin_mining_speed_control.sql's identity note). This is
//     the only place in this file a "userId" from the request body is
//     ever used for anything OTHER than authorization — it identifies
//     the player being acted ON, never the caller.
//   - speed (Set form only) must be a JSON number, finite (no NaN /
//     Infinity — JSON itself cannot encode either, but a hand-crafted
//     request body is rejected defensively too), and within
//     0 to 1,000,000 PXN/sec. The database applies the same range
//     check independently (defense in depth).
//   - clear (Clear form) must be exactly JSON `true` when present.
//   - Anything else (missing/wrong-typed userId, a body with neither
//     a valid "speed" nor "clear: true", a malformed UUID) is
//     rejected with 400 before the database — including the
//     authorization check below — is touched.
//
// Authentication & authorization (identical caller-identity pattern
// to functions/me, purchase-miner, set-miner-applied, accrue-mining —
// see those files):
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     CALLER's own `Authorization: Bearer <token>`) is used for TWO
//     things only: auth.getUser() (identity) and the
//     public.is_current_user_admin() RPC (authorization). Never used
//     for any other read/write.
//   - auth.getUser() is the sole source of the caller's identity —
//     never trusted from the request body, a header, or any
//     client-supplied flag. If it fails, 401.
//   - public.is_current_user_admin() (see
//     0019_admin_auth_foundation.sql) is then called AS THAT CALLER
//     (so it evaluates auth.uid() = the caller, never the target
//     userId from the body) to decide admin status server-side. If it
//     returns anything other than exactly `true`, 403 — the caller is
//     never told whether the target user exists, to avoid leaking
//     that to a non-admin caller.
//   - Only after both checks pass is the service-role client used, to
//     call admin_set_mining_speed / admin_clear_mining_speed_override
//     — both GRANTed to service_role only, so this Edge Function is
//     the only possible caller of either RPC. SUPABASE_SERVICE_ROLE_KEY
//     is read only from Deno.env (Supabase secrets), is never present
//     in any response, and is never sent to or usable by the
//     frontend.
//
// Response 200: { success: true, userId, adminSpeedOverride: <number|null> }
// Response 400: { success: false, message: "..." }
//   (malformed body, invalid userId, invalid speed)
// Response 401: { success: false, message: "Unauthorized" }
// Response 403: { success: false, message: "Forbidden" }
//   (authenticated, but not an admin)
// Response 404: { success: false, message: "Target player not found" }
//   (userId is a syntactically valid UUID but has no mining_state row)
// Response 405: method not allowed
// Response 500: server misconfiguration or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;
const FORBIDDEN = { success: false, message: "Forbidden" } as const;

// Custom SQLSTATEs raised by public.admin_set_mining_speed /
// public.admin_clear_mining_speed_override (see
// 0020_admin_mining_speed_control.sql). Mapped below to the HTTP
// status that best reflects each failure mode.
const PG_ERR_INVALID_INPUT = "PXN12";
const PG_ERR_INVALID_SPEED = "PXN13";
const PG_ERR_TARGET_NOT_FOUND = "PXN14";

const MAX_SPEED = 1000000;

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

/** Strict validation for userId (the TARGET player): present, a JSON string, a valid UUID. Never coerces. */
function parseTargetUserId(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const raw = (body as Record<string, unknown>).userId;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!UUID_RE.test(trimmed)) return null;
  return trimmed;
}

/** True only if the body has `clear: true` (JSON boolean, not truthy-coerced). */
function isClearRequest(body: unknown): boolean {
  if (typeof body !== "object" || body === null) return false;
  return (body as Record<string, unknown>).clear === true;
}

/**
 * Strict validation for speed: must be present, a JSON number, finite
 * (rejects NaN/Infinity — defensive; JSON itself can't encode them),
 * and within [0, MAX_SPEED]. Never coerces strings/booleans/null.
 */
function parseSpeed(body: unknown): number | null {
  if (typeof body !== "object" || body === null) return null;
  const raw = (body as Record<string, unknown>).speed;
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw)) return null;
  if (raw < 0 || raw > MAX_SPEED) return null;
  return raw;
}

interface AdminSpeedRow {
  user_id: string;
  admin_speed_override: number | string | null;
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

  const targetUserId = parseTargetUserId(rawBody);
  if (targetUserId === null) {
    return jsonResponse({ success: false, message: "userId must be a valid UUID" }, 400);
  }

  const clearRequested = isClearRequest(rawBody);
  let speed: number | null = null;

  if (!clearRequested) {
    speed = parseSpeed(rawBody);
    if (speed === null) {
      return jsonResponse(
        { success: false, message: `speed must be a finite number from 0 to ${MAX_SPEED}` },
        400,
      );
    }
  }

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[admin-set-mining-speed] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the caller's own
  // identity + admin-authorization checks below (auth.getUser() and
  // the is_current_user_admin() RPC, both evaluated as the CALLER,
  // via their own bearer token). Never used for any other database
  // read or write, and never used with the targetUserId above.
  const callerClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await callerClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }

  // --- Authorization: is THIS caller an admin? Server-side only. ---
  const { data: isAdminData, error: isAdminError } = await callerClient.rpc(
    "is_current_user_admin",
  );
  if (isAdminError) {
    console.error(
      "[admin-set-mining-speed] is_current_user_admin check failed:",
      isAdminError.message,
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }
  if (isAdminData !== true) {
    return jsonResponse(FORBIDDEN, 403);
  }

  // Service-role client — the only client that may call
  // admin_set_mining_speed / admin_clear_mining_speed_override (both
  // GRANTed to service_role only). Every validation/lookup/write
  // happens inside those RPCs, not in this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[admin-set-mining-speed] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  const { data: rpcData, error: rpcError } = clearRequested
    ? await admin
        .rpc("admin_clear_mining_speed_override", { p_user_id: targetUserId })
        .maybeSingle()
    : await admin
        .rpc("admin_set_mining_speed", { p_user_id: targetUserId, p_speed: speed })
        .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_INVALID_INPUT:
        return jsonResponse({ success: false, message: "Invalid request" }, 400);
      case PG_ERR_INVALID_SPEED:
        return jsonResponse(
          { success: false, message: `speed must be from 0 to ${MAX_SPEED}` },
          400,
        );
      case PG_ERR_TARGET_NOT_FOUND:
        return jsonResponse({ success: false, message: "Target player not found" }, 404);
      default:
        console.error(
          "[admin-set-mining-speed] RPC failed:",
          rpcError.message,
        );
        return jsonResponse({ success: false, message: "Could not update mining speed" }, 500);
    }
  }

  const row = rpcData as AdminSpeedRow | null;
  if (!row) {
    console.error("[admin-set-mining-speed] RPC returned no row");
    return jsonResponse({ success: false, message: "Could not update mining speed" }, 500);
  }

  return jsonResponse(
    {
      success: true,
      userId: row.user_id,
      adminSpeedOverride:
        row.admin_speed_override === null ? null : Number(row.admin_speed_override),
    },
    200,
  );
});
