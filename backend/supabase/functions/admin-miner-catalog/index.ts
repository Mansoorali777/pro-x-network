// Pro-X Network — "admin-miner-catalog" Edge Function.
//
// POST /functions/v1/admin-miner-catalog
//
// Admin-only CRUD surface for public.miner_catalog (see
// 0021_miner_catalog.sql). This is the ONLY entry point intended to
// write to that table from outside the SQL editor — it does NOT
// touch mining_config, mining_state, mining_inventory, users,
// auth-telegram, accrue-mining, purchase-miner, or
// set-miner-applied, and it does NOT modify any existing RLS policy
// on miner_catalog (the player-facing "select active rows" policy is
// untouched; this file only ever uses the service-role client, which
// bypasses RLS entirely, exactly like admin-set-mining-speed).
//
// Request body — a single JSON object with an "action" field:
//
//   List:       { "action": "list" }
//   Create:     { "action": "create", "minerTier": <int 1-1000>,
//                 "minerName": <string 1-200>, "minerIcon": <string 1-500>,
//                 "pricePxn": <number 0-100000000>,
//                 "miningSpeed": <number 0-100000>,
//                 "isActive": <boolean, optional, default true> }
//   Update:     { "action": "update", "id": <uuid>,
//                 "minerTier"?, "minerName"?, "minerIcon"?,
//                 "pricePxn"?, "miningSpeed"?, "isActive"? }
//                 (at least one updatable field required)
//   Deactivate: { "action": "deactivate", "id": <uuid> }
//   Activate:   { "action": "activate", "id": <uuid> }
//   Delete:     { "action": "delete", "id": <uuid> }
//
// Authentication & authorization (identical caller-identity pattern
// to admin-set-mining-speed / me / purchase-miner / accrue-mining —
// see those files):
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
//     or write miner_catalog. SUPABASE_SERVICE_ROLE_KEY is read only
//     from Deno.env (Supabase secrets), never present in any
//     response, and never sent to or usable by the frontend.
//
// Data-integrity guarantees:
//   - miner_catalog has one row per TIER, not per owned unit — owned
//     units live in public.mining_inventory (see 0014_mining_inventory.sql)
//     and denormalize miner_name/miner_icon/miner_speed at purchase
//     time. This function never reads or writes mining_inventory, so
//     deactivating, editing, or deleting a catalog row can NEVER
//     retroactively change what an existing owner already has, refund
//     PXN, or alter any balance.
//   - deactivate/activate only ever flip is_active — every other
//     column, and every mining_inventory row, is left untouched.
//   - delete only ever removes the single miner_catalog row matched
//     by id — no cascade, no mining_inventory write, no balance
//     change of any kind.
//   - create/update rely on miner_catalog's existing UNIQUE
//     (miner_tier) constraint for duplicate-tier detection (Postgres
//     error 23505) rather than a racy read-then-write check, and
//     that conflict is mapped to a clean 409 response instead of a
//     raw database error.
//   - No new RLS policy, table, or migration is created or modified
//     by this file. The only client write policy remains "none" —
//     writes only ever happen via this service-role-backed function.
//
// Response shapes:
//   200 list:       { success: true, miners: [...] }
//   200 mutation:    { success: true, miner: {...} }
//   400: { success: false, message: "..." }   (malformed/invalid input)
//   401: { success: false, message: "Unauthorized" }
//   403: { success: false, message: "Forbidden" }
//   404: { success: false, message: "Miner catalog entry not found" }
//   405: method not allowed
//   409: { success: false, message: "..." }   (duplicate miner tier)
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
const NOT_FOUND = { success: false, message: "Miner catalog entry not found" } as const;
const SERVICE_UNAVAILABLE = { success: false, message: "Service temporarily unavailable" } as const;

// Postgres unique_violation SQLSTATE — raised when miner_tier already
// exists (miner_catalog_miner_tier_key, see 0021_miner_catalog.sql).
const PG_ERR_UNIQUE_VIOLATION = "23505";

const MIN_TIER = 1;
const MAX_TIER = 1000;
const MAX_NAME_LEN = 200;
const MAX_ICON_LEN = 500;
const MAX_PRICE = 100000000;
const MAX_SPEED = 100000;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const VALID_ACTIONS = new Set([
  "list",
  "create",
  "update",
  "deactivate",
  "activate",
  "delete",
]);

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

/** Strict validation for `id`: present, a JSON string, a valid UUID. Never coerces. */
function parseId(body: Record<string, unknown>): string | null {
  const raw = body.id;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!UUID_RE.test(trimmed)) return null;
  return trimmed;
}

/** Strict validation for `minerTier`: JSON number, integer, within [MIN_TIER, MAX_TIER]. */
function parseMinerTier(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw)) return null;
  if (!Number.isInteger(raw)) return null;
  if (raw < MIN_TIER || raw > MAX_TIER) return null;
  return raw;
}

/** Strict validation for `minerName`: JSON string, length 1-200. Never trims/coerces. */
function parseMinerName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  if (raw.length < 1 || raw.length > MAX_NAME_LEN) return null;
  return raw;
}

/** Strict validation for `minerIcon`: JSON string, length 1-500. Format intentionally unconstrained (matches schema). */
function parseMinerIcon(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  if (raw.length < 1 || raw.length > MAX_ICON_LEN) return null;
  return raw;
}

/** Strict validation for `pricePxn`: JSON number, finite, within [0, MAX_PRICE]. */
function parsePricePxn(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw)) return null;
  if (raw < 0 || raw > MAX_PRICE) return null;
  return raw;
}

/** Strict validation for `miningSpeed`: JSON number, finite, within [0, MAX_SPEED]. */
function parseMiningSpeed(raw: unknown): number | null {
  if (typeof raw !== "number") return null;
  if (!Number.isFinite(raw)) return null;
  if (raw < 0 || raw > MAX_SPEED) return null;
  return raw;
}

/** Strict validation for `isActive`: JSON boolean only (no truthy coercion). */
function parseIsActive(raw: unknown): boolean | null {
  if (typeof raw !== "boolean") return null;
  return raw;
}

interface MinerCatalogRow {
  id: string;
  miner_tier: number;
  miner_name: string;
  miner_icon: string;
  price_pxn: number | string;
  mining_speed: number | string;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

/** Maps a DB row to the camelCase shape returned to the client. */
function formatMiner(row: MinerCatalogRow) {
  return {
    id: row.id,
    minerTier: row.miner_tier,
    minerName: row.miner_name,
    minerIcon: row.miner_icon,
    pricePxn: Number(row.price_pxn),
    miningSpeed: Number(row.mining_speed),
    isActive: row.is_active,
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
      {
        success: false,
        message: "action must be one of: list, create, update, deactivate, activate, delete",
      },
      400,
    );
  }

  // Per-action field validation, done up front so a malformed request
  // never reaches auth or the database.
  let id: string | null = null;
  let minerTier: number | null = null;
  let minerName: string | null = null;
  let minerIcon: string | null = null;
  let pricePxn: number | null = null;
  let miningSpeed: number | null = null;
  let isActive: boolean | null = null;

  if (action === "create") {
    minerTier = parseMinerTier(rawBody.minerTier);
    if (minerTier === null) {
      return jsonResponse(
        { success: false, message: `minerTier must be an integer from ${MIN_TIER} to ${MAX_TIER}` },
        400,
      );
    }
    minerName = parseMinerName(rawBody.minerName);
    if (minerName === null) {
      return jsonResponse(
        { success: false, message: `minerName must be a string from 1 to ${MAX_NAME_LEN} characters` },
        400,
      );
    }
    minerIcon = parseMinerIcon(rawBody.minerIcon);
    if (minerIcon === null) {
      return jsonResponse(
        { success: false, message: `minerIcon must be a non-empty string up to ${MAX_ICON_LEN} characters` },
        400,
      );
    }
    pricePxn = parsePricePxn(rawBody.pricePxn);
    if (pricePxn === null) {
      return jsonResponse(
        { success: false, message: `pricePxn must be a finite number from 0 to ${MAX_PRICE}` },
        400,
      );
    }
    miningSpeed = parseMiningSpeed(rawBody.miningSpeed);
    if (miningSpeed === null) {
      return jsonResponse(
        { success: false, message: `miningSpeed must be a finite number from 0 to ${MAX_SPEED}` },
        400,
      );
    }
    // isActive is optional on create — defaults to true when omitted.
    if (rawBody.isActive === undefined) {
      isActive = true;
    } else {
      isActive = parseIsActive(rawBody.isActive);
      if (isActive === null) {
        return jsonResponse({ success: false, message: "isActive must be a boolean" }, 400);
      }
    }
  } else if (action === "update") {
    id = parseId(rawBody);
    if (id === null) {
      return jsonResponse({ success: false, message: "id must be a valid UUID" }, 400);
    }

    if (rawBody.minerTier !== undefined) {
      minerTier = parseMinerTier(rawBody.minerTier);
      if (minerTier === null) {
        return jsonResponse(
          { success: false, message: `minerTier must be an integer from ${MIN_TIER} to ${MAX_TIER}` },
          400,
        );
      }
    }
    if (rawBody.minerName !== undefined) {
      minerName = parseMinerName(rawBody.minerName);
      if (minerName === null) {
        return jsonResponse(
          { success: false, message: `minerName must be a string from 1 to ${MAX_NAME_LEN} characters` },
          400,
        );
      }
    }
    if (rawBody.minerIcon !== undefined) {
      minerIcon = parseMinerIcon(rawBody.minerIcon);
      if (minerIcon === null) {
        return jsonResponse(
          { success: false, message: `minerIcon must be a non-empty string up to ${MAX_ICON_LEN} characters` },
          400,
        );
      }
    }
    if (rawBody.pricePxn !== undefined) {
      pricePxn = parsePricePxn(rawBody.pricePxn);
      if (pricePxn === null) {
        return jsonResponse(
          { success: false, message: `pricePxn must be a finite number from 0 to ${MAX_PRICE}` },
          400,
        );
      }
    }
    if (rawBody.miningSpeed !== undefined) {
      miningSpeed = parseMiningSpeed(rawBody.miningSpeed);
      if (miningSpeed === null) {
        return jsonResponse(
          { success: false, message: `miningSpeed must be a finite number from 0 to ${MAX_SPEED}` },
          400,
        );
      }
    }
    if (rawBody.isActive !== undefined) {
      isActive = parseIsActive(rawBody.isActive);
      if (isActive === null) {
        return jsonResponse({ success: false, message: "isActive must be a boolean" }, 400);
      }
    }

    if (
      minerTier === null &&
      minerName === null &&
      minerIcon === null &&
      pricePxn === null &&
      miningSpeed === null &&
      isActive === null
    ) {
      return jsonResponse(
        { success: false, message: "At least one updatable field must be provided" },
        400,
      );
    }
  } else if (action === "deactivate" || action === "activate" || action === "delete") {
    id = parseId(rawBody);
    if (id === null) {
      return jsonResponse({ success: false, message: "id must be a valid UUID" }, 400);
    }
  }
  // action === "list" needs no field validation.

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error(
      "[admin-miner-catalog] server misconfigured:",
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
      "[admin-miner-catalog] is_current_user_admin check failed:",
      isAdminError.message,
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }
  if (isAdminData !== true) {
    return jsonResponse(FORBIDDEN, 403);
  }

  // Service-role client — the only client that may read/write
  // miner_catalog from this function. RLS on miner_catalog has no
  // authenticated-role write policy at all (see 0021_miner_catalog.sql),
  // so a service-role client is the only way to write to this table
  // outside the SQL editor; this Edge Function is that path.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[admin-miner-catalog] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  try {
    if (action === "list") {
      const { data, error } = await admin
        .from("miner_catalog")
        .select("*")
        .order("miner_tier", { ascending: true });

      if (error) {
        console.error("[admin-miner-catalog] list failed:", error.message);
        return jsonResponse({ success: false, message: "Could not load miner catalog" }, 500);
      }

      const rows = (data ?? []) as MinerCatalogRow[];
      return jsonResponse({ success: true, miners: rows.map(formatMiner) }, 200);
    }

    if (action === "create") {
      const { data, error } = await admin
        .from("miner_catalog")
        .insert({
          miner_tier: minerTier,
          miner_name: minerName,
          miner_icon: minerIcon,
          price_pxn: pricePxn,
          mining_speed: miningSpeed,
          is_active: isActive,
        })
        .select("*")
        .single();

      if (error) {
        if ((error as { code?: string }).code === PG_ERR_UNIQUE_VIOLATION) {
          return jsonResponse(
            { success: false, message: `A miner catalog entry with tier ${minerTier} already exists` },
            409,
          );
        }
        console.error("[admin-miner-catalog] create failed:", error.message);
        return jsonResponse({ success: false, message: "Could not create miner catalog entry" }, 500);
      }

      return jsonResponse({ success: true, miner: formatMiner(data as MinerCatalogRow) }, 200);
    }

    if (action === "update") {
      const patch: Record<string, unknown> = {};
      if (minerTier !== null) patch.miner_tier = minerTier;
      if (minerName !== null) patch.miner_name = minerName;
      if (minerIcon !== null) patch.miner_icon = minerIcon;
      if (pricePxn !== null) patch.price_pxn = pricePxn;
      if (miningSpeed !== null) patch.mining_speed = miningSpeed;
      if (isActive !== null) patch.is_active = isActive;

      const { data, error } = await admin
        .from("miner_catalog")
        .update(patch)
        .eq("id", id as string)
        .select("*")
        .maybeSingle();

      if (error) {
        if ((error as { code?: string }).code === PG_ERR_UNIQUE_VIOLATION) {
          return jsonResponse(
            { success: false, message: "Another miner catalog entry already uses that tier" },
            409,
          );
        }
        console.error("[admin-miner-catalog] update failed:", error.message);
        return jsonResponse({ success: false, message: "Could not update miner catalog entry" }, 500);
      }

      if (!data) {
        return jsonResponse(NOT_FOUND, 404);
      }

      return jsonResponse({ success: true, miner: formatMiner(data as MinerCatalogRow) }, 200);
    }

    if (action === "activate" || action === "deactivate") {
      const { data, error } = await admin
        .from("miner_catalog")
        .update({ is_active: action === "activate" })
        .eq("id", id as string)
        .select("*")
        .maybeSingle();

      if (error) {
        console.error(`[admin-miner-catalog] ${action} failed:`, error.message);
        return jsonResponse({ success: false, message: "Could not update miner catalog entry" }, 500);
      }

      if (!data) {
        return jsonResponse(NOT_FOUND, 404);
      }

      return jsonResponse({ success: true, miner: formatMiner(data as MinerCatalogRow) }, 200);
    }

    if (action === "delete") {
      // Deletes ONLY the matched miner_catalog row. mining_inventory
      // rows denormalize miner_name/miner_icon/miner_speed at
      // purchase time (see 0014_mining_inventory.sql) and carry no
      // foreign key to miner_catalog, so this can never cascade into,
      // modify, or refund any existing player's inventory or balance.
      const { data, error } = await admin
        .from("miner_catalog")
        .delete()
        .eq("id", id as string)
        .select("*")
        .maybeSingle();

      if (error) {
        console.error("[admin-miner-catalog] delete failed:", error.message);
        return jsonResponse({ success: false, message: "Could not delete miner catalog entry" }, 500);
      }

      if (!data) {
        return jsonResponse(NOT_FOUND, 404);
      }

      return jsonResponse({ success: true, miner: formatMiner(data as MinerCatalogRow) }, 200);
    }

    // Unreachable — action was validated against VALID_ACTIONS above.
    return jsonResponse({ success: false, message: "Unsupported action" }, 400);
  } catch (err) {
    console.error(
      "[admin-miner-catalog] unexpected error:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }
});
