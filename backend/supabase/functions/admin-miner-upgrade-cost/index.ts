// Pro-X Network — "admin-miner-upgrade-cost" Edge Function.
//
// POST /functions/v1/admin-miner-upgrade-cost
//
// Admin-only read/write surface for public.miner_upgrade_costs (see
// 0026_admin_miner_upgrade_costs.sql). This is the ONLY entry point
// intended to write to that table from outside the SQL editor — it
// does NOT touch miner_catalog, mining_config, mining_state,
// mining_inventory, miner_upgrade_config, users, purchase-miner,
// set-miner-applied, accrue-mining, or upgrade-miner, and it does NOT
// modify any RLS policy on miner_upgrade_costs (that table has zero
// client policies, by design — this file only ever uses the
// service-role client, which bypasses RLS entirely, exactly like
// admin-set-mining-speed and admin-miner-catalog).
//
// Request body — a single JSON object with an "action" field:
//
//   List:   { "action": "list" }
//     Returns every configured (from_level -> to_level) row, ordered
//     by from_level ascending.
//
//   Update: { "action": "update", "fromLevel": <int >= 1>,
//             "costPxn": <number, finite, 0-100000000> }
//     Sets the exact PXN cost for the (fromLevel -> fromLevel + 1)
//     transition. toLevel is never accepted from the client — it is
//     always derived as fromLevel + 1 server-side, matching the
//     table's own to_level = from_level + 1 CHECK constraint.
//
//   Reset:  { "action": "reset", "fromLevel": <int >= 1> }
//     Restores cost_pxn for that transition back to the row's own
//     default_cost_pxn (the value it was originally seeded with —
//     see 0026_admin_miner_upgrade_costs.sql). Never recomputes
//     anything from miner_catalog or miner_upgrade_config; it only
//     ever copies default_cost_pxn into cost_pxn for that one row.
//
// Authentication & authorization (identical caller-identity pattern
// to admin-set-mining-speed / admin-miner-catalog / me /
// purchase-miner / accrue-mining — see those files):
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     CALLER's own `Authorization: Bearer <token>`) is used ONLY for
//     auth.getUser() (identity) and the public.is_current_user_admin()
//     RPC (authorization, evaluated as the caller via auth.uid() —
//     never trusted from the request body or any client-supplied
//     flag). Never used for any other read/write.
//   - If auth.getUser() fails: 401.
//   - If is_current_user_admin() is not exactly `true`: 403.
//   - Only after both checks pass is the service-role client
//     (getSupabaseAdmin(), see _shared/supabaseAdmin.ts) used to read
//     or write miner_upgrade_costs. SUPABASE_SERVICE_ROLE_KEY is read
//     only from Deno.env (Supabase secrets), never present in any
//     response, and never sent to or usable by the frontend.
//   - This function never accepts a "userId" field of any kind — it
//     has no notion of acting on behalf of, or targeting, any
//     particular player. It only ever reads/writes the GLOBAL,
//     tier-independent miner_upgrade_costs table.
//
// Data-integrity guarantees:
//   - "update" and "reset" only ever touch the single row matched by
//     (from_level, from_level + 1) — no cascade, no write to any
//     other table, no balance change of any kind, and no retroactive
//     effect on any mining_inventory row already upgraded at the old
//     cost.
//   - "update" never accepts or derives toLevel from the client;
//     it is always fromLevel + 1, matching the table's own CHECK
//     constraint, so a client can never create or target a
//     multi-level-skip row.
//   - "reset" never recomputes a formula — it only copies the row's
//     own stored default_cost_pxn (fixed at seed time) into cost_pxn.
//   - No new RLS policy, table, or migration is created or modified
//     by this file. The only client write policy remains "none" —
//     writes only ever happen via this service-role-backed function.
//
// Response shapes:
//   200 list:     { success: true, costs: [...] }
//   200 mutation: { success: true, cost: {...} }
//   400: { success: false, message: "..." }   (malformed/invalid input)
//   401: { success: false, message: "Unauthorized" }
//   403: { success: false, message: "Forbidden" }
//   404: { success: false, message: "No upgrade cost is configured for that level" }
//   405: method not allowed
//   500: server misconfiguration or unexpected error
//
// Never logs the access token, the service-role key, or any other
// secret. Database errors are never forwarded verbatim to the
// client — only a small set of recognized error codes are mapped to
// specific messages; everything else becomes a generic 500.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;
const FORBIDDEN = { success: false, message: "Forbidden" } as const;
const NOT_FOUND = {
  success: false,
  message: "No upgrade cost is configured for that level",
} as const;
const SERVICE_UNAVAILABLE = { success: false, message: "Service temporarily unavailable" } as const;

const MIN_FROM_LEVEL = 1;
const MAX_FROM_LEVEL = 100000; // defensive upper bound only; real ceiling is whatever rows exist
const MAX_COST_PXN = 100000000; // matches miner_catalog.price_pxn's own upper bound

const VALID_ACTIONS = new Set(["list", "update", "reset"]);

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

/** Strict validation for `fromLevel`: JSON number, integer, within [MIN_FROM_LEVEL, MAX_FROM_LEVEL]. Never coerces. */
function parseFromLevel(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw)) return null;
  if (!Number.isInteger(raw)) return null;
  if (raw < MIN_FROM_LEVEL || raw > MAX_FROM_LEVEL) return null;
  return raw;
}

/** Strict validation for `costPxn`: JSON number, finite, within [0, MAX_COST_PXN]. Never coerces. */
function parseCostPxn(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw)) return null;
  if (raw < 0 || raw > MAX_COST_PXN) return null;
  return raw;
}

interface MinerUpgradeCostRow {
  id: string;
  from_level: number;
  to_level: number;
  cost_pxn: number | string;
  default_cost_pxn: number | string;
  created_at: string;
  updated_at: string;
}

/** Maps a DB row to the camelCase shape returned to the client. */
function formatCost(row: MinerUpgradeCostRow) {
  return {
    id: row.id,
    fromLevel: row.from_level,
    toLevel: row.to_level,
    costPxn: Number(row.cost_pxn),
    defaultCostPxn: Number(row.default_cost_pxn),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
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

  const action = rawBody.action;
  if (typeof action !== "string" || !VALID_ACTIONS.has(action)) {
    return jsonResponse(
      { success: false, message: "action must be one of: list, update, reset" },
      400,
    );
  }

  // Per-action field validation, done up front so a malformed request
  // never reaches auth or the database. Note: "toLevel" is never
  // read from the request body under any action — it is always
  // derived server-side as fromLevel + 1.
  let fromLevel: number | null = null;
  let costPxn: number | null = null;

  if (action === "update") {
    fromLevel = parseFromLevel(rawBody.fromLevel);
    if (fromLevel === null) {
      return jsonResponse(
        { success: false, message: `fromLevel must be an integer >= ${MIN_FROM_LEVEL}` },
        400,
      );
    }
    costPxn = parseCostPxn(rawBody.costPxn);
    if (costPxn === null) {
      return jsonResponse(
        { success: false, message: `costPxn must be a finite number from 0 to ${MAX_COST_PXN}` },
        400,
      );
    }
  } else if (action === "reset") {
    fromLevel = parseFromLevel(rawBody.fromLevel);
    if (fromLevel === null) {
      return jsonResponse(
        { success: false, message: `fromLevel must be an integer >= ${MIN_FROM_LEVEL}` },
        400,
      );
    }
  }
  // action === "list" needs no field validation.

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[admin-miner-upgrade-cost] server misconfigured:",
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
      "[admin-miner-upgrade-cost] is_current_user_admin check failed:",
      isAdminError.message,
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }
  if (isAdminData !== true) {
    return jsonResponse(FORBIDDEN, 403);
  }

  // Service-role client — the only client that may read/write
  // miner_upgrade_costs from this function. RLS on that table has no
  // client policy at all (see 0026_admin_miner_upgrade_costs.sql), so
  // a service-role client is the only way to touch it outside the SQL
  // editor; this Edge Function is that path.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[admin-miner-upgrade-cost] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  try {
    if (action === "list") {
      const { data, error } = await admin
        .from("miner_upgrade_costs")
        .select("*")
        .order("from_level", { ascending: true });

      if (error) {
        console.error("[admin-miner-upgrade-cost] list failed:", error.message);
        return jsonResponse({ success: false, message: "Could not load upgrade costs" }, 500);
      }

      const rows = (data ?? []) as MinerUpgradeCostRow[];
      return jsonResponse({ success: true, costs: rows.map(formatCost) }, 200);
    }

    if (action === "update") {
      const toLevel = (fromLevel as number) + 1;
      const { data, error } = await admin
        .from("miner_upgrade_costs")
        .update({ cost_pxn: costPxn })
        .eq("from_level", fromLevel as number)
        .eq("to_level", toLevel)
        .select("*")
        .maybeSingle();

      if (error) {
        console.error("[admin-miner-upgrade-cost] update failed:", error.message);
        return jsonResponse({ success: false, message: "Could not update upgrade cost" }, 500);
      }

      if (!data) {
        return jsonResponse(NOT_FOUND, 404);
      }

      return jsonResponse({ success: true, cost: formatCost(data as MinerUpgradeCostRow) }, 200);
    }

    if (action === "reset") {
      const toLevel = (fromLevel as number) + 1;

      // Read default_cost_pxn first, then write it into cost_pxn for
      // the SAME row — never recomputed, never read from any other
      // table (miner_catalog, miner_upgrade_config are never touched
      // by this function at all).
      const { data: existing, error: readError } = await admin
        .from("miner_upgrade_costs")
        .select("default_cost_pxn")
        .eq("from_level", fromLevel as number)
        .eq("to_level", toLevel)
        .maybeSingle();

      if (readError) {
        console.error("[admin-miner-upgrade-cost] reset lookup failed:", readError.message);
        return jsonResponse({ success: false, message: "Could not reset upgrade cost" }, 500);
      }

      if (!existing) {
        return jsonResponse(NOT_FOUND, 404);
      }

      const { data, error } = await admin
        .from("miner_upgrade_costs")
        .update({ cost_pxn: (existing as { default_cost_pxn: number | string }).default_cost_pxn })
        .eq("from_level", fromLevel as number)
        .eq("to_level", toLevel)
        .select("*")
        .maybeSingle();

      if (error) {
        console.error("[admin-miner-upgrade-cost] reset failed:", error.message);
        return jsonResponse({ success: false, message: "Could not reset upgrade cost" }, 500);
      }

      if (!data) {
        return jsonResponse(NOT_FOUND, 404);
      }

      return jsonResponse({ success: true, cost: formatCost(data as MinerUpgradeCostRow) }, 200);
    }

    // Unreachable — action was validated against VALID_ACTIONS above.
    return jsonResponse({ success: false, message: "Unsupported action" }, 400);
  } catch (err) {
    console.error(
      "[admin-miner-upgrade-cost] unexpected error:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }
});
