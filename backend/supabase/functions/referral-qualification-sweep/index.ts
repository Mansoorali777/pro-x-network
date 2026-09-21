// Pro-X Network — "referral-qualification-sweep" Edge Function.
//
// POST /functions/v1/referral-qualification-sweep
//
// Internal service-to-service WORKER, not a player-facing endpoint.
// Per the FINAL LOCKED referral design (Design Revision v2, §4
// "QUALIFICATION SWEEP"), this function:
//   1. Verifies a trusted service-role caller (see AUTH below).
//   2. Calls public.get_and_lock_pending_referrals_batch(500)
//      (0047_get_and_lock_pending_referrals_batch.sql) to fetch up to
//      500 pending referrals whose cooldown has elapsed.
//   3. Calls public.qualify_referral(id)
//      (0046_qualify_and_flag_referral.sql) for each one, in order,
//      continuing to the next referral if any single call throws.
//   4. Returns a concise JSON summary of what happened.
//
// This function does NOT:
//   - qualify/flag anything itself — all of that logic lives entirely
//     in the two RPCs above, which this function only calls.
//   - award any m.PXN, miner, or other reward of any kind — no reward
//     tables/RPCs exist yet (referral_milestones, mpxn_ledger,
//     miner_catalog, mining_inventory are never touched here).
//   - write to any monthly-leaderboard/snapshot table — none exist
//     yet; public.qualify_referral() itself already documents exactly
//     where that integration will land in a later migration.
//   - schedule itself. No pg_cron/pg_net wiring is introduced by this
//     step — this function is invoked manually (e.g. via `supabase
//     functions invoke` or a signed curl request) for testing until a
//     later, separate step adds scheduling.
//   - modify auth-telegram, index.html, or admin.html.
//
// ------------------------------------------------------------------
// AUTH: a trusted, static service-role secret — no new JWT machinery.
// ------------------------------------------------------------------
// This project's existing Edge Functions authenticate a human caller
// via their own Supabase session JWT (see admin-get-mining-config,
// admin-set-mining-config, etc.: extract the caller's bearer token,
// resolve auth.getUser() with it, then call is_current_user_admin()
// AS that caller). That pattern does not fit here: there is no human
// session behind a scheduled/manual worker invocation, and per this
// step's explicit constraints, no new JWT signing, no
// SUPABASE_JWT_SECRET, and no PXN_JWT_SECRET may be introduced.
//
// Instead, this function reuses the ONE static secret this codebase's
// Edge Functions already have available for exactly this kind of
// server-to-server situation: SUPABASE_SERVICE_ROLE_KEY (already
// required by every Edge Function via
// _shared/env.ts:getSupabaseAdminEnv(), already platform-injected,
// already never sent to or usable by the frontend — see
// _shared/supabaseAdmin.ts's own header comment). The caller must
// present it as a normal bearer token:
//
//   Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>
//
// Two layers, both already-existing platform/codebase mechanisms,
// nothing new invented:
//   (a) Platform layer: config.toml sets verify_jwt = true for this
//       function (see the config.toml change accompanying this
//       migration), so Supabase's own gateway rejects any request
//       whose bearer token is not a validly-signed Supabase JWT
//       BEFORE this code even runs. The service-role key IS itself
//       such a JWT (signed by the project's existing, Supabase-
//       managed auth secret — this function never reads, verifies, or
//       otherwise touches that signing secret directly), so this
//       layer alone already blocks anonymous/garbage requests.
//   (b) Function layer (below): verify_jwt = true would also accept
//       an ORDINARY PLAYER's session JWT (also validly signed) — so
//       this function additionally checks, itself, that the presented
//       token is EXACTLY the service-role key (constant-time string
//       comparison), rejecting any other otherwise-valid JWT
//       (including a real player's or admin's own session token) with
//       403. Only whoever holds the service-role key — this backend's
//       own deployment tooling, and, in a later step, a pg_cron/pg_net
//       job configured with it — can ever successfully call this
//       function.
//
// This is deliberately the same shape a future pg_cron + pg_net
// schedule will use to invoke this function (a static Authorization
// header carrying the service-role key), so adding real scheduling
// later requires no change to this function's auth logic at all.

import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabaseAdminEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { ok: false, message: "Unauthorized" } as const;
const FORBIDDEN = { ok: false, message: "Forbidden" } as const;
const SERVICE_UNAVAILABLE = { ok: false, message: "Service temporarily unavailable" } as const;
const METHOD_NOT_ALLOWED = { ok: false, message: "Method not allowed" } as const;

const MAX_BATCH_SIZE = 500;

interface PendingReferralRow {
  id: string;
  referrer_user_id: string;
  referred_user_id: string;
  qualification_eligible_at: string;
  created_at: string;
}

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

/**
 * Constant-time string comparison, local to this function only (not
 * exported from/added to _shared/telegram.ts, which already has its
 * own private equivalent for HMAC comparison — this migration does
 * not modify any existing Edge Function or shared module).
 */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse(METHOD_NOT_ALLOWED, 405);
  }

  const presentedToken = extractBearerToken(req);
  if (!presentedToken) {
    return jsonResponse(UNAUTHORIZED, 401);
  }

  let serviceRoleKey: string;
  try {
    ({ serviceRoleKey } = getSupabaseAdminEnv());
  } catch (err) {
    console.error(
      "[referral-qualification-sweep] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  // The presented bearer token must be EXACTLY the service-role key —
  // see the AUTH header comment above for why this second check is
  // necessary even with verify_jwt = true at the platform layer.
  if (!timingSafeEqual(presentedToken, serviceRoleKey)) {
    return jsonResponse(FORBIDDEN, 403);
  }

  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[referral-qualification-sweep] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  // ------------------------------------------------------------
  // 1. Fetch (and, for the duration of this one RPC call's own
  //    short transaction, lock) a batch of ready pending referrals.
  //    See 0047's own header comment for exactly what this lock does
  //    and does not guarantee once this call returns.
  // ------------------------------------------------------------
  const { data: batchData, error: batchError } = await admin.rpc(
    "get_and_lock_pending_referrals_batch",
    { p_batch_size: MAX_BATCH_SIZE },
  );

  if (batchError) {
    console.error(
      "[referral-qualification-sweep] get_and_lock_pending_referrals_batch failed:",
      batchError.message,
    );
    return jsonResponse({ ok: false, message: "Could not fetch pending referrals" }, 500);
  }

  const referrals = (batchData ?? []) as PendingReferralRow[];
  const fetched = referrals.length;

  let qualified = 0;
  let flagged = 0;
  let notQualified = 0;
  let failed = 0;

  // Referral ids that came back false from qualify_referral() — used
  // below for a single bulk follow-up read to split "flagged" out
  // from the rest of "not qualified" for reporting purposes only.
  // qualify_referral() itself returns a plain boolean (true =
  // qualified, false = anything else, including flagged) — see
  // 0046_qualify_and_flag_referral.sql — so distinguishing "flagged"
  // for this summary requires this one extra, batched read; it never
  // changes any data.
  const falseIds: string[] = [];

  // ------------------------------------------------------------
  // 2. Qualify one referral at a time. Each call is its own
  //    independent transaction (see 0047's header comment on why the
  //    batch-fetch lock above cannot and does not need to carry over
  //    into these calls) — qualify_referral() re-locks and rechecks
  //    the row itself before doing anything. A thrown error on one
  //    referral is caught and counted, and processing continues with
  //    the rest of the batch — one bad referral must never abort the
  //    whole sweep.
  // ------------------------------------------------------------
  for (const referral of referrals) {
    try {
      const { data: qualifyResult, error: qualifyError } = await admin.rpc(
        "qualify_referral",
        { p_referral_id: referral.id },
      );

      if (qualifyError) {
        failed++;
        console.error(
          `[referral-qualification-sweep] qualify_referral failed for referral ${referral.id}:`,
          qualifyError.message,
        );
        continue;
      }

      if (qualifyResult === true) {
        qualified++;
      } else {
        notQualified++;
        falseIds.push(referral.id);
      }
    } catch (err) {
      failed++;
      console.error(
        `[referral-qualification-sweep] unexpected error qualifying referral ${referral.id}:`,
        err instanceof Error ? err.message : "unknown error",
      );
    }
  }

  // ------------------------------------------------------------
  // 3. Split "flagged" out of "not qualified", purely for a more
  //    informative summary during manual testing (no data is changed
  //    by this step). Best-effort only: if this follow-up read itself
  //    fails, the affected referrals simply stay counted as
  //    not_qualified rather than flagged — the sweep's real work
  //    (step 2) is already complete and correct regardless.
  // ------------------------------------------------------------
  if (falseIds.length > 0) {
    const { data: statusRows, error: statusError } = await admin
      .from("referrals")
      .select("id, status")
      .in("id", falseIds);

    if (statusError) {
      console.error(
        "[referral-qualification-sweep] follow-up status read failed (counts still valid, flagged/not_qualified split may be approximate):",
        statusError.message,
      );
    } else {
      const flaggedIds = new Set(
        (statusRows ?? [])
          .filter((row: { id: string; status: string }) => row.status === "flagged")
          .map((row: { id: string; status: string }) => row.id),
      );
      flagged = flaggedIds.size;
      notQualified = falseIds.length - flagged;
    }
  }

  return jsonResponse(
    {
      ok: true,
      fetched,
      qualified,
      flagged,
      not_qualified: notQualified,
      failed,
    },
    200,
  );
});
