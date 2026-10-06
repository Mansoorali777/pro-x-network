// Pro-X Network — "admin-task-catalog" Edge Function.
//
// POST /functions/v1/admin-task-catalog
//
// Admin-only CRUD surface for public.task_catalog (see
// 0035_task_catalog.sql). This is the ONLY entry point intended to
// write to that table from outside the SQL editor — it does NOT
// touch miner_catalog, mining_config, mining_state, mining_inventory,
// mpxn_ledger, adjust_claimed_total(), users, auth-telegram, or any
// other existing table/function, and it does NOT modify any existing
// RLS policy on task_catalog (the player-facing "select active rows"
// policy from 0035 is untouched; this file only ever uses the
// service-role client, which bypasses RLS entirely, exactly like
// admin-miner-catalog).
//
// This function does NOT implement task claiming/rewards. It does
// NOT create, read, or write public.task_claims (which does not
// exist yet). reward_mpxn here is a catalog value only — nothing in
// this file credits, debits, or otherwise touches any player balance.
// It also does NOT upload/replace/delete any Storage object in the
// task-icons bucket (see 0036_task_icon_storage.sql) — the `icon`
// field is stored and returned purely as an admin-supplied string
// (path/URL); actual Storage upload handling is an explicitly later,
// separate step (mirrors how admin-miner-catalog itself never touches
// Storage — the admin.html icon-upload flow calls Storage directly).
//
// Request body — a single JSON object with an "action" field:
//
//   List:    { "action": "list_tasks" }
//   Get:     { "action": "get_task", "task_id": <uuid> }
//   Create:  { "action": "create_task", "title": <string 1-200>,
//              "subtitle": <string 1-500>, "icon"?: <string|null>,
//              "action_url"?: <string|null>,
//              "verification_type": <manual_claim|referral_count|miner_level|claim_count>,
//              "reward_mpxn": <number, 0 < n <= 100000000>,
//              "sort_order": <integer 0-100000>,
//              "is_active"?: <boolean, default true> }
//   Update:  { "action": "update_task", "task_id": <uuid>,
//              "title"?, "subtitle"?, "icon"?, "action_url"?,
//              "verification_type"?, "reward_mpxn"?, "sort_order"?,
//              "is_active"? }  (at least one updatable field required;
//              "id" and "created_at" are never accepted/applied even
//              if present in the body)
//   Delete:  { "action": "delete_task", "task_id": <uuid> }
//   SetActive: { "action": "set_active", "task_id": <uuid>, "is_active": <boolean> }
//   Reorder: { "action": "reorder_tasks",
//              "items": [ { "task_id": <uuid>, "sort_order": <integer 0-100000> }, ... ] }
//
// Authentication & authorization (identical caller-identity pattern to
// admin-miner-catalog / admin-set-mining-speed / me / purchase-miner —
// see those files):
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     CALLER's own `Authorization: Bearer <token>`) is used ONLY for
//     auth.getUser() (identity) and the public.is_current_user_admin()
//     RPC (authorization, evaluated as the caller via auth.uid() —
//     never trusted from the request body or any client-supplied
//     flag). Never used for any other read/write.
//   - If auth.getUser() fails: 401 UNAUTHORIZED.
//   - If is_current_user_admin() is not exactly `true`: 403 FORBIDDEN.
//   - Only after both checks pass is the service-role client
//     (getSupabaseAdmin(), see _shared/supabaseAdmin.ts) used to read
//     or write task_catalog. SUPABASE_SERVICE_ROLE_KEY is read only
//     from Deno.env (Supabase secrets), never present in any
//     response, and never sent to or usable by the frontend.
//   - Nothing here trusts body.userId, a Telegram username/id, a
//     frontend "isAdmin" flag, or localStorage for authorization.
//     There is no custom JWT of any kind involved — no
//     SUPABASE_JWT_SECRET, no PXN_JWT_SECRET, no JWKS/private JWK,
//     no custom signing. Only Supabase's own auth.getUser().
//
// Validation notes (server-authoritative — the frontend's own
// validation, if any, is never trusted):
//   - title and subtitle are both required, non-empty (after
//     trimming) strings. NOTE: task_catalog.subtitle is NOT NULL with
//     a length-1..500 check constraint (0035_task_catalog.sql), so
//     subtitle is treated as REQUIRED here even though the calling
//     spec described it as "optional but normalized" — an empty/
//     missing subtitle would violate the existing table's CHECK
//     constraint and fail at the database, so this function rejects
//     it up front with a clear 400 instead of forwarding a raw DB
//     error. icon and action_url ARE genuinely optional/nullable,
//     matching the table's actual (nullable) schema.
//   - reward_mpxn must be a finite number STRICTLY GREATER THAN 0 on
//     create (tighter than the table's own `>= 0` check constraint —
//     an intentional Edge-Function-level rule so a task can never be
//     created worth nothing; still well within what the table allows).
//   - sort_order must be an integer within [0, 100000], matching
//     task_catalog's own check constraint exactly.
//   - verification_type must be exactly one of the 4 values the
//     table's check constraint allows.
//
// reorder_tasks concurrency note: Postgres RLS/service-role writes
// here are NOT wrapped in a single multi-row transaction (per
// instructions, no new RPC/migration is introduced in this step to
// provide one). To avoid ever silently mutating some rows for a
// request that names a nonexistent task_id, this function first
// verifies every task_id in the request already exists — and performs
// NO writes at all — before applying any update. Once that check
// passes, each row's sort_order is updated with its own independent
// UPDATE statement; if one of those (already-validated) updates were
// to fail for an unrelated reason (e.g. a transient DB error), rows
// updated earlier in the same request remain updated — this is a
// known limitation of doing this without a dedicated RPC, and is
// documented here rather than hidden.
//
// Response shapes:
//   Success: { "success": true, "data": ... }
//   Error:   { "success": false, "error": { "code": "...", "message": "..." } }
//
//   200 list_tasks:    data: { tasks: [...] }
//   200 get_task:      data: { task: {...} }
//   200 create_task:   data: { task: {...} }
//   200 update_task:   data: { task: {...} }
//   200 delete_task:   data: { deleted: true, task_id: "..." }
//   200 set_active:    data: { task: {...} }
//   200 reorder_tasks: data: { tasks: [...] }   (updated rows, sort_order ascending)
//   400: malformed/invalid input (INVALID_JSON / INVALID_BODY / INVALID_ACTION / VALIDATION_ERROR)
//   401: UNAUTHORIZED
//   403: FORBIDDEN
//   404: NOT_FOUND
//   405: METHOD_NOT_ALLOWED
//   500: SERVICE_UNAVAILABLE / INTERNAL_ERROR
//
// Never logs the access token, the service-role key, or any other
// secret. Database errors are never forwarded verbatim to the
// client — only a small set of recognized cases are mapped to
// specific messages; everything else becomes a generic 500.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

function successResponse(data: unknown, status = 200): Response {
  return jsonResponse({ success: true, data }, status);
}

function errorResponse(code: string, message: string, status: number): Response {
  return jsonResponse({ success: false, error: { code, message } }, status);
}

const ERR = {
  METHOD_NOT_ALLOWED: "METHOD_NOT_ALLOWED",
  UNAUTHORIZED: "UNAUTHORIZED",
  FORBIDDEN: "FORBIDDEN",
  INVALID_JSON: "INVALID_JSON",
  INVALID_BODY: "INVALID_BODY",
  INVALID_ACTION: "INVALID_ACTION",
  VALIDATION_ERROR: "VALIDATION_ERROR",
  NOT_FOUND: "NOT_FOUND",
  SERVICE_UNAVAILABLE: "SERVICE_UNAVAILABLE",
  INTERNAL_ERROR: "INTERNAL_ERROR",
} as const;

// ---------------------------------------------------------------------------
// Constants (mirror task_catalog's own check constraints — 0035_task_catalog.sql)
// ---------------------------------------------------------------------------

const MIN_TITLE_LEN = 1;
const MAX_TITLE_LEN = 200;
const MIN_SUBTITLE_LEN = 1;
const MAX_SUBTITLE_LEN = 500;

// icon/action_url have no length check at the DB level (task_catalog.icon
// and .action_url are unconstrained nullable text) — these are sane
// Edge-Function-level caps only, not a reflection of a DB constraint.
const MAX_ICON_LEN = 2000;
const MAX_ACTION_URL_LEN = 2000;

const MIN_REWARD_MPXN = 0; // table allows >= 0; this function requires strictly > 0 on create (see below)
const MAX_REWARD_MPXN = 100000000;

const MIN_SORT_ORDER = 0;
const MAX_SORT_ORDER = 100000;

const VALID_VERIFICATION_TYPES = new Set([
  "manual_claim",
  "referral_count",
  "miner_level",
  "claim_count",
]);

const VALID_ACTIONS = new Set([
  "list_tasks",
  "get_task",
  "create_task",
  "update_task",
  "delete_task",
  "set_active",
  "reorder_tasks",
]);

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

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

/** Strict validation for a required `task_id` field. Never coerces. */
function parseTaskId(body: Record<string, unknown>): string | null {
  const raw = body.task_id;
  if (!isValidUuid(raw)) return null;
  return (raw as string).trim();
}

/** Required string field: JSON string, trimmed, length within [min, max]. */
function parseRequiredString(raw: unknown, min: number, max: number): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (trimmed.length < min || trimmed.length > max) return null;
  return trimmed;
}

/**
 * Optional, nullable string field (icon / action_url).
 * - undefined  -> "not supplied" (caller should leave existing value alone on update,
 *                 or store null on create)
 * - null       -> explicit "clear this field" -> stored as null
 * - string     -> trimmed; empty string after trim is normalized to null;
 *                 otherwise validated against maxLen
 * Returns `{ ok: false }` only when a non-null, non-string value was supplied,
 * or a non-empty string exceeds maxLen.
 */
type OptionalStringResult =
  | { ok: true; supplied: false }
  | { ok: true; supplied: true; value: string | null }
  | { ok: false };

function parseOptionalNullableString(raw: unknown, maxLen: number): OptionalStringResult {
  if (raw === undefined) return { ok: true, supplied: false };
  if (raw === null) return { ok: true, supplied: true, value: null };
  if (typeof raw !== "string") return { ok: false };
  const trimmed = raw.trim();
  if (trimmed.length === 0) return { ok: true, supplied: true, value: null };
  if (trimmed.length > maxLen) return { ok: false };
  return { ok: true, supplied: true, value: trimmed };
}

function parseVerificationType(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  return VALID_VERIFICATION_TYPES.has(raw) ? raw : null;
}

/** reward_mpxn: finite number, `min < n <= MAX_REWARD_MPXN` (strict lower bound — see header note). */
function parseRewardMpxn(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw)) return null;
  if (raw <= MIN_REWARD_MPXN || raw > MAX_REWARD_MPXN) return null;
  return raw;
}

function parseSortOrder(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isInteger(raw)) return null;
  if (raw < MIN_SORT_ORDER || raw > MAX_SORT_ORDER) return null;
  return raw;
}

function parseIsActive(raw: unknown): boolean | null {
  if (typeof raw !== "boolean") return null;
  return raw;
}

// ---------------------------------------------------------------------------
// Row shape
// ---------------------------------------------------------------------------

interface TaskCatalogRow {
  id: string;
  title: string;
  subtitle: string;
  icon: string | null;
  action_url: string | null;
  verification_type: string;
  reward_mpxn: number | string;
  sort_order: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

/** Maps a DB row to the JSON shape returned to the client (same field names as the table). */
function formatTask(row: TaskCatalogRow) {
  return {
    id: row.id,
    title: row.title,
    subtitle: row.subtitle,
    icon: row.icon,
    action_url: row.action_url,
    verification_type: row.verification_type,
    reward_mpxn: Number(row.reward_mpxn),
    sort_order: row.sort_order,
    is_active: row.is_active,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse(ERR.METHOD_NOT_ALLOWED, "Method not allowed", 405);
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) {
    return errorResponse(ERR.UNAUTHORIZED, "Missing or invalid Authorization header", 401);
  }

  // --- Parse and strictly validate the request body BEFORE touching auth or the database. ---
  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return errorResponse(ERR.INVALID_JSON, "Request body must be valid JSON", 400);
  }

  if (!isPlainObject(rawBody)) {
    return errorResponse(ERR.INVALID_BODY, "Request body must be a JSON object", 400);
  }

  const action = rawBody.action;
  if (typeof action !== "string" || !VALID_ACTIONS.has(action)) {
    return errorResponse(
      ERR.INVALID_ACTION,
      "action must be one of: list_tasks, get_task, create_task, update_task, delete_task, set_active, reorder_tasks",
      400,
    );
  }

  // Per-action field validation, done up front so a malformed request
  // never reaches auth or the database.
  let taskId: string | null = null;
  let title: string | null = null;
  let subtitle: string | null = null;
  let iconResult: OptionalStringResult = { ok: true, supplied: false };
  let actionUrlResult: OptionalStringResult = { ok: true, supplied: false };
  let verificationType: string | null = null;
  let rewardMpxn: number | null = null;
  let sortOrder: number | null = null;
  let isActive: boolean | null = null;
  let reorderItems: Array<{ task_id: string; sort_order: number }> | null = null;

  if (action === "get_task" || action === "delete_task") {
    taskId = parseTaskId(rawBody);
    if (taskId === null) {
      return errorResponse(ERR.VALIDATION_ERROR, "task_id must be a valid UUID", 400);
    }
  } else if (action === "create_task") {
    title = parseRequiredString(rawBody.title, MIN_TITLE_LEN, MAX_TITLE_LEN);
    if (title === null) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        `title is required and must be a string from ${MIN_TITLE_LEN} to ${MAX_TITLE_LEN} characters`,
        400,
      );
    }

    // subtitle: task_catalog.subtitle is NOT NULL with a 1-500 length
    // check constraint, so it is required here despite being described
    // as "optional" in the calling spec — see header note.
    subtitle = parseRequiredString(rawBody.subtitle, MIN_SUBTITLE_LEN, MAX_SUBTITLE_LEN);
    if (subtitle === null) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        `subtitle is required (task_catalog.subtitle is NOT NULL) and must be a string from ${MIN_SUBTITLE_LEN} to ${MAX_SUBTITLE_LEN} characters`,
        400,
      );
    }

    iconResult = parseOptionalNullableString(rawBody.icon, MAX_ICON_LEN);
    if (!iconResult.ok) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        `icon must be a string up to ${MAX_ICON_LEN} characters, or null`,
        400,
      );
    }

    actionUrlResult = parseOptionalNullableString(rawBody.action_url, MAX_ACTION_URL_LEN);
    if (!actionUrlResult.ok) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        `action_url must be a string up to ${MAX_ACTION_URL_LEN} characters, or null`,
        400,
      );
    }

    verificationType = parseVerificationType(rawBody.verification_type);
    if (verificationType === null) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        `verification_type must be one of: ${Array.from(VALID_VERIFICATION_TYPES).join(", ")}`,
        400,
      );
    }

    rewardMpxn = parseRewardMpxn(rawBody.reward_mpxn);
    if (rewardMpxn === null) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        `reward_mpxn must be a finite number greater than 0 and up to ${MAX_REWARD_MPXN}`,
        400,
      );
    }

    sortOrder = parseSortOrder(rawBody.sort_order);
    if (sortOrder === null) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        `sort_order must be an integer from ${MIN_SORT_ORDER} to ${MAX_SORT_ORDER}`,
        400,
      );
    }

    if (rawBody.is_active === undefined) {
      isActive = true; // matches task_catalog.is_active's own DEFAULT true
    } else {
      isActive = parseIsActive(rawBody.is_active);
      if (isActive === null) {
        return errorResponse(ERR.VALIDATION_ERROR, "is_active must be a boolean", 400);
      }
    }
  } else if (action === "update_task") {
    taskId = parseTaskId(rawBody);
    if (taskId === null) {
      return errorResponse(ERR.VALIDATION_ERROR, "task_id must be a valid UUID", 400);
    }

    // "id" and "created_at" are intentionally never read from the body —
    // even if present, they are silently ignored rather than applied.

    if (rawBody.title !== undefined) {
      title = parseRequiredString(rawBody.title, MIN_TITLE_LEN, MAX_TITLE_LEN);
      if (title === null) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `title must be a string from ${MIN_TITLE_LEN} to ${MAX_TITLE_LEN} characters`,
          400,
        );
      }
    }

    if (rawBody.subtitle !== undefined) {
      subtitle = parseRequiredString(rawBody.subtitle, MIN_SUBTITLE_LEN, MAX_SUBTITLE_LEN);
      if (subtitle === null) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `subtitle must be a non-empty string from ${MIN_SUBTITLE_LEN} to ${MAX_SUBTITLE_LEN} characters (task_catalog.subtitle is NOT NULL, so it cannot be cleared to empty)`,
          400,
        );
      }
    }

    if (rawBody.icon !== undefined) {
      iconResult = parseOptionalNullableString(rawBody.icon, MAX_ICON_LEN);
      if (!iconResult.ok) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `icon must be a string up to ${MAX_ICON_LEN} characters, or null`,
          400,
        );
      }
    }

    if (rawBody.action_url !== undefined) {
      actionUrlResult = parseOptionalNullableString(rawBody.action_url, MAX_ACTION_URL_LEN);
      if (!actionUrlResult.ok) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `action_url must be a string up to ${MAX_ACTION_URL_LEN} characters, or null`,
          400,
        );
      }
    }

    if (rawBody.verification_type !== undefined) {
      verificationType = parseVerificationType(rawBody.verification_type);
      if (verificationType === null) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `verification_type must be one of: ${Array.from(VALID_VERIFICATION_TYPES).join(", ")}`,
          400,
        );
      }
    }

    if (rawBody.reward_mpxn !== undefined) {
      rewardMpxn = parseRewardMpxn(rawBody.reward_mpxn);
      if (rewardMpxn === null) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `reward_mpxn must be a finite number greater than 0 and up to ${MAX_REWARD_MPXN}`,
          400,
        );
      }
    }

    if (rawBody.sort_order !== undefined) {
      sortOrder = parseSortOrder(rawBody.sort_order);
      if (sortOrder === null) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `sort_order must be an integer from ${MIN_SORT_ORDER} to ${MAX_SORT_ORDER}`,
          400,
        );
      }
    }

    if (rawBody.is_active !== undefined) {
      isActive = parseIsActive(rawBody.is_active);
      if (isActive === null) {
        return errorResponse(ERR.VALIDATION_ERROR, "is_active must be a boolean", 400);
      }
    }

    const hasAnyUpdatableField =
      title !== null ||
      subtitle !== null ||
      iconResult.supplied ||
      actionUrlResult.supplied ||
      verificationType !== null ||
      rewardMpxn !== null ||
      sortOrder !== null ||
      isActive !== null;

    if (!hasAnyUpdatableField) {
      return errorResponse(
        ERR.VALIDATION_ERROR,
        "At least one updatable field must be provided",
        400,
      );
    }
  } else if (action === "set_active") {
    taskId = parseTaskId(rawBody);
    if (taskId === null) {
      return errorResponse(ERR.VALIDATION_ERROR, "task_id must be a valid UUID", 400);
    }
    isActive = parseIsActive(rawBody.is_active);
    if (isActive === null) {
      return errorResponse(ERR.VALIDATION_ERROR, "is_active must be a boolean", 400);
    }
  } else if (action === "reorder_tasks") {
    const rawItems = rawBody.items;
    if (!Array.isArray(rawItems) || rawItems.length === 0) {
      return errorResponse(ERR.VALIDATION_ERROR, "items must be a non-empty array", 400);
    }

    const parsedItems: Array<{ task_id: string; sort_order: number }> = [];
    const seenTaskIds = new Set<string>();
    const seenSortOrders = new Set<number>();

    for (const rawItem of rawItems) {
      if (!isPlainObject(rawItem)) {
        return errorResponse(ERR.VALIDATION_ERROR, "Each item must be a JSON object", 400);
      }
      if (!isValidUuid(rawItem.task_id)) {
        return errorResponse(ERR.VALIDATION_ERROR, "Each item.task_id must be a valid UUID", 400);
      }
      const itemTaskId = (rawItem.task_id as string).trim();

      const itemSortOrder = parseSortOrder(rawItem.sort_order);
      if (itemSortOrder === null) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `Each item.sort_order must be an integer from ${MIN_SORT_ORDER} to ${MAX_SORT_ORDER}`,
          400,
        );
      }

      if (seenTaskIds.has(itemTaskId)) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `Duplicate task_id in items: ${itemTaskId}`,
          400,
        );
      }
      if (seenSortOrders.has(itemSortOrder)) {
        return errorResponse(
          ERR.VALIDATION_ERROR,
          `Duplicate sort_order in items: ${itemSortOrder}`,
          400,
        );
      }
      seenTaskIds.add(itemTaskId);
      seenSortOrders.add(itemSortOrder);
      parsedItems.push({ task_id: itemTaskId, sort_order: itemSortOrder });
    }

    reorderItems = parsedItems;
  }
  // action === "list_tasks" needs no field validation.

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[admin-task-catalog] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(ERR.SERVICE_UNAVAILABLE, "Service temporarily unavailable", 500);
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
    return errorResponse(ERR.UNAUTHORIZED, "Unauthorized", 401);
  }

  // --- Authorization: is THIS caller an admin? Server-side only. ---
  const { data: isAdminData, error: isAdminError } = await callerClient.rpc(
    "is_current_user_admin",
  );
  if (isAdminError) {
    console.error(
      "[admin-task-catalog] is_current_user_admin check failed:",
      isAdminError.message,
    );
    return errorResponse(ERR.SERVICE_UNAVAILABLE, "Service temporarily unavailable", 500);
  }
  if (isAdminData !== true) {
    return errorResponse(ERR.FORBIDDEN, "Forbidden", 403);
  }

  // Service-role client — the only client that may read/write
  // task_catalog from this function. RLS on task_catalog has no
  // authenticated-role write policy at all (see 0035_task_catalog.sql),
  // so a service-role client is the only way to write to this table
  // outside the SQL editor; this Edge Function is that path.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[admin-task-catalog] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(ERR.SERVICE_UNAVAILABLE, "Service temporarily unavailable", 500);
  }

  try {
    if (action === "list_tasks") {
      // Admin sees every row, active or not — no is_active filter here
      // (the public "active only" view is task_catalog's own RLS
      // policy, which only applies to non-service-role callers anyway).
      const { data, error } = await admin
        .from("task_catalog")
        .select("*")
        .order("sort_order", { ascending: true })
        .order("created_at", { ascending: true });

      if (error) {
        console.error("[admin-task-catalog] list_tasks failed:", error.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not load task catalog", 500);
      }

      const rows = (data ?? []) as TaskCatalogRow[];
      return successResponse({ tasks: rows.map(formatTask) });
    }

    if (action === "get_task") {
      const { data, error } = await admin
        .from("task_catalog")
        .select("*")
        .eq("id", taskId as string)
        .maybeSingle();

      if (error) {
        console.error("[admin-task-catalog] get_task failed:", error.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not load task", 500);
      }
      if (!data) {
        return errorResponse(ERR.NOT_FOUND, "Task not found", 404);
      }

      return successResponse({ task: formatTask(data as TaskCatalogRow) });
    }

    if (action === "create_task") {
      const { data, error } = await admin
        .from("task_catalog")
        .insert({
          title,
          subtitle,
          icon: iconResult.supplied ? iconResult.value : null,
          action_url: actionUrlResult.supplied ? actionUrlResult.value : null,
          verification_type: verificationType,
          reward_mpxn: rewardMpxn,
          sort_order: sortOrder,
          is_active: isActive,
        })
        .select("*")
        .single();

      if (error) {
        console.error("[admin-task-catalog] create_task failed:", error.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not create task", 500);
      }

      return successResponse({ task: formatTask(data as TaskCatalogRow) });
    }

    if (action === "update_task") {
      const patch: Record<string, unknown> = {};
      if (title !== null) patch.title = title;
      if (subtitle !== null) patch.subtitle = subtitle;
      if (iconResult.supplied) patch.icon = iconResult.value;
      if (actionUrlResult.supplied) patch.action_url = actionUrlResult.value;
      if (verificationType !== null) patch.verification_type = verificationType;
      if (rewardMpxn !== null) patch.reward_mpxn = rewardMpxn;
      if (sortOrder !== null) patch.sort_order = sortOrder;
      if (isActive !== null) patch.is_active = isActive;
      // "id" and "created_at" are never included in patch, by construction.

      const { data, error } = await admin
        .from("task_catalog")
        .update(patch)
        .eq("id", taskId as string)
        .select("*")
        .maybeSingle();

      if (error) {
        console.error("[admin-task-catalog] update_task failed:", error.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not update task", 500);
      }
      if (!data) {
        return errorResponse(ERR.NOT_FOUND, "Task not found", 404);
      }

      return successResponse({ task: formatTask(data as TaskCatalogRow) });
    }

    if (action === "set_active") {
      const { data, error } = await admin
        .from("task_catalog")
        .update({ is_active: isActive })
        .eq("id", taskId as string)
        .select("*")
        .maybeSingle();

      if (error) {
        console.error("[admin-task-catalog] set_active failed:", error.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not update task", 500);
      }
      if (!data) {
        return errorResponse(ERR.NOT_FOUND, "Task not found", 404);
      }

      return successResponse({ task: formatTask(data as TaskCatalogRow) });
    }

    if (action === "delete_task") {
      // Deletes ONLY the matched task_catalog row. No task_claims table
      // exists yet (explicitly out of scope for this step), so there is
      // no claim-history to cascade into, and this can never touch any
      // player balance.
      const { data, error } = await admin
        .from("task_catalog")
        .delete()
        .eq("id", taskId as string)
        .select("id")
        .maybeSingle();

      if (error) {
        console.error("[admin-task-catalog] delete_task failed:", error.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not delete task", 500);
      }
      if (!data) {
        return errorResponse(ERR.NOT_FOUND, "Task not found", 404);
      }

      return successResponse({ deleted: true, task_id: (data as { id: string }).id });
    }

    if (action === "reorder_tasks") {
      const items = reorderItems as Array<{ task_id: string; sort_order: number }>;
      const requestedIds = items.map((i) => i.task_id);

      // Fail-fast, no-write validation pass: every requested task_id
      // must already exist, checked BEFORE any UPDATE is issued (see
      // header note on why this can't be a single atomic transaction
      // without a dedicated RPC).
      const { data: existingRows, error: existingError } = await admin
        .from("task_catalog")
        .select("id")
        .in("id", requestedIds);

      if (existingError) {
        console.error("[admin-task-catalog] reorder_tasks lookup failed:", existingError.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Could not verify tasks", 500);
      }

      const existingIds = new Set((existingRows ?? []).map((r: { id: string }) => r.id));
      const missingIds = requestedIds.filter((id) => !existingIds.has(id));
      if (missingIds.length > 0) {
        return errorResponse(
          ERR.NOT_FOUND,
          `Task(s) not found: ${missingIds.join(", ")}`,
          404,
        );
      }

      // All requested ids confirmed to exist — apply each update. Each
      // is an independent statement (see header note on the lack of a
      // wrapping transaction).
      for (const item of items) {
        const { error: updateError } = await admin
          .from("task_catalog")
          .update({ sort_order: item.sort_order })
          .eq("id", item.task_id);

        if (updateError) {
          console.error("[admin-task-catalog] reorder_tasks update failed:", updateError.message);
          return errorResponse(ERR.INTERNAL_ERROR, "Could not fully apply new task order", 500);
        }
      }

      const { data: updatedRows, error: reloadError } = await admin
        .from("task_catalog")
        .select("*")
        .order("sort_order", { ascending: true })
        .order("created_at", { ascending: true });

      if (reloadError) {
        console.error("[admin-task-catalog] reorder_tasks reload failed:", reloadError.message);
        return errorResponse(ERR.INTERNAL_ERROR, "Order was applied but could not be reloaded", 500);
      }

      const rows = (updatedRows ?? []) as TaskCatalogRow[];
      return successResponse({ tasks: rows.map(formatTask) });
    }

    // Unreachable — action was validated against VALID_ACTIONS above.
    return errorResponse(ERR.INVALID_ACTION, "Unsupported action", 400);
  } catch (err) {
    console.error(
      "[admin-task-catalog] unexpected error:",
      err instanceof Error ? err.message : "unknown error",
    );
    return errorResponse(ERR.INTERNAL_ERROR, "Service temporarily unavailable", 500);
  }
});
