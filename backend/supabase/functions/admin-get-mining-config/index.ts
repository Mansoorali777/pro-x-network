// Pro-X Network — "admin-get-mining-config" Edge Function.
//
// POST /functions/v1/admin-get-mining-config
//
// Admin-only, READ-ONLY: returns the seven LIVE public.mining_config
// columns that admin-set-mining-config/index.ts can write and
// accrue-mining/index.ts (plus level-up-mining/index.ts for
// level_up_cost_pxn) actually reads for real mining-rate/level-up math.
//
// This function exists solely so admin.html has a safe way to POPULATE
// its "LIVE MINING ECONOMY" panel with the current server values before
// an admin makes any change — it never writes, mutates, or deactivates
// anything. It does NOT touch mining_state, mining_inventory,
// miner_catalog, task_catalog, task_claims, mpxn_ledger, marketplace_*,
// users, or admin_users. It does NOT call admin_set_mining_config or any
// other data-changing RPC. It does NOT modify mining_config.updated_by_admin
// or anything else — this is a single read-only SELECT, nothing more.
//
// Fields returned — deliberately restricted to exactly the seven
// mining_config columns admin-set-mining-config can change (see that
// file's own header comment for the full per-column audit):
//   base_speed, referral_speed_bonus, boost_multiplier,
//   ad_boost_multiplier, level_boost_percent, level_up_cost_pxn,
//   max_offline_accrual_sec
// Every other mining_config column (id, referral_instant_pxn,
// boost_duration_min, tap_boost_multiplier, tap_boost_duration_sec,
// ads_required_for_boost, ad_boost_duration_hours, ad_sim_seconds,
// pxn_swap_rate, miner_tiers, is_active, created_by, updated_by_admin,
// created_at) is intentionally left out of the SELECT and the
// response — this endpoint has no reason to expose them, and keeping
// the read narrow means this file can never leak more than the admin
// panel's Live Mining Economy fields need.
//
// Authentication & authorization (identical caller-identity pattern to
// admin-set-mining-config / admin-set-mining-speed — see those files):
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     CALLER's own `Authorization: Bearer <token>`) is used for TWO
//     things only: auth.getUser() (identity) and the
//     public.is_current_user_admin() RPC (authorization). Never used
//     for any other read/write.
//   - auth.getUser() is the SOLE source of the caller's identity —
//     never trusted from the request body, a header, or any
//     client-supplied admin flag. If it fails: 401.
//   - public.is_current_user_admin() (0019_admin_auth_foundation.sql)
//     is then called AS THAT CALLER (evaluates auth.uid() = the
//     caller) to decide admin status server-side. If it returns
//     anything other than exactly `true`: 403.
//   - Only after both checks pass is the service-role client used —
//     for a single SELECT against mining_config (a table with zero
//     client-facing RLS policies, per accrue-mining/index.ts's own
//     comments, so a caller-scoped client could never read it
//     directly even if it tried).
//
// Response 200: { success: true, config: { base_speed,
//   referral_speed_bonus, boost_multiplier, ad_boost_multiplier,
//   level_boost_percent, level_up_cost_pxn, max_offline_accrual_sec } }
//   (all seven numeric fields are returned as JSON numbers)
// Response 401: { success: false, message: "Unauthorized" }
// Response 403: { success: false, message: "Forbidden" }
//   (authenticated, but not an admin)
// Response 405: method not allowed
// Response 500: server misconfiguration, no active mining_config row
//   (should be unreachable — see 0003_mining_config.sql's unique
//   partial index), or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret. Database errors are never forwarded verbatim to the client
// — only a generic message is returned; the real error is logged
// server-side only.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;
const FORBIDDEN = { success: false, message: "Forbidden" } as const;
const SERVICE_UNAVAILABLE = { success: false, message: "Service temporarily unavailable" } as const;

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

interface MiningConfigRow {
  base_speed: number | string;
  referral_speed_bonus: number | string;
  boost_multiplier: number | string;
  ad_boost_multiplier: number | string;
  level_boost_percent: number | string;
  level_up_cost_pxn: number | string;
  max_offline_accrual_sec: number;
}

/** Maps the DB row to the JSON shape returned to the client — plain numbers, snake_case, exactly the seven allowed fields. */
function formatConfig(row: MiningConfigRow) {
  return {
    base_speed: Number(row.base_speed),
    referral_speed_bonus: Number(row.referral_speed_bonus),
    boost_multiplier: Number(row.boost_multiplier),
    ad_boost_multiplier: Number(row.ad_boost_multiplier),
    level_boost_percent: Number(row.level_boost_percent),
    level_up_cost_pxn: Number(row.level_up_cost_pxn),
    max_offline_accrual_sec: row.max_offline_accrual_sec,
  };
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
      "[admin-get-mining-config] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the caller's own
  // identity + admin-authorization checks below (auth.getUser() and
  // the is_current_user_admin() RPC, both evaluated as the CALLER via
  // their own bearer token). Never used for any other database read
  // or write.
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
      "[admin-get-mining-config] is_current_user_admin check failed:",
      isAdminError.message,
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }
  if (isAdminData !== true) {
    return jsonResponse(FORBIDDEN, 403);
  }

  // Service-role client — mining_config has zero client-facing RLS
  // policies by design (see accrue-mining/index.ts), so only the
  // service-role client can read it at all. Used here for a single,
  // read-only SELECT of the active row's seven admin-editable
  // columns — no insert, update, delete, or RPC call of any kind.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[admin-get-mining-config] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  const { data: configData, error: configError } = await admin
    .from("mining_config")
    .select(
      "base_speed, referral_speed_bonus, boost_multiplier, ad_boost_multiplier, level_boost_percent, level_up_cost_pxn, max_offline_accrual_sec",
    )
    .eq("is_active", true)
    .maybeSingle();

  if (configError) {
    console.error(
      "[admin-get-mining-config] failed to load active mining_config:",
      configError.message,
    );
    return jsonResponse({ success: false, message: "Could not load mining config" }, 500);
  }

  const row = configData as MiningConfigRow | null;
  if (!row) {
    console.error("[admin-get-mining-config] no active mining_config row found");
    return jsonResponse({ success: false, message: "Could not load mining config" }, 500);
  }

  return jsonResponse({ success: true, config: formatConfig(row) }, 200);
});
