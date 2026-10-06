// Pro-X Network — "admin-withdrawals" Edge Function.
//
// POST /functions/v1/admin-withdrawals
//
// Admin-only actions:
//   List pending:  { "action": "list_pending" }
//   List active:   { "action": "list_active" }  — pending AND approved
//                  (0055_admin_active_withdrawals_and_leaderboard_self_name.sql).
//                  Added so the admin UI has one queue that covers the
//                  full pending -> approved -> complete workflow — with
//                  list_pending alone, a withdrawal disappears from the
//                  only list the UI could fetch the instant it's
//                  approved, before COMPLETE is ever reachable.
//                  list_pending itself is unchanged and still works.
//   Approve:       { "action": "approve", "withdrawal_id": "<uuid>" }
//   Reject:        { "action": "reject",  "withdrawal_id": "<uuid>", "reason": "<1-500 chars>" }
//   Complete:      { "action": "complete", "withdrawal_id": "<uuid>", "tx_hash": "<non-empty string>" }
//
// Authentication & authorization — identical pattern to
// functions/admin-users (kept deliberately unchanged as the model):
//   - Request body parsed/validated FIRST, before any auth or database
//     call.
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     caller's own Authorization bearer token) is used for TWO things
//     only: auth.getUser() (identity) and the EXISTING
//     public.is_current_user_admin() RPC (authorization). If either
//     fails: 401/403.
//   - Only after both checks pass does this file use the service-role
//     client, and only to call the admin_* withdrawal RPCs in
//     0052_player_wallet_and_withdrawals.sql — every one of those RPCs
//     ALSO independently re-verifies admin_users membership server-side
//     (defense in depth: this file's own check is not the only gate).
//   - withdrawal_id is the TARGET row being actioned — never trusted as
//     proof of anything about the caller.
//
// This file does NOT implement any balance movement, wallet validation,
// or conversion-rate logic itself — all of that lives inside the
// SECURITY DEFINER RPCs it calls. It does NOT touch mining_state,
// player_wallets, marketplace, or leaderboard tables directly.
//
// Response envelope:
//   Success: { "success": true, "data": <RPC result> }
//   Error:   { "success": false, "error": { "code", "message" } }

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
const FORBIDDEN = () => errorResponse(403, "ADMIN_REQUIRED", "Admin access required");

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

// Maps the admin_* withdrawal RPCs' PXNxx SQLSTATEs (see
// 0052_player_wallet_and_withdrawals.sql section 7) to a clean
// application error. Never forwards a raw PostgreSQL error message.
function mapPgError(code: string | undefined, rawMessage: string): { status: number; error: AppError } {
  switch (code) {
    case "PXN61":
      return { status: 403, error: { code: "ADMIN_REQUIRED", message: "Admin access required" } };
    case "PXN90":
      return { status: 404, error: { code: "WITHDRAWAL_NOT_FOUND", message: "Withdrawal not found" } };
    case "PXN91":
      return { status: 409, error: { code: "WITHDRAWAL_NOT_PENDING", message: "This withdrawal is no longer pending" } };
    case "PXN92":
      return { status: 400, error: { code: "REJECTION_REASON_REQUIRED", message: "A reason is required" } };
    case "PXN93":
      return { status: 409, error: { code: "WITHDRAWAL_NOT_APPROVED", message: "This withdrawal has not been approved yet" } };
    default:
      console.error("[admin-withdrawals] unrecognized database error:", code, rawMessage);
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
  const action = typeof rec.action === "string" ? rec.action : "list_pending";

  const SUPPORTED = new Set(["list_pending", "list_active", "approve", "reject", "complete"]);
  if (!SUPPORTED.has(action)) {
    return errorResponse(400, "VALIDATION_ERROR", "action must be one of: list_pending, list_active, approve, reject, complete");
  }

  let withdrawalId: string | undefined;
  let reason: string | undefined;
  let txHash: string | undefined;

  if (action === "approve" || action === "reject" || action === "complete") {
    if (!isUuid(rec.withdrawal_id)) {
      return errorResponse(400, "VALIDATION_ERROR", "withdrawal_id must be a valid UUID");
    }
    withdrawalId = rec.withdrawal_id;
  }
  if (action === "reject") {
    if (typeof rec.reason !== "string" || rec.reason.trim().length === 0) {
      return errorResponse(400, "REJECTION_REASON_REQUIRED", "A non-empty reason is required");
    }
    reason = rec.reason;
  }
  if (action === "complete") {
    if (typeof rec.tx_hash !== "string" || rec.tx_hash.trim().length === 0) {
      return errorResponse(400, "VALIDATION_ERROR", "tx_hash must be a non-empty string");
    }
    txHash = rec.tx_hash;
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) return UNAUTHORIZED();

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error("[admin-withdrawals] server misconfigured:", err instanceof Error ? err.message : "unknown error");
    return errorResponse(500, "INTERNAL_ERROR", "Service temporarily unavailable");
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) return UNAUTHORIZED();
  const callerId = authData.user.id;

  // Existing admin authorization mechanism (0019_admin_auth_foundation.sql),
  // reused as-is — called AS the caller so it evaluates auth.uid() = caller.
  const { data: isAdmin, error: adminCheckError } = await userClient.rpc(
    "is_current_user_admin",
  );
  if (adminCheckError || isAdmin !== true) return FORBIDDEN();

  const admin = getSupabaseAdmin();

  try {
    if (action === "list_pending") {
      const { data, error } = await admin.rpc("admin_list_pending_withdrawals", {
        p_admin_user_id: callerId,
      });
      if (error) throw error;
      return jsonResponse({ success: true, data }, 200);
    }

    if (action === "list_active") {
      const { data, error } = await admin.rpc("admin_list_active_withdrawals", {
        p_admin_user_id: callerId,
      });
      if (error) throw error;
      return jsonResponse({ success: true, data }, 200);
    }

    if (action === "approve") {
      const { data, error } = await admin.rpc("admin_approve_withdrawal", {
        p_admin_user_id: callerId,
        p_withdrawal_id: withdrawalId,
      });
      if (error) throw error;
      return jsonResponse({ success: true, data }, 200);
    }

    if (action === "reject") {
      const { data, error } = await admin.rpc("admin_reject_withdrawal", {
        p_admin_user_id: callerId,
        p_withdrawal_id: withdrawalId,
        p_reason: reason,
      });
      if (error) throw error;
      return jsonResponse({ success: true, data }, 200);
    }

    if (action === "complete") {
      const { data, error } = await admin.rpc("admin_complete_withdrawal", {
        p_admin_user_id: callerId,
        p_withdrawal_id: withdrawalId,
        p_tx_hash: txHash,
      });
      if (error) throw error;
      return jsonResponse({ success: true, data }, 200);
    }
  } catch (error) {
    const err = error as { code?: string; message?: string };
    const mapped = mapPgError(err.code, err.message ?? "unknown error");
    return errorResponse(mapped.status, mapped.error.code, mapped.error.message);
  }

  // Unreachable — SUPPORTED.has(action) already narrowed action above.
  return errorResponse(400, "VALIDATION_ERROR", "Unsupported action");
});
