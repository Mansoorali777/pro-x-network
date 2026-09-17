// Pro-X Network — "get-miner-upgrade-costs" Edge Function.
//
// POST /functions/v1/get-miner-upgrade-costs
//
// Read-only, PLAYER-FACING endpoint. Returns every configured
// public.miner_upgrade_costs row (from_level, to_level, cost_pxn,
// default_cost_pxn), ordered by from_level ascending, so the Mini
// App can show the live, admin-configured PXN cost for every miner
// upgrade level — without exposing any way to change those costs.
//
// This file does NOT modify upgrade_miner(), does NOT modify any
// miner upgrade formula, does NOT modify admin-miner-upgrade-cost,
// does NOT modify any PXN balance logic, does NOT introduce any
// custom JWT/JWT secret, and does NOT touch miner_catalog,
// mining_config, mining_state, mining_inventory, or any existing
// migration, RLS policy, or RPC. It adds exactly one new, strictly
// read-only Edge Function.
//
// Authentication (identical caller-identity pattern to functions/me,
// functions/get-mining-inventory, and the identity half of
// functions/admin-miner-upgrade-cost — see those files):
//   - A per-request, caller-scoped supabase-js client (anon key + the
//     caller's own `Authorization: Bearer <token>`) is used ONLY for
//     auth.getUser() — i.e. to confirm this is a real, currently
//     valid Supabase Auth session. Never used for any other read.
//   - If auth.getUser() fails (missing/malformed header, invalid or
//     expired token): 401 Unauthorized.
//   - No admin/role check is performed — any authenticated player may
//     call this endpoint, since live upgrade costs are exactly what
//     every player needs to see before upgrading a miner. This is
//     the deliberate difference from admin-miner-upgrade-cost (which
//     additionally requires is_current_user_admin() = true, because
//     it can also WRITE costs).
//
// Database access:
//   - public.miner_upgrade_costs has Row Level Security enabled with
//     ZERO policies for anon/authenticated (see
//     0026_admin_miner_upgrade_costs.sql) — Postgres denies all
//     access, including SELECT, to those roles by default. A
//     caller-scoped (anon-key) client can therefore never read this
//     table, regardless of whether the caller is authenticated.
//   - This function reads the table using the shared service-role
//     admin client (getSupabaseAdmin(), see
//     backend/supabase/functions/_shared/supabaseAdmin.ts), which
//     bypasses RLS by design — the same pattern already used by
//     admin-miner-upgrade-cost's own "list" action. The admin client
//     is only ever constructed AFTER auth.getUser() has already
//     succeeded above, and is used for exactly one SELECT.
//   - Strictly read-only. No insert/update/delete of any kind, on
//     this table or any other. There is no action/mutation field in
//     the request body at all — this function does one thing.
//   - SUPABASE_SERVICE_ROLE_KEY is read only from Deno.env (Supabase
//     secrets, via _shared/env.ts -> _shared/supabaseAdmin.ts), never
//     present in any response, and never sent to or usable by the
//     frontend.
//
// Response shapes:
//   200: { success: true, costs: [ { fromLevel, toLevel, costPxn,
//          defaultCostPxn }, ... ] }   (empty array, not an error, if
//          the table has no rows)
//   401: { success: false, message: "Unauthorized" }
//   405: { success: false, message: "Method not allowed" }
//   500: { success: false, message: "..." }   (server misconfiguration
//          or unexpected database error only — never the underlying
//          error detail or any secret)
//
// Never logs the access token, the service-role key, or any other
// secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;
const SERVICE_UNAVAILABLE = { success: false, message: "Service temporarily unavailable" } as const;

interface MinerUpgradeCostRow {
  from_level: number;
  to_level: number;
  cost_pxn: number | string;
  default_cost_pxn: number | string;
}

/** Maps a DB row to the camelCase shape returned to the client, coercing numeric(...) columns (which supabase-js returns as strings) into real JS numbers. */
function formatCost(row: MinerUpgradeCostRow) {
  return {
    fromLevel: row.from_level,
    toLevel: row.to_level,
    costPxn: Number(row.cost_pxn),
    defaultCostPxn: Number(row.default_cost_pxn),
  };
}

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
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
      "[get-miner-upgrade-costs] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  // Per-request, caller-scoped client — used ONLY to verify the
  // caller's own identity via auth.getUser() below. Never used for
  // any database read: miner_upgrade_costs has zero RLS policies for
  // this role, so a query against it here would always return empty,
  // not an authorization decision — the actual read happens further
  // down, via the service-role admin client, only once we already
  // know the caller is a valid authenticated user.
  const callerClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  // --- Validate the token via the normal Supabase Auth mechanism. ---
  // getUser() asks Supabase's Auth server to verify the token; we
  // never decode or trust the JWT's claims ourselves, and no custom
  // JWT or JWT secret is used anywhere in this file.
  const { data: authData, error: authError } = await callerClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }

  // Service-role client — the only client that can read
  // miner_upgrade_costs, since that table has no client-role RLS
  // policy at all (see 0026_admin_miner_upgrade_costs.sql). Only
  // constructed after the caller has already been confirmed
  // authenticated above. Used for exactly one read-only SELECT.
  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[get-miner-upgrade-costs] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse(SERVICE_UNAVAILABLE, 500);
  }

  const { data, error } = await admin
    .from("miner_upgrade_costs")
    .select("from_level, to_level, cost_pxn, default_cost_pxn")
    .order("from_level", { ascending: true });

  if (error) {
    console.error("[get-miner-upgrade-costs] list failed:", error.message);
    return jsonResponse({ success: false, message: "Could not load upgrade costs" }, 500);
  }

  const rows = (data ?? []) as MinerUpgradeCostRow[];
  return jsonResponse({ success: true, costs: rows.map(formatCost) }, 200);
});
