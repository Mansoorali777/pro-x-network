// Pro-X Network — "accrue-mining" Edge Function.
//
// POST /functions/v1/accrue-mining
//
// Server-side mining accrual, now covering the same rate inputs as
// the frontend's currentSpeed() EXCEPT the tap boost (intentionally
// client/session-only, never moved server-side). It does NOT
// implement claim, level-up, or miner purchase — those remain later,
// explicitly-scoped steps. It does NOT implement or modify miner
// apply/remove — that stays exclusively in set-miner-applied/index.ts
// and its public.set_miner_applied() RPC (see 0018_secure_miner_apply_remove.sql);
// this function only ever READS is_applied, never writes it. It does
// NOT implement admin mining-speed control — that stays exclusively
// in admin-set-mining-speed/index.ts and its
// public.admin_set_mining_speed() / admin_clear_mining_speed_override()
// RPCs (see 0020_admin_mining_speed_control.sql); this function only
// ever READS admin_speed_override, never writes it. It reads:
//   - public.mining_config (base_speed, referral_speed_bonus,
//     boost_multiplier, ad_boost_multiplier, max_offline_accrual_sec,
//     level_boost_percent) — the same values already documented in
//     0003_mining_config.sql as copied verbatim from the live
//     client's REWARDS_CONFIG / DEFAULT_BASE_SPEED.
//   - the caller's own public.mining_inventory rows where
//     is_applied = true (miner_speed only — see "applied miner speed"
//     below). Strictly read-only: no insert/update/delete of any kind
//     on this table, on this or any other row.
//   - the caller's own public.mining_state row (level, referral_count,
//     boost_until, ad_boost_until, mined_balance_total, pending_claim,
//     last_accrued_at, accrual_lock_version, admin_speed_override).
//
// Formula (mirrors index.html's currentSpeed(), minus tap boost):
//   IF admin_speed_override IS NOT NULL (see
//   0020_admin_mining_speed_control.sql):
//     rate = admin_speed_override  — used AS the final rate, verbatim.
//     Bypasses base_speed, appliedMinerSpeed, referral bonus, the
//     level multiplier, and BOTH the normal and ad boost multipliers.
//     Predictable by design: whatever the admin set is exactly what
//     accrues, nothing else compounds on top of it. (Tap boost was
//     already excluded from server-side accrual before this existed,
//     and remains excluded from the override too.)
//   ELSE (the default — admin_speed_override IS NULL, unchanged from
//   before this column existed):
//     appliedMinerSpeed = SUM(miner_speed) over this player's own
//                         mining_inventory rows where is_applied = true
//     base = base_speed + appliedMinerSpeed + referral_count * referral_speed_bonus
//     rate = base * levelBoostMultiplier(level, level_boost_percent)
//     if boost_until    > now: rate *= boost_multiplier
//     if ad_boost_until > now: rate *= ad_boost_multiplier
//
// admin_speed_override is read fresh from this player's own
// mining_state row on every call, exactly like level/referral_count/
// boost_until/ad_boost_until below — never from the request body,
// and this file never writes it (see admin-set-mining-speed/index.ts
// for the only place it's written).
//
// Applied miner speed: computed fresh from public.mining_inventory on
// every call (SUM of miner_speed for this user's is_applied = true
// rows), NEVER from the request body, frontend/localStorage, or any
// cached value — mirroring how referral_count/boost_until/
// ad_boost_until are read only from this player's own mining_state
// row. Whether a given inventory row counts is controlled exclusively
// by set-miner-applied's is_applied column; this file never flips
// that flag itself. (Skipped entirely when admin_speed_override is
// set — see formula above.)
//
// referral_count, boost_until, and ad_boost_until are read ONLY from
// this player's own mining_state row (never from the request body —
// see extractBearerToken/auth.getUser() below for the only accepted
// caller input, which is the bearer token).
//
// Authentication: identical pattern to functions/me — a per-request,
// caller-scoped client (anon key + the caller's own access token) is
// used ONLY to call auth.getUser(), which is the sole source of the
// caller's identity. No user id is ever accepted from the request
// body, no JWT is decoded manually, and no custom JWT is minted here.
//
// Writes: performed with the service-role client (the only client in
// this file with database write access), because mining_state has no
// client-writable RLS policy — by design (see 0013_mining_state.sql,
// "mining_state_select_own" is SELECT-only for `authenticated`).
// mining_config similarly has zero client-facing policies, so it is
// also read with the service-role client.
//
// Concurrency: see the comment above the accrual loop below for why
// this is safe without SELECT ... FOR UPDATE, a stored procedure, or
// a new migration.
//
// Response 200: { success, user_id, elapsed_seconds, applied_seconds,
//                 mining_rate, accrued_amount, mining_state }
// Response 401: unauthenticated
// Response 405: method not allowed
// Response 409: could not apply accrual after retrying a genuine
//               concurrent-write conflict (rare; caller may just
//               call again)
// Response 500: server misconfiguration or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;

// How many times to retry the compare-and-swap update below if a
// genuinely concurrent request wins the race first. 3 is generous
// for a single-user double-tap/double-request scenario without
// looping indefinitely under real contention.
const MAX_CAS_ATTEMPTS = 3;

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

interface MiningConfigRow {
  base_speed: number;
  max_offline_accrual_sec: number;
  level_boost_percent: number;
  referral_speed_bonus: number;
  boost_multiplier: number;
  ad_boost_multiplier: number;
}

interface MiningInventoryRow {
  miner_speed: number | string;
}

interface MiningStateRow {
  user_id: string;
  mined_balance_total: number;
  pending_claim: number;
  claimed_total: number;
  pxn_balance: number;
  level: number;
  claim_count: number;
  boost_until: string | null;
  ad_boost_until: string | null;
  ads_watched_in_window: number;
  ads_window_started_at: string | null;
  last_accrued_at: string;
  referral_count: number;
  accrual_lock_version: number;
  admin_speed_override: number | string | null;
  created_at: string;
  updated_at: string;
}

/**
 * levelBoostPercent (mining_config.level_boost_percent) is stored as
 * a DECIMAL multiplier, not a percentage — e.g. 0.05 means "+5% per
 * level above 1", so it must be used directly, NOT divided by 100.
 * (0003_mining_config.sql: "stored as a fraction, matching current
 * usage.") Formula: 1 + (level - 1) * levelBoostPercent — e.g.
 * level 1 = 1.0, level 2 = 1.05, level 3 = 1.10 for 0.05.
 */
function levelBoostMultiplier(level: number, levelBoostPercent: number): number {
  const effectiveLevel = Math.max(1, level);
  return 1 + (effectiveLevel - 1) * levelBoostPercent;
}

/**
 * Full server-side mining rate, mirroring index.html's currentSpeed()
 * with one deliberate exclusion (see file header): no tap-boost
 * multiplier (stays client/session-only by design).
 *
 * If adminSpeedOverride is non-null (see
 * 0020_admin_mining_speed_control.sql), it is returned directly as
 * the final rate — every other parameter below is ignored for that
 * call, including the level multiplier and both boost multipliers.
 *
 * Every input here is read from the player's OWN mining_inventory
 * rows (appliedMinerSpeed) or mining_state row (referralCount,
 * boostUntil, adBoostUntil, adminSpeedOverride), or from the server's
 * active mining_config row — never from the request body, and
 * boostUntil/adBoostUntil are compared against the server's own
 * `now`, never a client-supplied timestamp.
 */
function computeMiningRate(
  config: MiningConfigRow,
  appliedMinerSpeed: number,
  level: number,
  referralCount: number,
  boostUntil: string | null,
  adBoostUntil: string | null,
  now: Date,
  adminSpeedOverride: number | null,
): number {
  if (adminSpeedOverride !== null) {
    return adminSpeedOverride;
  }

  const base = config.base_speed + appliedMinerSpeed + referralCount * config.referral_speed_bonus;
  let rate = base * levelBoostMultiplier(level, config.level_boost_percent);

  if (boostUntil && new Date(boostUntil).getTime() > now.getTime()) {
    rate *= config.boost_multiplier;
  }
  if (adBoostUntil && new Date(adBoostUntil).getTime() > now.getTime()) {
    rate *= config.ad_boost_multiplier;
  }

  return rate;
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
      "[accrue-mining] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the identity
  // check below, exactly like functions/me. Never used for any
  // database read or write in this function.
  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }
  const userId = authData.user.id;

  // Service-role client — the only client with write access to
  // mining_state and read access to mining_config (both tables have
  // zero client-facing RLS policies by design).
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[accrue-mining] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // --- Load the active mining configuration. ---
  const { data: configData, error: configError } = await admin
    .from("mining_config")
    .select(
      "base_speed, max_offline_accrual_sec, level_boost_percent, referral_speed_bonus, boost_multiplier, ad_boost_multiplier",
    )
    .eq("is_active", true)
    .maybeSingle();
  const config = configData as MiningConfigRow | null;

  if (configError || !config) {
    console.error(
      "[accrue-mining] failed to load active mining_config:",
      configError?.message ?? "no active row",
    );
    return jsonResponse({ success: false, message: "Could not load mining configuration" }, 500);
  }

  // --- Load this player's applied miner speed. ---
  // Read-only SUM over public.mining_inventory for this caller's own
  // is_applied = true rows (mining_inventory_user_id_is_applied_idx,
  // see 0014_mining_inventory.sql, covers this exact filter). Uses
  // the same service-role client as mining_config/mining_state above
  // — this table's RLS only grants SELECT to `authenticated` for
  // their own rows, which the explicit .eq("user_id", ...) filter
  // below already mirrors as defense in depth. No row in this table
  // is ever inserted, updated, or deleted from this file — is_applied
  // is set exclusively by set-miner-applied/index.ts.
  const { data: appliedInventoryData, error: inventoryError } = await admin
    .from("mining_inventory")
    .select("miner_speed")
    .eq("user_id", userId)
    .eq("is_applied", true);

  if (inventoryError) {
    console.error(
      "[accrue-mining] failed to load applied mining_inventory:",
      inventoryError.message,
    );
    return jsonResponse({ success: false, message: "Could not load mining inventory" }, 500);
  }

  const appliedMinerSpeed = ((appliedInventoryData ?? []) as MiningInventoryRow[]).reduce(
    (sum, row) => sum + Number(row.miner_speed),
    0,
  );

  // --- Load (or create) this player's mining_state row. ---
  const { data: existingStateData, error: selectError } = await admin
    .from("mining_state")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle();

  if (selectError) {
    console.error("[accrue-mining] failed to load mining_state:", selectError.message);
    return jsonResponse({ success: false, message: "Could not load mining state" }, 500);
  }

  let stateRow: MiningStateRow | null = existingStateData as MiningStateRow | null;

  if (!stateRow) {
    // First accrual call for this player. Insert relies entirely on
    // the column defaults declared in 0013_mining_state.sql — only
    // user_id (the authenticated identity from auth.getUser() above)
    // is specified. Nothing is imported from localStorage here.
    const { data: createdData, error: insertError } = await admin
      .from("mining_state")
      .insert({ user_id: userId })
      .select("*")
      .single();

    if (insertError) {
      // 23505 = unique_violation: a concurrent request for the same
      // player already created this row first. Expected under
      // concurrency, not a real error — fall through and re-read it.
      if (insertError.code !== "23505") {
        console.error("[accrue-mining] failed to create mining_state:", insertError.message);
        return jsonResponse({ success: false, message: "Could not initialize mining state" }, 500);
      }
      const { data: raceStateData, error: raceError } = await admin
        .from("mining_state")
        .select("*")
        .eq("user_id", userId)
        .maybeSingle();
      const raceState = raceStateData as MiningStateRow | null;
      if (raceError || !raceState) {
        console.error(
          "[accrue-mining] failed to load mining_state after insert race:",
          raceError?.message ?? "row still missing",
        );
        return jsonResponse({ success: false, message: "Could not load mining state" }, 500);
      }
      stateRow = raceState;
    } else {
      stateRow = createdData as MiningStateRow;
    }
  }

  if (!stateRow) {
    // Should be unreachable given the branches above.
    console.error("[accrue-mining] no mining_state row after load/create — should be unreachable");
    return jsonResponse({ success: false, message: "Could not load mining state" }, 500);
  }

  // --- Compute and apply accrual with optimistic concurrency control. ---
  //
  // Why this is safe WITHOUT SELECT ... FOR UPDATE, a stored
  // procedure, or a new migration:
  //
  // A single UPDATE statement is atomic by itself in Postgres. Each
  // attempt below issues exactly one UPDATE whose WHERE clause pins
  // BOTH user_id and the exact accrual_lock_version this attempt
  // read. If a concurrent request's UPDATE for the same row commits
  // first, this row's accrual_lock_version has already moved past
  // what we read, so our WHERE clause matches zero rows — Postgres
  // reports that via the (empty) result set, we detect it below, and
  // we retry from a FRESH read rather than assuming our stale numbers
  // still apply (i.e. we never blindly re-add the same delta twice).
  // This is the standard optimistic-concurrency-control pattern and
  // is what accrual_lock_version's own doc comment in
  // 0013_mining_state.sql describes it as being for — it is only
  // "not sufficient by itself" if a request updates unconditionally
  // and merely increments the counter; conditioning the WHERE clause
  // on the version, as done here, is what makes it sufficient.
  let attempt = 0;
  let outcome: {
    elapsedSeconds: number;
    appliedSeconds: number;
    miningRate: number;
    accruedAmount: number;
    updatedRow: MiningStateRow;
  } | null = null;

  let workingState = stateRow;

  while (attempt < MAX_CAS_ATTEMPTS && !outcome) {
    attempt += 1;

    const now = new Date();
    const lastAccruedAt = new Date(workingState.last_accrued_at);
    // Clamp negative elapsed time (e.g. clock skew) to 0 rather than
    // ever subtracting from a balance.
    const elapsedSeconds = Math.max(0, (now.getTime() - lastAccruedAt.getTime()) / 1000);
    const appliedSeconds = Math.min(elapsedSeconds, config.max_offline_accrual_sec);

    const adminSpeedOverride =
      workingState.admin_speed_override === null || workingState.admin_speed_override === undefined
        ? null
        : Number(workingState.admin_speed_override);

    const miningRate = computeMiningRate(
      config,
      appliedMinerSpeed,
      workingState.level,
      workingState.referral_count,
      workingState.boost_until,
      workingState.ad_boost_until,
      now,
      adminSpeedOverride,
    );
    const accruedAmount = miningRate * appliedSeconds;

    const newMinedBalance = Number(workingState.mined_balance_total) + accruedAmount;
    const newPendingClaim = Number(workingState.pending_claim) + accruedAmount;
    const expectedVersion = workingState.accrual_lock_version;

    const { data: updatedData, error: updateError } = await admin
      .from("mining_state")
      .update({
        mined_balance_total: newMinedBalance,
        pending_claim: newPendingClaim,
        last_accrued_at: now.toISOString(),
        accrual_lock_version: expectedVersion + 1,
      })
      .eq("user_id", userId)
      .eq("accrual_lock_version", expectedVersion)
      .select("*")
      .maybeSingle();
    const updated = updatedData as MiningStateRow | null;

    if (updateError) {
      console.error("[accrue-mining] update failed:", updateError.message);
      return jsonResponse({ success: false, message: "Could not save accrual" }, 500);
    }

    if (updated) {
      outcome = { elapsedSeconds, appliedSeconds, miningRate, accruedAmount, updatedRow: updated };
      break;
    }

    // Zero rows matched: accrual_lock_version moved under us. Re-read
    // the current row and retry the whole computation against that
    // fresh baseline on the next loop iteration.
    const { data: refreshedData, error: refreshError } = await admin
      .from("mining_state")
      .select("*")
      .eq("user_id", userId)
      .maybeSingle();
    const refreshed = refreshedData as MiningStateRow | null;

    if (refreshError || !refreshed) {
      console.error(
        "[accrue-mining] failed to re-read mining_state after a concurrent-write conflict:",
        refreshError?.message ?? "row missing",
      );
      return jsonResponse({ success: false, message: "Could not save accrual" }, 500);
    }
    workingState = refreshed;
  }

  if (!outcome) {
    console.warn(
      `[accrue-mining] gave up after ${MAX_CAS_ATTEMPTS} concurrent-write conflicts user_id=${userId}`,
    );
    return jsonResponse(
      { success: false, message: "Too many concurrent requests — please try again." },
      409,
    );
  }

  return jsonResponse({
    success: true,
    user_id: userId,
    elapsed_seconds: outcome.elapsedSeconds,
    applied_seconds: outcome.appliedSeconds,
    mining_rate: outcome.miningRate,
    accrued_amount: outcome.accruedAmount,
    mining_state: outcome.updatedRow,
  });
});
