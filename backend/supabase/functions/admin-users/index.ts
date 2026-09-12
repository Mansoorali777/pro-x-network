// Pro-X Network — "admin-users" Edge Function.
//
// POST /functions/v1/admin-users
//
// Admin-only, READ-ONLY endpoint with two actions:
//
//   List:   { "action": "list", "search"?: "<text>" }
//   Detail: { "action": "get", "userId": "<uuid>" }
//
// action defaults to "list" if omitted, so the original
// `{}`-body call this function originally shipped with keeps working
// unchanged (no search filter applied).
//
// "list" lets an admin view every player's identity fields (from
// public.users) alongside their EXACT, database-authoritative PXN
// balance (public.mining_state.pxn_balance), optionally filtered by a
// case-insensitive match against Telegram ID / username / first name
// / last name — filtered IN THE DATABASE QUERY (a Postgres
// ILIKE/eq filter via the service-role client below), not by fetching
// every row and filtering in this file or in the browser.
//
// "get" additionally returns one player's full balance/progression
// snapshot (pxn_balance, mined_balance_total, pending_claim,
// claimed_total, level) and their owned miner units
// (public.mining_inventory).
//
// This function does NOT write, reset, or adjust any balance, level,
// or miner data — every query below is a SELECT. It does NOT touch
// mining_config, referrals, purchase/upgrade logic, or any other
// table, does NOT introduce any custom JWT/JWT secret, and does NOT
// change admin-set-mining-speed, admin-miner-catalog,
// admin-miner-upgrade-cost, upgrade-miner, purchase-miner,
// accrue-mining, or any existing RLS policy/RPC/migration.
//
// Authentication & authorization — UNCHANGED from the original
// version of this file, and identical to admin-set-mining-speed /
// admin-miner-catalog (see those files):
//   - The request body is parsed and validated FIRST (action/search/
//     userId shape only) — before any auth or database call — so a
//     malformed request never reaches the database, same ordering
//     admin-set-mining-speed uses.
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
//     anything other than exactly `true`: 403. This is the ONLY
//     authorization check in this file — the "get" action's `userId`
//     identifies the TARGET player being looked up, exactly like
//     admin-set-mining-speed's own `userId`, and is never itself
//     trusted as proof of anything; it is used solely to select rows
//     after the caller has already been confirmed to be an admin.
//   - Only after BOTH checks pass is the service-role client used, to
//     read public.users / public.mining_state / public.mining_inventory.
//     SUPABASE_SERVICE_ROLE_KEY is read only from Deno.env (Supabase
//     secrets, via _shared/env.ts -> _shared/supabaseAdmin.ts), is
//     never present in any response, and is never sent to or usable
//     by the frontend.
//     This is also the only path that can read these tables for users
//     other than yourself at all: public.users has only a
//     "users_select_own" RLS policy (auth.uid() = id),
//     public.mining_state only "mining_state_select_own"
//     (auth.uid() = user_id), and public.mining_inventory only
//     "mining_inventory_select_own" (auth.uid() = user_id) — an
//     authenticated, non-admin caller can never read another player's
//     row through any client-side query; RLS denies it by default.
//     This function is a deliberate, narrow, admin-gated exception,
//     exactly like the target-lookup half of admin-set-mining-speed.
//
// Search ("list" only):
//   - Optional `search` string (max 200 chars). Empty/omitted =
//     every user, unchanged behavior.
//   - Matches (case-insensitive substring) against telegram_username,
//     telegram_first_name, or telegram_last_name, OR (exact match,
//     since telegram_user_id is a bigint, not free text) against
//     telegram_user_id when the search text is purely digits.
//   - Built as a single PostgREST `.or(...)` filter evaluated by
//     Postgres itself — never fetched-then-filtered here or in the
//     browser. The search text is escaped (ILIKE wildcards `%`/`_`
//     and the backslash escape character itself, plus PostgREST's own
//     comma/quote reserved characters) before being placed in that
//     filter string, so it is always treated as a literal substring
//     to match, never as an ILIKE pattern or filter-syntax injection.
//
// Mining rate ("get" only):
//   - miningRate reflects ONLY public.mining_state.admin_speed_override
//     (normalized), i.e. the one authoritative, directly-stored
//     override value — never recomputed. mining_state has no stored
//     "current effective rate" column; the real per-second rate
//     (base_speed + applied-miner-speed + referral bonus, then the
//     level multiplier, then normal/ad boosts, unless overridden by
//     admin_speed_override — see 0020_admin_mining_speed_control.sql)
//     is computed live, only inside accrue-mining/index.ts, from
//     public.mining_config plus this player's own state/inventory at
//     claim time. Reimplementing that formula here would risk it
//     silently drifting out of sync with the real one, so per this
//     feature's own instructions this file does not recalculate it:
//     when admin_speed_override is NULL, miningRate is returned as
//     `null` rather than an invented/recomputed number.
//
// Response 200 (list): { success: true, users: [ { userId,
//   telegramUserId, username, firstName, lastName, pxnBalance,
//   createdAt }, ... ] }
// Response 200 (get): { success: true, user: { userId, telegramUserId,
//   username, firstName, lastName, pxnBalance, minedBalanceTotal,
//   pendingClaim, claimedTotal, level, miningRate, createdAt },
//   miners: [ { inventoryId, minerTier, minerName, minerIcon,
//   minerLevel, minerSpeed, applied, createdAt }, ... ] }
// Response 400: { success: false, message: "..." }
//   (malformed body, invalid action, invalid/oversized search, userId
//   missing or not a valid UUID for "get")
// Response 401: { success: false, message: "Unauthorized" }
// Response 403: { success: false, message: "Forbidden" }
//   (authenticated, but not an admin)
// Response 404: { success: false, message: "User not found" }
//   ("get" only — userId is a syntactically valid UUID with no
//   matching public.users row)
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
const NOT_FOUND = { success: false, message: "User not found" } as const;
const SERVICE_UNAVAILABLE = { success: false, message: "Service temporarily unavailable" } as const;

const MAX_SEARCH_LEN = 200;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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

interface MiningStateDetailRow {
  user_id: string;
  pxn_balance: number | string | null;
  mined_balance_total: number | string | null;
  pending_claim: number | string | null;
  claimed_total: number | string | null;
  level: number | string | null;
  admin_speed_override: number | string | null;
}

interface MiningInventoryRow {
  id: string;
  miner_tier: number | string;
  miner_name: string;
  miner_icon: string | null;
  miner_level: number | string;
  miner_speed: number | string | null;
  is_applied: boolean;
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

/** Number(...) + Number.isFinite(...), never NaN — falls back to 0 (spec-required for pxnBalance; reused for the other numeric mining_state fields, which carry the same numeric(20,8)-can-arrive-as-string caveat). */
function safeNumber(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

/** Same normalization, but returns null instead of 0 when absent/non-finite — for admin_speed_override, where "no override" (null) is a meaningful, distinct state from "override of 0". */
function safeNullableNumber(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function mapUserRow(u: UserRow) {
  return {
    userId: u.id,
    telegramUserId:
      u.telegram_user_id === null || u.telegram_user_id === undefined
        ? null
        : String(u.telegram_user_id),
    username: u.telegram_username,
    firstName: u.telegram_first_name,
    lastName: u.telegram_last_name,
    createdAt: u.created_at,
  };
}

/** Strict validation for the "get" action's userId (the TARGET player): present, a JSON string, a valid UUID. Never coerces. Same pattern as admin-set-mining-speed's parseTargetUserId. */
function parseTargetUserId(body: unknown): string | null {
  if (typeof body !== "object" || body === null) return null;
  const raw = (body as Record<string, unknown>).userId;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!UUID_RE.test(trimmed)) return null;
  return trimmed;
}

/**
 * Validates the "list" action's optional search string.
 * Returns:
 *   { ok: true,  value: string | null }  — value is null for "no filter" (omitted/empty)
 *   { ok: false }                        — present but the wrong type, or over MAX_SEARCH_LEN
 */
function parseSearch(body: unknown): { ok: true; value: string | null } | { ok: false } {
  if (typeof body !== "object" || body === null) return { ok: true, value: null };
  const raw = (body as Record<string, unknown>).search;
  if (raw === undefined || raw === null) return { ok: true, value: null };
  if (typeof raw !== "string") return { ok: false };
  if (raw.length > MAX_SEARCH_LEN) return { ok: false };
  const trimmed = raw.trim();
  return { ok: true, value: trimmed.length > 0 ? trimmed : null };
}

/** action defaults to "list" (keeps the original `{}`-body call working). Anything other than "list"/"get" is invalid. */
function parseAction(body: unknown): "list" | "get" | null {
  if (typeof body !== "object" || body === null) return "list";
  const raw = (body as Record<string, unknown>).action;
  if (raw === undefined || raw === null) return "list";
  if (raw === "list" || raw === "get") return raw;
  return null;
}

/**
 * Escapes a raw search string for safe use inside a single PostgREST
 * `.or(...)` ILIKE condition: backslash-escapes the ILIKE wildcard
 * characters (`%`, `_`) and the backslash escape character itself, so
 * the text matches only literally (never as a wildcard pattern
 * supplied by the caller), then wraps the whole value in double
 * quotes and backslash-escapes any embedded double quote — PostgREST's
 * own required quoting for filter values that may contain reserved
 * characters (comma, period, parentheses) in an `.or()` filter list.
 */
function escapeIlikeValue(raw: string): string {
  const wildcardEscaped = raw.replace(/[\\%_]/g, (ch) => `\\${ch}`);
  const quoteEscaped = wildcardEscaped.replace(/"/g, '\\"');
  return `"%${quoteEscaped}%"`;
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
  let rawBody: unknown = {};
  const bodyText = await req.text();
  if (bodyText.trim().length > 0) {
    try {
      rawBody = JSON.parse(bodyText);
    } catch {
      return jsonResponse({ success: false, message: "Request body must be valid JSON" }, 400);
    }
  }

  const action = parseAction(rawBody);
  if (action === null) {
    return jsonResponse({ success: false, message: "action must be one of: list, get" }, 400);
  }

  let targetUserId: string | null = null;
  let searchValue: string | null = null;

  if (action === "get") {
    targetUserId = parseTargetUserId(rawBody);
    if (targetUserId === null) {
      return jsonResponse({ success: false, message: "userId must be a valid UUID" }, 400);
    }
  } else {
    const parsedSearch = parseSearch(rawBody);
    if (!parsedSearch.ok) {
      return jsonResponse(
        { success: false, message: `search must be a string up to ${MAX_SEARCH_LEN} characters` },
        400,
      );
    }
    searchValue = parsedSearch.value;
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
  // their own bearer token). Never used for any other database read,
  // and never used with targetUserId above (that identifies the
  // TARGET player, not the caller — see the header comment).
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
  // public.users / public.mining_state / public.mining_inventory row
  // (each table only grants "select own" to authenticated via RLS).
  // Only constructed after the caller has already been confirmed
  // authenticated AND admin above. Used for read-only SELECTs only.
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

  // ================================ list ================================
  if (action === "list") {
    let usersQuery = admin
      .from("users")
      .select("id, telegram_user_id, telegram_username, telegram_first_name, telegram_last_name, created_at")
      .order("created_at", { ascending: false });

    if (searchValue !== null) {
      const pattern = escapeIlikeValue(searchValue);
      const conditions = [
        `telegram_username.ilike.${pattern}`,
        `telegram_first_name.ilike.${pattern}`,
        `telegram_last_name.ilike.${pattern}`,
      ];
      // telegram_user_id is a bigint, not free text — an ILIKE
      // substring match isn't meaningful/available on it without a
      // column cast, so a purely-numeric search additionally matches
      // it by EXACT value (the common "paste the Telegram ID" case).
      if (/^\d+$/.test(searchValue)) {
        conditions.push(`telegram_user_id.eq.${searchValue}`);
      }
      usersQuery = usersQuery.or(conditions.join(","));
    }

    const { data: usersData, error: usersError } = await usersQuery;
    if (usersError) {
      console.error("[admin-users] list failed:", usersError.message);
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
      ...mapUserRow(u),
      // Not present in balanceByUserId (no mining_state row yet) safely
      // falls back to 0 via safeNumber(undefined), same as a
      // non-finite stored value would.
      pxnBalance: safeNumber(balanceByUserId.get(u.id)),
    }));

    return jsonResponse({ success: true, users }, 200);
  }

  // ================================= get =================================
  const { data: userRow, error: userError } = await admin
    .from("users")
    .select("id, telegram_user_id, telegram_username, telegram_first_name, telegram_last_name, created_at")
    .eq("id", targetUserId as string)
    .maybeSingle();

  if (userError) {
    console.error("[admin-users] get user failed:", userError.message);
    return jsonResponse({ success: false, message: "Could not load user" }, 500);
  }
  if (!userRow) {
    return jsonResponse(NOT_FOUND, 404);
  }

  const { data: stateRow, error: stateError } = await admin
    .from("mining_state")
    .select("user_id, pxn_balance, mined_balance_total, pending_claim, claimed_total, level, admin_speed_override")
    .eq("user_id", targetUserId as string)
    .maybeSingle();

  if (stateError) {
    console.error("[admin-users] get mining_state failed:", stateError.message);
    return jsonResponse({ success: false, message: "Could not load user" }, 500);
  }

  const { data: minersData, error: minersError } = await admin
    .from("mining_inventory")
    .select("id, miner_tier, miner_name, miner_icon, miner_level, miner_speed, is_applied, created_at")
    .eq("user_id", targetUserId as string)
    .order("created_at", { ascending: true });

  if (minersError) {
    console.error("[admin-users] get mining_inventory failed:", minersError.message);
    return jsonResponse({ success: false, message: "Could not load user" }, 500);
  }

  const state = stateRow as MiningStateDetailRow | null;

  const user = {
    ...mapUserRow(userRow as UserRow),
    pxnBalance: state ? safeNumber(state.pxn_balance) : 0,
    minedBalanceTotal: state ? safeNumber(state.mined_balance_total) : 0,
    pendingClaim: state ? safeNumber(state.pending_claim) : 0,
    claimedTotal: state ? safeNumber(state.claimed_total) : 0,
    level: state ? safeNumber(state.level) : 0,
    // See the "Mining rate" header comment: only the directly-stored
    // admin override, never a recomputed/invented rate.
    miningRate: state ? safeNullableNumber(state.admin_speed_override) : null,
  };

  const miners = ((minersData ?? []) as MiningInventoryRow[]).map((m) => ({
    inventoryId: m.id,
    minerTier: safeNumber(m.miner_tier),
    minerName: m.miner_name,
    minerIcon: m.miner_icon,
    minerLevel: safeNumber(m.miner_level),
    minerSpeed: safeNumber(m.miner_speed),
    applied: m.is_applied === true,
    createdAt: m.created_at,
  }));

  return jsonResponse({ success: true, user, miners }, 200);
});
