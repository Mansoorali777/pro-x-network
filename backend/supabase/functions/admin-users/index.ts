// Pro-X Network — "admin-users" Edge Function.
//
// POST /functions/v1/admin-users
//
// Admin-only, READ-ONLY endpoint. Lets an authenticated admin view
// every player's identity fields (from public.users) alongside their
// EXACT, database-authoritative PXN balance (public.mining_state.
// pxn_balance). It does NOT write, reset, or adjust any balance, does
// NOT touch mined_balance_total / pending_claim / claimed_total /
// level / any other mining_state column, does NOT modify public.users
// or any other table, does NOT introduce any custom JWT/JWT secret,
// and does NOT change admin-set-mining-speed, admin-miner-catalog,
// admin-miner-upgrade-cost, or any existing RLS policy/RPC/migration.
//
// Request body: {} (no fields — this endpoint takes none; a JSON
// object is still required so the shape matches every other Edge
// Function in this project, but nothing in the body is read).
//
// Authentication & authorization (identical caller-identity +
// admin-check pattern to admin-set-mining-speed and
// admin-miner-catalog — see those files):
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     CALLER's own `Authorization: Bearer <token>`) is used for TWO
//     things only: auth.getUser() (identity) and the
//     public.is_current_user_admin() RPC (authorization). Never used
//     for any other read.
//   - auth.getUser() is the sole source of the caller's identity —
//     never trusted from the request body, a header, or any
//     client-supplied flag. If it fails: 401.
//   - public.is_current_user_admin() (see 0019_admin_auth_foundation.sql)
//     is then called AS THAT CALLER (so it evaluates auth.uid() = the
//     caller) to decide admin status server-side. If it returns
//     anything other than exactly `true`: 403.
//   - Only after BOTH checks pass is the service-role client used, to
//     read public.users and public.mining_state. SUPABASE_SERVICE_ROLE_KEY
//     is read only from Deno.env (Supabase secrets, via
//     _shared/env.ts -> _shared/supabaseAdmin.ts), is never present in
//     any response, and is never sent to or usable by the frontend.
//     This is also the only path that can read these tables for users
//     other than yourself at all: public.users has only a
//     "users_select_own" RLS policy (auth.uid() = id) and
//     public.mining_state only "mining_state_select_own"
//     (auth.uid() = user_id) — an authenticated, non-admin caller can
//     never read another player's row through any client-side query,
//     RLS denies it by default. This function is a deliberate,
//     narrow, admin-gated exception, exactly like the target-lookup
//     half of admin-set-mining-speed.
//
// Database access:
//   - Reads public.users (id, telegram_user_id, telegram_username,
//     telegram_first_name, telegram_last_name, created_at — see
//     0002_users.sql) and public.mining_state (user_id, pxn_balance —
//     see 0013_mining_state.sql), then joins them in application code
//     on users.id = mining_state.user_id. Strictly read-only: no
//     insert/update/delete of any kind, on either table or any other.
//   - A player with no mining_state row yet (should not normally
//     happen post-auth, but not assumed) shows pxnBalance: 0 rather
//     than being dropped from the list or erroring.
//   - pxn_balance is a PostgreSQL numeric(20,8) column, which
//     supabase-js can surface as a string; every value is passed
//     through Number(...) and Number.isFinite(...), falling back to 0
//     (never NaN) if that check fails.
//   - telegram_user_id (bigint) is returned as a decimal string, not a
//     JS number, since a JS number cannot safely represent every
//     bigint value without precision loss.
//
// Response 200: { success: true, users: [ { userId, telegramUserId,
//   username, firstName, lastName, pxnBalance, createdAt }, ... ] }
// Response 401: { success: false, message: "Unauthorized" }
// Response 403: { success: false, message: "Forbidden" }
//   (authenticated, but not an admin)
// Response 405: method not allowed
// Response 500: server misconfiguration or unexpected database error
//   only — never the underlying error detail or any secret.
//
// Never logs the access token, the service-role key, or any other
// secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;
const FORBIDDEN = { success: false, message: "Forbidden" } as const;
const SERVICE_UNAVAILABLE = { success: false, message: "Service temporarily unavailable" } as const;

interface UserRow {
  id: string;
  telegram_user_id: number | string | null;
  telegram_username: string | null;
  telegram_first_name: string | null;
  telegram_last_name: string | null;
  created_at: string;
}

interface MiningStateBalanceRow {
  user_id: string;
  pxn_balance: number | string | null;
}

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

/** Number(...) + Number.isFinite(...), never NaN — falls back to 0 per spec. */
function safePxnBalance(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
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
      "[admin-users] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the caller's own
  // identity + admin-authorization checks below (auth.getUser() and
  // the is_current_user_admin() RPC, both evaluated as the CALLER, via
  // their own bearer token). Never used for any other database read.
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
    console.error("[admin-users] is_current_user_admin check failed:", isAdminError.message);
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }
  if (isAdminData !== true) {
    return jsonResponse(FORBIDDEN, 403);
  }

  // Service-role client — the only client that can read every player's
  // public.users / public.mining_state row (both tables only grant
  // "select own" to authenticated via RLS). Only constructed after the
  // caller has already been confirmed authenticated AND admin above.
  // Used for exactly two read-only SELECTs.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[admin-users] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  const { data: usersData, error: usersError } = await admin
    .from("users")
    .select("id, telegram_user_id, telegram_username, telegram_first_name, telegram_last_name, created_at")
    .order("created_at", { ascending: false });

  if (usersError) {
    console.error("[admin-users] users list failed:", usersError.message);
    return jsonResponse({ success: false, message: "Could not load users" }, 500);
  }

  const { data: balancesData, error: balancesError } = await admin
    .from("mining_state")
    .select("user_id, pxn_balance");

  if (balancesError) {
    console.error("[admin-users] mining_state list failed:", balancesError.message);
    return jsonResponse({ success: false, message: "Could not load users" }, 500);
  }

  const balanceByUserId = new Map<string, unknown>();
  for (const row of (balancesData ?? []) as MiningStateBalanceRow[]) {
    balanceByUserId.set(row.user_id, row.pxn_balance);
  }

  const users = ((usersData ?? []) as UserRow[]).map((u) => ({
    userId: u.id,
    telegramUserId: u.telegram_user_id === null || u.telegram_user_id === undefined
      ? null
      : String(u.telegram_user_id),
    username: u.telegram_username,
    firstName: u.telegram_first_name,
    lastName: u.telegram_last_name,
    // Not present in balanceByUserId (no mining_state row yet) safely
    // falls back to 0 via safePxnBalance(undefined), same as a
    // non-finite stored value would.
    pxnBalance: safePxnBalance(balanceByUserId.get(u.id)),
    createdAt: u.created_at,
  }));

  return jsonResponse({ success: true, users }, 200);
});
