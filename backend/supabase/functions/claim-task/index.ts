// Pro-X Network — "claim-task" Edge Function.
//
// POST /functions/v1/claim-task
//
// Server-authoritative Task Claim. This is the write path that
// rewards a player for completing a task from public.task_catalog
// (0035_task_catalog.sql — already read by the Tasks screen, see the
// player-side task READ migration). It replaces the old,
// client-only CLAIM behavior in index.html (state.tasksDone[id] =
// true, then adding the reward straight to the local balance with no
// server involvement at all) by delegating the entire lock / load
// task / not-found / inactive / already-claimed / verify /
// atomic-insert-and-credit / idempotency sequence to a single atomic
// SECURITY DEFINER Postgres function, public.claim_task (originally
// created by 0037_task_claims.sql, which itself calls
// public.adjust_claimed_total from 0030_mpxn_ledger_primitive.sql;
// its verification step was later updated by
// 0039_claim_task_requirement_verification.sql — see below). This
// file does NOT implement any of that logic itself, and does NOT
// modify index.html, admin.html, auth-telegram, claim-mining,
// level-up-mining, purchase-miner, upgrade-miner, set-miner-applied,
// accrue-mining, marketplace, marketplace-read, admin-task-catalog,
// or any existing migration.
//
// Verification (all of it happens inside public.claim_task, in the
// same transaction as the reward — this file never verifies
// anything itself):
//   - manual_claim: ALWAYS rejected with TASK_VERIFICATION_REQUIRED.
//     No automatic verification mechanism exists for this type, and
//     none may be faked — a task is never rewarded merely because
//     the client tapped CLAIM.
//   - referral_count / miner_level / claim_count: public.claim_task
//     compares the authenticated caller's live mining_state counter
//     (referral_count / level / claim_count) against that task's
//     task_catalog.requirement_value (0038_task_verification_
//     requirements.sql's column, read server-side inside the RPC —
//     never from the request body). Meets the threshold -> the
//     existing atomic insert-into-task_claims + adjust_claimed_total
//     credit proceeds; doesn't meet it -> TASK_VERIFICATION_REQUIRED,
//     no reward, no task_claims row. See
//     0039_claim_task_requirement_verification.sql for the exact
//     comparison logic and this repo's README for the full history
//     (0037 created the atomic claim machinery with every
//     verification_type hard-rejecting; 0038 added
//     requirement_value as schema-only; 0039 is the step that wired
//     the two together).
// This function simply surfaces whatever public.claim_task returns —
// it does not (and must not) duplicate any of the above verification
// itself, or grant a reward through any path other than that RPC.
//
// Request body — a single JSON object:
//   {
//     "task_id": <uuid string>,       // required
//     "request_id"?: <uuid string>    // optional idempotency key
//   }
//   - task_id is the ONLY way this function learns which task to
//     claim. It must be a syntactically valid UUID — anything else
//     (missing, wrong type, malformed) is rejected with 400
//     (INVALID_TASK_ID) before the database is touched. Whether that
//     task actually exists, is active, and is claimable is checked
//     server-side inside public.claim_task — never assumed here.
//   - request_id, if present, must be a syntactically valid UUID —
//     if malformed, rejected with 400 (INVALID_REQUEST_ID). If
//     absent, this function generates one with crypto.randomUUID(),
//     exactly like level-up-mining/index.ts does for its own
//     requestId — a client is never required to supply one. See
//     0037_task_claims.sql for what this idempotency key actually
//     protects against (a network-level retry of the same request —
//     NOT a second claim of the same task, which task_claims'
//     UNIQUE(user_id, task_id) always blocks regardless of
//     request_id).
//   - No other field in the request body is ever read. In
//     particular, there is no user_id, reward_mpxn, claimed_amount,
//     verification_type, or balance field accepted from the client —
//     even if the caller sends one, it is silently ignored. The only
//     source of identity is auth.getUser() below; the only source of
//     reward amount and verification_type is the task_catalog row
//     itself, read inside public.claim_task.
//
// Authentication: identical pattern to functions/level-up-mining,
// functions/me, functions/claim-mining, functions/purchase-miner,
// and functions/upgrade-miner — a per-request, caller-scoped
// supabase-js client (anon key + the caller's own
// `Authorization: Bearer <token>` access token) is used, and
// `auth.getUser()` is the sole source of the caller's identity.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — the ONLY user id ever used in this function, and the value
//     passed as p_user_id to the RPC. It is NEVER read from the
//     request body — a malicious client cannot claim a task on
//     another user's behalf by supplying a different user_id,
//     because no such field is ever consulted.
//   - This is the normal Supabase JWT/session mechanism. There is no
//     custom JWT/JWKS/private-JWK system anywhere in this file, and
//     SUPABASE_JWT_SECRET / PXN_JWT_SECRET are never read or
//     referenced.
//
// Database access:
//   - getSupabaseAdmin() (service-role client) is used ONLY to call
//     the public.claim_task RPC. It is never used to read or write
//     task_catalog, task_claims, mining_state, or mpxn_ledger
//     directly from this file — every one of those reads/locks/
//     writes happens inside the single atomic transaction of the
//     SECURITY DEFINER function itself.
//   - public.claim_task is GRANTed to service_role only (REVOKEd
//     from public/anon/authenticated — see 0037_task_claims.sql), so
//     only this Edge Function — never a client calling the PostgREST
//     RPC endpoint directly — can invoke it.
//
// Concurrency & idempotency: public.claim_task locks the target
// task_catalog row (SELECT ... FOR UPDATE) before checking it, relies
// on task_claims' own UNIQUE(user_id, task_id) to make a duplicate
// claim of the same task physically impossible regardless of
// request_id, and treats a repeated request_id as a no-op replay of
// an already-committed result rather than a new reward — see
// 0037_task_claims.sql and 0039_claim_task_requirement_verification.sql
// for the full guarantee. This file does not
// add any locking, verification, or deduplication logic of its own;
// it only passes task_id/request_id through and maps the RPC's
// result/error to an HTTP response.
//
// Response 200: { success: true, data: { task_id, claim_id,
//                 reward_mpxn, claimed_total, request_id } }
// Response 400: { success: false, error: { code, message } }
//   (INVALID_JSON / INVALID_BODY / INVALID_TASK_ID / INVALID_REQUEST_ID
//   / TASK_INACTIVE / TASK_VERIFICATION_REQUIRED)
// Response 401: { success: false, error: { code: "UNAUTHENTICATED", ... } }
// Response 404: { success: false, error: { code: "TASK_NOT_FOUND", ... } }
// Response 405: { success: false, error: { code: "METHOD_NOT_ALLOWED", ... } }
// Response 409: { success: false, error: { code: "TASK_ALREADY_CLAIMED", ... } }
// Response 500: { success: false, error: { code: "INTERNAL_ERROR", ... } }
//   (server misconfiguration, or a data-integrity anomaly the RPC
//   detected — see 0037_task_claims.sql's PXN29/PXN34)
//
// Never logs the access token, the service-role key, or any other
// secret. Database errors are never forwarded verbatim to the
// client — only a small set of recognized SQLSTATEs are mapped to
// specific messages; everything else becomes a generic 500.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

// ---------------------------------------------------------------------------
// Response helpers — same shape as admin-task-catalog/index.ts, per this
// step's required response format (success:{success,data} / error:
// {success,error:{code,message}}).
// ---------------------------------------------------------------------------

function successResponse(data: unknown, status = 200): Response {
  return jsonResponse({ success: true, data }, status);
}

function errorResponse(code: string, message: string, status: number): Response {
  return jsonResponse({ success: false, error: { code, message } }, status);
}

const ERR = {
  METHOD_NOT_ALLOWED: "METHOD_NOT_ALLOWED",
  UNAUTHENTICATED: "UNAUTHENTICATED",
  INVALID_JSON: "INVALID_JSON",
  INVALID_BODY: "INVALID_BODY",
  INVALID_TASK_ID: "INVALID_TASK_ID",
  INVALID_REQUEST_ID: "INVALID_REQUEST_ID",
  TASK_NOT_FOUND: "TASK_NOT_FOUND",
  TASK_INACTIVE: "TASK_INACTIVE",
  TASK_ALREADY_CLAIMED: "TASK_ALREADY_CLAIMED",
  TASK_VERIFICATION_REQUIRED: "TASK_VERIFICATION_REQUIRED",
  INTERNAL_ERROR: "INTERNAL_ERROR",
} as const;

// Custom SQLSTATEs raised by public.claim_task / public.adjust_claimed_total
// (see 0037_task_claims.sql, 0030_mpxn_ledger_primitive.sql). Mapped below to
// the HTTP status/error code that best reflects each failure mode. Continues
// the existing PXN01-PXN28 sequence (PXN24-26: adjust_claimed_total;
// PXN27-28: level_up_mining, not used here; PXN29-34: claim_task).
const PG_ERR_INVALID_INPUT = "PXN29"; // defense in depth only — should never trigger from a real request
const PG_ERR_TASK_NOT_FOUND = "PXN30";
const PG_ERR_TASK_INACTIVE = "PXN31";
const PG_ERR_TASK_ALREADY_CLAIMED = "PXN32";
const PG_ERR_VERIFICATION_REQUIRED = "PXN33";
const PG_ERR_DATA_INTEGRITY = "PXN34";
const PG_ERR_NO_MINING_STATE = "PXN25"; // shared with adjust_claimed_total; also raised directly by claim_task's own referral_count/miner_level/claim_count verification (0039) when the caller has no mining_state row at all
const PG_ERR_INSUFFICIENT_BALANCE = "PXN24"; // reused; cannot actually trigger for a positive reward credit
const PG_ERR_DUPLICATE = "PXN26"; // reused; the race-condition backstop behind TASK_ALREADY_CLAIMED

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

function isPlainObject(body: unknown): body is Record<string, unknown> {
  return typeof body === "object" && body !== null && !Array.isArray(body);
}

function isValidUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value.trim());
}

interface ClaimTaskRow {
  claim_id: string;
  task_id: string;
  reward_mpxn: number | string;
  claimed_total: number | string;
  request_id: string;
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse(ERR.METHOD_NOT_ALLOWED, "Method not allowed", 405);
  }

  // --- Authenticate the caller. This is the ONLY source of user_id used
  // anywhere below — never the request body. ---
  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return errorResponse(ERR.UNAUTHENTICATED, "Unauthorized", 401);
  }

  let publicEnv: { url: string; anonKey: string };
  try {
    publicEnv = getSupabasePublicEnv();
  } catch (err) {
    console.error(
      "[claim-task] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(ERR.INTERNAL_ERROR, "Service temporarily unavailable", 500);
  }

  // Per-request, caller-scoped client — used ONLY for the identity check
  // below, exactly like functions/level-up-mining, functions/me,
  // functions/claim-mining, functions/purchase-miner, and
  // functions/upgrade-miner. Never used for any database read or write in
  // this function.
  const userClient = createClient(publicEnv.url, publicEnv.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return errorResponse(ERR.UNAUTHENTICATED, "Unauthorized", 401);
  }
  const userId = authData.user.id;

  // --- Parse the request body. task_id is required; request_id is
  // optional. ---
  let parsedBody: unknown = null;
  const rawBody = await req.text();
  if (rawBody.trim().length > 0) {
    try {
      parsedBody = JSON.parse(rawBody);
    } catch {
      return errorResponse(ERR.INVALID_JSON, "Invalid request body", 400);
    }
  }

  if (!isPlainObject(parsedBody)) {
    return errorResponse(ERR.INVALID_BODY, "Request body must be a JSON object with a task_id", 400);
  }

  const rawTaskId = parsedBody.task_id;
  if (!isValidUuid(rawTaskId)) {
    return errorResponse(ERR.INVALID_TASK_ID, "task_id must be a valid UUID", 400);
  }
  const taskId = (rawTaskId as string).trim();

  const rawRequestId = parsedBody.request_id;
  let requestId: string;
  if (rawRequestId === undefined || rawRequestId === null) {
    // Server-generated fallback: a client is never required to supply its
    // own idempotency key — same pattern as level-up-mining/index.ts.
    requestId = crypto.randomUUID();
  } else if (isValidUuid(rawRequestId)) {
    requestId = (rawRequestId as string).trim();
  } else {
    return errorResponse(ERR.INVALID_REQUEST_ID, "request_id must be a valid UUID", 400);
  }

  // Service-role client — the only client that may call
  // public.claim_task (GRANTed to service_role only). Every row lock,
  // existence/active/already-claimed check, verification attempt, and
  // insert+credit happens inside that single RPC call, not in this file.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[claim-task] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(ERR.INTERNAL_ERROR, "Service temporarily unavailable", 500);
  }

  const { data: rpcData, error: rpcError } = await admin
    .rpc("claim_task", { p_user_id: userId, p_task_id: taskId, p_request_id: requestId })
    .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_TASK_NOT_FOUND:
        return errorResponse(ERR.TASK_NOT_FOUND, "This task no longer exists", 404);
      case PG_ERR_TASK_INACTIVE:
        return errorResponse(ERR.TASK_INACTIVE, "This task is not currently active", 400);
      case PG_ERR_TASK_ALREADY_CLAIMED:
      case PG_ERR_DUPLICATE:
        return errorResponse(
          ERR.TASK_ALREADY_CLAIMED,
          "This task has already been claimed",
          409,
        );
      case PG_ERR_VERIFICATION_REQUIRED:
        // See this file's header and 0039_claim_task_requirement_
        // verification.sql: manual_claim always lands here (no
        // automatic verification mechanism exists for it); referral_
        // count/miner_level/claim_count land here specifically when
        // the caller's mining_state counter hasn't yet reached that
        // task's task_catalog.requirement_value.
        return errorResponse(
          ERR.TASK_VERIFICATION_REQUIRED,
          "This task cannot be verified yet and has not been claimed",
          400,
        );
      case PG_ERR_NO_MINING_STATE:
        // Raised by claim_task itself for a referral_count/miner_level/
        // claim_count task when the caller has no mining_state row yet
        // (see 0039_claim_task_requirement_verification.sql) — a real,
        // if unusual, 404 rather than a server bug.
        return errorResponse(
          ERR.INTERNAL_ERROR,
          "No mining data found for this player",
          404,
        );
      case PG_ERR_INSUFFICIENT_BALANCE:
        // Cannot actually occur for a positive reward credit — mapped
        // for completeness/consistency only, same as level-up-mining
        // does for its own (differently-triggered) insufficient-balance
        // case.
        console.error("[claim-task] unexpected PXN24 from a positive reward credit");
        return errorResponse(ERR.INTERNAL_ERROR, "Could not process task claim", 500);
      case PG_ERR_INVALID_INPUT:
      case PG_ERR_DATA_INTEGRITY:
        console.error("[claim-task] claim_task RPC data/input error:", rpcError.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not process task claim", 500);
      default:
        // Never expose the raw database error message to the client.
        console.error("[claim-task] claim_task RPC failed:", rpcError.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not process task claim", 500);
    }
  }

  const row = rpcData as ClaimTaskRow | null;
  if (!row) {
    console.error("[claim-task] claim_task RPC returned no row");
    return errorResponse(ERR.INTERNAL_ERROR, "Could not process task claim", 500);
  }

  return successResponse(
    {
      task_id: row.task_id,
      claim_id: row.claim_id,
      reward_mpxn: Number(row.reward_mpxn),
      claimed_total: Number(row.claimed_total),
      request_id: requestId,
    },
    200,
  );
});
