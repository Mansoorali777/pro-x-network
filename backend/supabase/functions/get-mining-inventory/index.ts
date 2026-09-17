// Pro-X Network — "get-mining-inventory" Edge Function.
//
// POST /functions/v1/get-mining-inventory
//
// Read-only endpoint. Returns the calling player's own
// `public.mining_inventory` rows — every owned miner unit — and
// nothing else. This is the read counterpart to the (not yet
// implemented) purchase/apply/remove endpoints: it performs zero
// database writes and is not the place any of that logic lives.
//
// Authentication: identical pattern to functions/me and
// functions/accrue-mining — a per-request, caller-scoped
// supabase-js client (anon key + the caller's own
// `Authorization: Bearer <token>` access token) is used, and
// `auth.getUser()` is the sole source of the caller's identity.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id.
//   - No user id (or any other identity claim) is ever accepted from
//     the request body, a query param, or a header other than
//     Authorization. auth.getUser()'s result is the only identity
//     used anywhere in this function.
//
// Database access:
//   - The SAME per-request, user-scoped client (anon key + the
//     caller's access token) is used to read `public.mining_inventory`,
//     so the table's existing RLS policy
//     (`mining_inventory_select_own`, i.e. `auth.uid() = user_id`) is
//     what actually decides which rows come back. The service-role
//     client is never created or used in this file — this endpoint
//     has no reason to bypass RLS, since a player reading their own
//     inventory is exactly what that policy already allows.
//   - Strictly read-only. No insert/update/delete of any kind, on
//     this table or any other.
//
// Response 200: { "success": true, "inventory": [ ...rows... ] }
//   (an empty array, not an error, when the player owns no miners)
// Response 401: { "success": false, "message": "Unauthorized" }
//   (missing/malformed Authorization header, or invalid/expired token)
// Response 405: { "success": false, "message": "Method not allowed" }
//   (any method other than POST/OPTIONS)
// Response 500: { "success": false, "message": "..." }
//   (server misconfiguration or unexpected database error only —
//   never the underlying error detail or any secret)
//
// Never logs the access token or any other secret.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;

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
      "[get-mining-inventory] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request client, scoped to the caller's own token — never the
  // service-role key. This is what makes both the auth check below
  // and the subsequent table read subject to normal Supabase Auth /
  // RLS rules, exactly as if a browser had made the call directly.
  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  // --- Validate the token via the normal Supabase Auth mechanism. ---
  // getUser() asks Supabase's Auth server to verify the token; we
  // never decode or trust the JWT's claims ourselves, and the
  // resulting user id is the ONLY identity used below — never a
  // value from the request body.
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }

  // --- Read only the caller's own rows, via RLS (mining_inventory_select_own). ---
  // The .eq("user_id", ...) filter is redundant with RLS by design —
  // RLS is the actual enforcement boundary, this is defense in depth
  // and makes the query's intent explicit.
  const { data: inventoryRows, error: dbError } = await userClient
    .from("mining_inventory")
    .select(
      "id, user_id, miner_tier, miner_name, miner_icon, miner_level, miner_speed, is_applied, created_at, updated_at",
    )
    .eq("user_id", authData.user.id)
    .order("created_at", { ascending: true });

  if (dbError) {
    console.error("[get-mining-inventory] database error while loading inventory:", dbError.message);
    return jsonResponse({ success: false, message: "Could not load inventory" }, 500);
  }

  return jsonResponse({ success: true, inventory: inventoryRows ?? [] }, 200);
});
