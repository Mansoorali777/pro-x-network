// Pro-X Network — "get-current-leaderboard" Edge Function.
//
// POST /functions/v1/get-current-leaderboard
//
// Authenticated player read surface for the monthly leaderboard:
// exposes public.get_current_leaderboard()
// (0049_monthly_leaderboard_foundation.sql) to the frontend. Returns
// the current/next period's countdown, configured rank prizes, the
// global top 100, and the caller's own rank/points — nothing else.
// This function does not modify get_current_leaderboard(), 0049,
// 0050, or any other table/RPC/RLS policy, and does not touch
// accrue-mining, claim-mining, me, auth-telegram, or any referral
// function/table — it is a new, independent, read-only endpoint.
//
// Authentication: identical pattern to functions/me/index.ts (kept
// deliberately unchanged as the model for this function):
//   - Reads a real Supabase Auth session access token from the
//     `Authorization: Bearer <token>` header (the same kind of token
//     ProXAuth.getAccessToken() already returns on the frontend).
//   - The token is verified the normal Supabase Auth way: attached to
//     a supabase-js client (anon key, the same key already shipped to
//     the frontend) and `auth.getUser()` is called, which asks
//     Supabase's Auth server whether the token is valid. This
//     function never decodes the JWT itself and never trusts a claim
//     it hasn't had Supabase verify first.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — this function never takes a user id from the request body or
//     query string.
//
// Database access:
//   - The SAME per-request, user-scoped client (anon key + the
//     caller's access token) is used to call
//     public.get_current_leaderboard() via PostgREST's RPC endpoint.
//     That RPC reads `auth.uid()` internally (see 0049) to determine
//     "self" — calling it through this user-scoped client (rather
//     than a service-role client, and rather than passing any
//     caller-supplied id) is what makes auth.uid() resolve correctly
//     to this exact authenticated caller, and is exactly why 0049
//     already grants EXECUTE on this RPC to the `authenticated` role
//     rather than `service_role` only. Nothing about that grant or
//     the RPC itself needs to change for this to work.
//   - Read-only. No insert/update/delete; get_current_leaderboard()
//     itself performs no writes (it does update the internal period
//     status via a helper it calls, which is existing 0049 behavior,
//     unrelated to and unmodified by this function).
//
// Response 200: { "success": true, "leaderboard": { period, status,
//   prizes, top100, self } } — exactly the jsonb object
//   get_current_leaderboard() returns, unwrapped under "leaderboard".
// Response 401: { "success": false, "message": "Unauthorized" }
//   (missing/malformed header, invalid/expired token)
// Response 405: method not allowed
// Response 500: server misconfiguration or unexpected error
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
      "[get-current-leaderboard] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  // Per-request client, scoped to the caller's own token — never the
  // service-role key. This is what makes both the auth check below
  // and the RPC call subject to normal Supabase Auth rules, exactly
  // as if a browser had called the RPC directly, and is what lets
  // public.get_current_leaderboard()'s own auth.uid() resolve to this
  // exact caller.
  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  // --- Validate the token via the normal Supabase Auth mechanism. ---
  // getUser() asks Supabase's Auth server to verify the token; we
  // never decode or trust the JWT's claims ourselves.
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }

  // --- Call the existing RPC exactly as the authenticated caller. ---
  // No arguments: get_current_leaderboard() takes none — it derives
  // "self" entirely from auth.uid() on this user-scoped client.
  const { data: leaderboard, error: rpcError } = await userClient.rpc(
    "get_current_leaderboard",
  );

  if (rpcError) {
    console.error(
      "[get-current-leaderboard] get_current_leaderboard RPC failed:",
      rpcError.message,
    );
    return jsonResponse({ success: false, message: "Could not load leaderboard" }, 500);
  }

  return jsonResponse({ success: true, leaderboard: leaderboard ?? null }, 200);
});
