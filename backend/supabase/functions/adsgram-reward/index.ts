// Pro-X Network — "adsgram-reward" Edge Function.
//
// POST /functions/v1/adsgram-reward
// Body (optional): { "request_id": "<uuid>" }
//
// Called by the Telegram Mini App AFTER AdsGram's onReward callback
// fires — i.e. after a rewarded ad has actually been watched to
// completion. This function does NOT talk to AdsGram's API: AdsGram's
// own SDK confirms the ad was watched; this function's job is to turn
// that confirmation into an atomic, server-authoritative accrual + ad
// boost, and to record an audit row.
//
// Trust boundary: this function trusts that AdsGram's client-side
// onReward callback accurately signals "ad watched" — there is no
// server-to-server webhook for this flow (AdsGram does not offer one),
// which is the SAME trust model already used by every other
// client-triggered action in this project (manual_claim task reward,
// tap boosts, etc.). What this function DOES guarantee is that the
// resulting credit is atomic and server-authoritative: it is applied
// via public.prepare_ad_reward(), which enforces the 10-ads-per-24h
// limit and the 10th-ad-boost activation entirely server-side, in one
// transaction, regardless of what the client claims or how many times
// it calls.
//
// Credit path — exactly one RPC:
//   public.prepare_ad_reward(p_user_id uuid) [p_now defaults to now()]
// That RPC atomically:
//   a. accrues elapsed time at the current mining rate into
//      mined_balance_total / pending_claim, and stamps
//      last_accrued_at = now — i.e. the boost earned by this ad does
//      NOT retroactively apply to elapsed time;
//   b. rolls the 24h ad window forward if it has expired;
//   c. raises AD_LIMIT_REACHED if ads_watched_in_window >= 10;
//   d. increments ads_watched_in_window;
//   e. on the 10th ad of the window, sets ad_boost_until = now + 8h;
//   f. bumps accrual_lock_version.
// This function does NOT duplicate any of that logic — it only calls
// the RPC and maps the outcome to an HTTP response.
//
// Idempotency (request_id): if the client supplies a `request_id`
// (recommended — generate one per "watch ad" attempt, keep it stable
// across retries of the same attempt), this function first checks
// public.ad_reward_claims for a matching
// (user_id, provider='adsgram', metadata->>'request_id') row. If one
// exists, the original result is replayed without calling the RPC
// again — so a lost response + client retry cannot double-credit.
// If no request_id is supplied, this protection is skipped and the
// RPC is called unconditionally.
//
// Audit: after a successful RPC, this function inserts one row into
// public.ad_reward_claims (user_id, provider='adsgram',
// provider_user_id=<telegram_user_id if known>, reward_type=
// 'mining_boost', status='credited', metadata=<RPC result + request_id>).
// That table is a pure audit log — it is NOT the source of truth for
// the balance; mining_state is. A failure to insert there is logged
// and otherwise ignored: the reward is already committed by the RPC,
// and returning an error now would incorrectly tell the client the
// ad was not credited.
//
// Authentication: identical pattern to accrue-mining / claim-mining /
// me — a per-request, caller-scoped supabase-js client (anon key +
// the caller's own `Authorization: Bearer <token>` access token) is
// used ONLY to call auth.getUser(), which is the sole source of the
// caller's identity. No user id is ever accepted from the request
// body, no JWT is decoded manually, no custom JWT is minted.
//
// Response 200: the RPC's own JSONB result
//   { success, ads_watched, ads_remaining, accrued_amount,
//     mining_rate_before_reward, boost_activated, ad_boost_until }
//   (plus { replayed: true } when served from the idempotency cache)
// Response 400: invalid body (malformed JSON, or non-UUID request_id)
// Response 401: unauthenticated (missing/invalid bearer token)
// Response 404: no mining_state row for this user (caller must hit
//               accrue-mining first, i.e. open the app normally)
// Response 405: method not allowed
// Response 429: daily ad limit reached (AD_LIMIT_REACHED)
// Response 500: server misconfiguration or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isValidUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value.trim());
}

/**
 * Shape returned by public.prepare_ad_reward(). Kept loose (numbers as
 * number | string) because Postgres numeric comes back as a string in
 * some supabase-js configurations.
 */
interface PrepareAdRewardResult {
  success: boolean;
  ads_watched: number;
  ads_remaining: number;
  accrued_amount: number | string;
  mining_rate_before_reward: number | string;
  boost_activated: boolean;
  ad_boost_until: string | null;
}

/**
 * Reads the optional JSON body. Returns:
 *   { ok: true, requestId }   on success (requestId may be null)
 *   { ok: false }             if the body is present but malformed
 * A completely empty body is valid (request_id is optional).
 */
async function parseOptionalBody(
  req: Request,
): Promise<{ ok: true; requestId: string | null } | { ok: false }> {
  const raw = await req.text();
  if (raw.trim().length === 0) {
    return { ok: true, requestId: null };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: false };
  }
  const rawRequestId = (parsed as Record<string, unknown>).request_id;
  if (rawRequestId === undefined || rawRequestId === null) {
    return { ok: true, requestId: null };
  }
  if (!isValidUuid(rawRequestId)) {
    return { ok: false };
  }
  return { ok: true, requestId: (rawRequestId as string).trim() };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ success: false, message: "Method not allowed" }, 405);
  }

  // --- Optional body: { request_id?: uuid } ---
  const bodyResult = await parseOptionalBody(req);
  if (!bodyResult.ok) {
    return jsonResponse(
      { success: false, message: "Invalid request body (request_id must be a UUID if supplied)" },
      400,
    );
  }
  const requestId = bodyResult.requestId;

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return jsonResponse({ success: false, message: "Unauthorized" }, 401);
  }

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[adsgram-reward] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request, caller-scoped client — used ONLY for the identity
  // check below, exactly like accrue-mining / claim-mining / me.
  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse({ success: false, message: "Unauthorized" }, 401);
  }
  const userId = authData.user.id;

  // Service-role client — the only client with write access to
  // mining_state / ad_reward_claims (both have zero client-facing
  // write policies by design).
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[adsgram-reward] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // --- Idempotency fast path (only if the client supplied a request_id). ---
  // Looks up a previous successful credit for this exact (user, request_id)
  // pair in the audit log and replays its result without calling the RPC.
  if (requestId) {
    const { data: existing, error: existingError } = await admin
      .from("ad_reward_claims")
      .select("metadata")
      .eq("user_id", userId)
      .eq("provider", "adsgram")
      .eq("status", "credited")
      .filter("metadata->>request_id", "eq", requestId)
      .limit(1)
      .maybeSingle();

    if (existingError) {
      // Do NOT fail the request just because the idempotency check
      // itself had a transient problem — fall through to the RPC, whose
      // own atomicity still protects the balance against a same-window
      // race. This is a deliberate fail-open on the *check*, not on the
      // *credit*: the credit is always guarded by the RPC.
      console.warn(
        "[adsgram-reward] idempotency lookup failed (continuing):",
        existingError.message,
      );
    } else if (existing?.metadata) {
      const meta = existing.metadata as Partial<PrepareAdRewardResult> & {
        request_id?: string;
      };
      console.log(
        `[adsgram-reward] replaying cached result user_id=${userId} request_id=${requestId}`,
      );
      return jsonResponse(
        {
          success: true,
          ads_watched: meta.ads_watched ?? null,
          ads_remaining: meta.ads_remaining ?? null,
          accrued_amount: meta.accrued_amount ?? 0,
          mining_rate_before_reward: meta.mining_rate_before_reward ?? 0,
          boost_activated: meta.boost_activated ?? false,
          ad_boost_until: meta.ad_boost_until ?? null,
          replayed: true,
        },
        200,
      );
    }
  }

  // --- The single atomic credit. ---
  const { data: rpcData, error: rpcError } = await admin.rpc("prepare_ad_reward", {
    p_user_id: userId,
  });

  if (rpcError) {
    // public.prepare_ad_reward raises bare `raise exception '<CODE>';`
    // with no custom SQLSTATE, so branch on the message text.
    const msg = rpcError.message ?? "";

    if (msg.includes("MINING_STATE_NOT_FOUND")) {
      // The player has no mining_state row yet. In normal flow this
      // endpoint is only called after the Mini App has already hit
      // accrue-mining at least once (which creates that row), so this
      // is a caller-contract violation, not a server fault.
      console.warn(`[adsgram-reward] no mining_state row user_id=${userId}`);
      return jsonResponse(
        { success: false, message: "Mining state not initialized — open the app first" },
        404,
      );
    }

    if (msg.includes("MINING_CONFIG_NOT_FOUND")) {
      console.error("[adsgram-reward] no active mining_config row");
      return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
    }

    if (msg.includes("AD_LIMIT_REACHED")) {
      return jsonResponse(
        {
          success: false,
          message: "Daily ad limit reached. Your 24-hour window will reset automatically.",
        },
        429,
      );
    }

    console.error("[adsgram-reward] prepare_ad_reward failed:", msg);
    return jsonResponse({ success: false, message: "Could not process ad reward" }, 500);
  }

  const result = rpcData as PrepareAdRewardResult | null;
  if (!result || result.success !== true) {
    console.error("[adsgram-reward] prepare_ad_reward returned no usable row");
    return jsonResponse({ success: false, message: "Could not process ad reward" }, 500);
  }

  // --- Best-effort audit row. Never fails the response. ---
  try {
    const { data: usersRow } = await admin
      .from("users")
      .select("telegram_user_id")
      .eq("id", userId)
      .maybeSingle();

    const providerUserId =
      usersRow && typeof usersRow.telegram_user_id === "number"
        ? usersRow.telegram_user_id
        : null;

    const { error: auditError } = await admin.from("ad_reward_claims").insert({
      user_id: userId,
      provider: "adsgram",
      provider_user_id: providerUserId,
      reward_type: "mining_boost",
      status: "credited",
      metadata: {
        request_id: requestId,
        ads_watched: result.ads_watched,
        ads_remaining: result.ads_remaining,
        accrued_amount: result.accrued_amount,
        mining_rate_before_reward: result.mining_rate_before_reward,
        boost_activated: result.boost_activated,
        ad_boost_until: result.ad_boost_until,
      },
    });

    if (auditError) {
      console.warn(
        "[adsgram-reward] audit insert failed (non-fatal):",
        auditError.message,
      );
    }
  } catch (err) {
    console.warn(
      "[adsgram-reward] audit insert threw (non-fatal):",
      err instanceof Error ? err.message : "unknown error",
    );
  }

  return jsonResponse(result, 200);
});