// Pro-X Network — "admin-set-mining-config" Edge Function.
//
// POST /functions/v1/admin-set-mining-config
//
// Admin-only: updates the LIVE public.mining_config row — the table
// accrue-mining/index.ts and level-up-mining actually read for real
// mining-rate/level-up math (re-confirmed by reading both files in
// full before writing this function) — by delegating the entire
// lock / validate / deactivate-old-row / insert-new-row sequence to a
// single SECURITY DEFINER Postgres function,
// public.admin_set_mining_config (see
// 0041_admin_mining_config_control.sql). This function does NOT
// implement any of that logic itself, and does NOT touch
// mining_state, mining_inventory, miner_catalog, task_catalog,
// task_claims, mpxn_ledger, marketplace_*, users, admin_users, or any
// existing Edge Function or migration.
//
// This is Phase 1 only. It does NOT implement Daily Boost / Ad Boost
// activation, referral tracking, or Tap Boost — those need their own
// later migrations writing to mining_state (boost_until,
// ad_boost_until, referral_count), none of which this function or its
// RPC ever reads or writes.
//
// admin.html is NOT updated to call this function yet (that's an
// explicitly separate, later step) — today, admin.html's "REWARDS"
// panel still only edits localStorage["proxnetwork_admin_config_v1"],
// which has zero effect on this table. This function exists so that
// a future frontend change (or a direct authenticated call, e.g. from
// the Supabase SQL editor's REST tester or a manual fetch) has a real,
// secure write path to mining_config for the first time.
//
// Request body — a single JSON object. Every field is OPTIONAL; at
// least one must be present. Omitted fields are left completely
// unchanged from the current active mining_config row — they are
// NEVER reset to a default or to null.
//   {
//     "baseSpeed"?:              <number, 0 to 1000000>,
//     "referralSpeedBonus"?:     <number, 0 to 1000000>,
//     "boostMultiplier"?:        <number, greater than 0, up to 1000>,
//     "adBoostMultiplier"?:      <number, greater than 0, up to 1000>,
//     "levelBoostPercent"?:      <number, 0 to 10 — a fraction, e.g.
//                                 0.05 = "+5% mining speed per level",
//                                 matching mining_config's existing
//                                 storage convention (see
//                                 accrue-mining/index.ts's own
//                                 levelBoostMultiplier() comment)>,
//     "levelUpCostPxn"?:         <number, 0 to 100000000>,
//     "maxOfflineAccrualSec"?:   <integer, 60 to 2592000>
//   }
// These are exactly, and only, the seven mining_config columns
// accrue-mining/level-up-mining actually read today (re-audited before
// writing this file — see 0041's own header comment for the full
// per-column confirmation). No other mining_config column
// (referral_instant_pxn, boost_duration_min, tap_boost_multiplier,
// tap_boost_duration_sec, ads_required_for_boost,
// ad_boost_duration_hours, ad_sim_seconds, pxn_swap_rate, miner_tiers)
// can be changed through this function — there is no field for any of
// them, by design, and the RPC always carries their existing values
// forward unchanged.
//
// Every present field is validated here, strictly, BEFORE the
// database — matching ranges are re-validated inside the RPC itself
// as defense in depth (same two-layer pattern as
// admin-set-mining-speed / admin_set_mining_speed).
//
// Authentication & authorization (identical caller-identity pattern to
// admin-set-mining-speed / admin-miner-catalog / admin-task-catalog —
// see those files):
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
//   - Only after both checks pass is the service-role client used, to
//     call admin_set_mining_config — GRANTed to service_role only, so
//     this Edge Function is the only possible caller of that RPC.
//     SUPABASE_SERVICE_ROLE_KEY is read only from Deno.env (Supabase
//     secrets), is never present in any response, and is never sent
//     to or usable by the frontend.
//   - The caller's own verified id (from auth.getUser(), NEVER from
//     the request body) is passed to the RPC as p_admin_user_id —
//     stored only for audit purposes (mining_config.updated_by_admin)
//     and never used to decide authorization itself (that decision is
//     already final by the time the RPC is called).
//
// Response 200: { success: true, config: { id, baseSpeed,
//   referralInstantPxn, referralSpeedBonus, boostMultiplier,
//   boostDurationMin, tapBoostMultiplier, tapBoostDurationSec,
//   adsRequiredForBoost, adBoostMultiplier, adBoostDurationHours,
//   adSimSeconds, levelUpCostPxn, levelBoostPercent,
//   maxOfflineAccrualSec, pxnSwapRate, minerTiers, isActive,
//   createdBy, updatedByAdmin, createdAt } }
//   (the FULL new active row is returned, including the columns this
//   function cannot change, so a caller always sees the complete,
//   current live config — never a partial/merged guess)
// Response 400: { success: false, message: "..." }
//   (malformed body, no fields provided, or a field out of range)
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
// — only a small set of recognized error codes are mapped to specific
// messages; everything else becomes a generic 500.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;
const FORBIDDEN = { success: false, message: "Forbidden" } as const;
const SERVICE_UNAVAILABLE = { success: false, message: "Service temporarily unavailable" } as const;

// Custom SQLSTATEs raised by public.admin_set_mining_config (see
// 0041_admin_mining_config_control.sql). Mapped below to the HTTP
// status that best reflects each failure mode.
const PG_ERR_INVALID_INPUT = "PXN47";
const PG_ERR_OUT_OF_RANGE = "PXN48";
const PG_ERR_NO_ACTIVE_CONFIG = "PXN49";

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

function isPlainObject(body: unknown): body is Record<string, unknown> {
  return typeof body === "object" && body !== null && !Array.isArray(body);
}

/**
 * Strict validation for one optional numeric field: absent/undefined
 * -> { present: false } ("leave unchanged" — never coerced from
 * null, missing key only). Present but not a finite JSON number, or
 * outside [min, max] (exclusiveMin: outside (min, max]) -> null
 * (invalid — caller must reject with 400). Present and valid ->
 * { present: true, value }. Never trims/coerces strings/booleans.
 */
function parseOptionalNumber(
  body: Record<string, unknown>,
  key: string,
  min: number,
  max: number,
  exclusiveMin = false,
): { present: boolean; value: number } | null {
  if (!(key in body) || body[key] === undefined) {
    return { present: false, value: 0 };
  }
  const raw = body[key];
  if (typeof raw !== "number" || !Number.isFinite(raw)) return null;
  if (exclusiveMin ? raw <= min : raw < min) return null;
  if (raw > max) return null;
  return { present: true, value: raw };
}

/** Same as parseOptionalNumber, additionally requiring an integer value. */
function parseOptionalInteger(
  body: Record<string, unknown>,
  key: string,
  min: number,
  max: number,
): { present: boolean; value: number } | null {
  const result = parseOptionalNumber(body, key, min, max);
  if (result === null) return null;
  if (result.present && !Number.isInteger(result.value)) return null;
  return result;
}

interface MiningConfigRow {
  id: string;
  base_speed: number | string;
  referral_instant_pxn: number | string;
  referral_speed_bonus: number | string;
  boost_multiplier: number | string;
  boost_duration_min: number;
  tap_boost_multiplier: number | string;
  tap_boost_duration_sec: number;
  ads_required_for_boost: number;
  ad_boost_multiplier: number | string;
  ad_boost_duration_hours: number;
  ad_sim_seconds: number;
  level_up_cost_pxn: number | string;
  level_boost_percent: number | string;
  max_offline_accrual_sec: number;
  pxn_swap_rate: number | string;
  miner_tiers: unknown;
  is_active: boolean;
  created_by: string | null;
  updated_by_admin: string | null;
  created_at: string;
}

/** Maps a DB row to the camelCase shape returned to the client. */
function formatConfig(row: MiningConfigRow) {
  return {
    id: row.id,
    baseSpeed: Number(row.base_speed),
    referralInstantPxn: Number(row.referral_instant_pxn),
    referralSpeedBonus: Number(row.referral_speed_bonus),
    boostMultiplier: Number(row.boost_multiplier),
    boostDurationMin: row.boost_duration_min,
    tapBoostMultiplier: Number(row.tap_boost_multiplier),
    tapBoostDurationSec: row.tap_boost_duration_sec,
    adsRequiredForBoost: row.ads_required_for_boost,
    adBoostMultiplier: Number(row.ad_boost_multiplier),
    adBoostDurationHours: row.ad_boost_duration_hours,
    adSimSeconds: row.ad_sim_seconds,
    levelUpCostPxn: Number(row.level_up_cost_pxn),
    levelBoostPercent: Number(row.level_boost_percent),
    maxOfflineAccrualSec: row.max_offline_accrual_sec,
    pxnSwapRate: Number(row.pxn_swap_rate),
    minerTiers: row.miner_tiers,
    isActive: row.is_active,
    createdBy: row.created_by,
    updatedByAdmin: row.updated_by_admin,
    createdAt: row.created_at,
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

  // --- Parse and strictly validate the request body BEFORE touching auth or the database. ---
  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return jsonResponse({ success: false, message: "Request body must be valid JSON" }, 400);
  }

  if (!isPlainObject(rawBody)) {
    return jsonResponse({ success: false, message: "Request body must be a JSON object" }, 400);
  }

  const baseSpeed = parseOptionalNumber(rawBody, "baseSpeed", 0, 1000000);
  if (baseSpeed === null) {
    return jsonResponse({ success: false, message: "baseSpeed must be a finite number from 0 to 1000000" }, 400);
  }

  const referralSpeedBonus = parseOptionalNumber(rawBody, "referralSpeedBonus", 0, 1000000);
  if (referralSpeedBonus === null) {
    return jsonResponse(
      { success: false, message: "referralSpeedBonus must be a finite number from 0 to 1000000" },
      400,
    );
  }

  const boostMultiplier = parseOptionalNumber(rawBody, "boostMultiplier", 0, 1000, true);
  if (boostMultiplier === null) {
    return jsonResponse(
      { success: false, message: "boostMultiplier must be a finite number greater than 0, up to 1000" },
      400,
    );
  }

  const adBoostMultiplier = parseOptionalNumber(rawBody, "adBoostMultiplier", 0, 1000, true);
  if (adBoostMultiplier === null) {
    return jsonResponse(
      { success: false, message: "adBoostMultiplier must be a finite number greater than 0, up to 1000" },
      400,
    );
  }

  const levelBoostPercent = parseOptionalNumber(rawBody, "levelBoostPercent", 0, 10);
  if (levelBoostPercent === null) {
    return jsonResponse(
      { success: false, message: "levelBoostPercent must be a finite number from 0 to 10" },
      400,
    );
  }

  const levelUpCostPxn = parseOptionalNumber(rawBody, "levelUpCostPxn", 0, 100000000);
  if (levelUpCostPxn === null) {
    return jsonResponse(
      { success: false, message: "levelUpCostPxn must be a finite number from 0 to 100000000" },
      400,
    );
  }

  const maxOfflineAccrualSec = parseOptionalInteger(rawBody, "maxOfflineAccrualSec", 60, 2592000);
  if (maxOfflineAccrualSec === null) {
    return jsonResponse(
      { success: false, message: "maxOfflineAccrualSec must be an integer from 60 to 2592000 seconds" },
      400,
    );
  }

  if (
    !baseSpeed.present &&
    !referralSpeedBonus.present &&
    !boostMultiplier.present &&
    !adBoostMultiplier.present &&
    !levelBoostPercent.present &&
    !levelUpCostPxn.present &&
    !maxOfflineAccrualSec.present
  ) {
    return jsonResponse(
      { success: false, message: "At least one config value must be provided" },
      400,
    );
  }

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[admin-set-mining-config] server misconfigured:",
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
  const adminUserId = authData.user.id;

  // --- Authorization: is THIS caller an admin? Server-side only. ---
  const { data: isAdminData, error: isAdminError } = await callerClient.rpc(
    "is_current_user_admin",
  );
  if (isAdminError) {
    console.error(
      "[admin-set-mining-config] is_current_user_admin check failed:",
      isAdminError.message,
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }
  if (isAdminData !== true) {
    return jsonResponse(FORBIDDEN, 403);
  }

  // Service-role client — the only client that may call
  // admin_set_mining_config (GRANTed to service_role only). Every
  // validation/lock/deactivate/insert happens inside that RPC, not in
  // this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[admin-set-mining-config] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  const { data: rpcData, error: rpcError } = await admin
    .rpc("admin_set_mining_config", {
      p_admin_user_id: adminUserId,
      p_base_speed: baseSpeed.present ? baseSpeed.value : null,
      p_referral_speed_bonus: referralSpeedBonus.present ? referralSpeedBonus.value : null,
      p_boost_multiplier: boostMultiplier.present ? boostMultiplier.value : null,
      p_ad_boost_multiplier: adBoostMultiplier.present ? adBoostMultiplier.value : null,
      p_level_boost_percent: levelBoostPercent.present ? levelBoostPercent.value : null,
      p_level_up_cost_pxn: levelUpCostPxn.present ? levelUpCostPxn.value : null,
      p_max_offline_accrual_sec: maxOfflineAccrualSec.present ? maxOfflineAccrualSec.value : null,
    })
    .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_INVALID_INPUT:
        return jsonResponse({ success: false, message: "At least one config value must be provided" }, 400);
      case PG_ERR_OUT_OF_RANGE:
        return jsonResponse({ success: false, message: "One or more config values are out of range" }, 400);
      case PG_ERR_NO_ACTIVE_CONFIG:
        console.error("[admin-set-mining-config] no active mining_config row found");
        return jsonResponse({ success: false, message: "Could not update mining config" }, 500);
      default:
        console.error("[admin-set-mining-config] admin_set_mining_config RPC failed:", rpcError.message);
        return jsonResponse({ success: false, message: "Could not update mining config" }, 500);
    }
  }

  const row = rpcData as MiningConfigRow | null;
  if (!row) {
    console.error("[admin-set-mining-config] admin_set_mining_config RPC returned no row");
    return jsonResponse({ success: false, message: "Could not update mining config" }, 500);
  }

  return jsonResponse({ success: true, config: formatConfig(row) }, 200);
});
