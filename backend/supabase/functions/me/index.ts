// Pro-X Network — "me" Edge Function.
//
// POST /functions/v1/me
//
// The first authenticated backend endpoint. Returns the calling
// player's own `public.users` row — nothing else, no exceptions.
//
// Authentication:
//   - Reads a real Supabase Auth session access token from the
//     `Authorization: Bearer <token>` header (the same kind of token
//     auth-telegram mints via admin.generateLink + verifyOtp).
//   - The token is verified the normal Supabase Auth way: it is
//     attached to a supabase-js client (anon key, same key already
//     shipped to the frontend) and `auth.getUser()` is called, which
//     asks Supabase's Auth server whether the token is valid. This
//     function never decodes the JWT itself and never trusts a claim
//     it hasn't had Supabase verify first.
//   - `verify_jwt = true` in config.toml means the Supabase platform
//     already rejects missing/malformed/expired tokens before this
//     code even runs. The explicit getUser() call below is a second,
//     independent check inside the function itself (defense in
//     depth), and is also how we obtain the authenticated user's id
//     — we never take a user id or telegram_user_id from the request.
//
// Database access:
//   - The SAME per-request, user-scoped client (anon key + the
//     caller's access token) is used to read `public.users`, so the
//     project's existing RLS policy (`users_select_own`, i.e.
//     `auth.uid() = id`) is what actually decides which row — if
//     any — comes back. The service-role client is never used here,
//     because this endpoint has no reason to bypass RLS.
//   - Read-only. No insert/update/delete.
//
// Response 200: { "success": true, "user": { ...public.users row... } }
// Response 401: { "success": false, "message": "Unauthorized" }
//   (missing/malformed header, invalid/expired token, or no matching
//   users row for this auth identity)
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
      "[me] server misconfigured:",
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
  // never decode or trust the JWT's claims ourselves.
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }

  // --- Read only the caller's own row, via RLS (users_select_own). ---
  const { data: userRow, error: dbError } = await userClient
    .from("users")
    .select("*")
    .eq("id", authData.user.id)
    .maybeSingle();

  if (dbError) {
    console.error("[me] database error while loading user:", dbError.message);
    return jsonResponse({ success: false, message: "Could not load profile" }, 500);
  }

  if (!userRow) {
    // Valid session, but no matching public.users row (or RLS denied
    // it, which for this policy only happens if the ids don't
    // match) — treat the same as "not authenticated" rather than
    // leaking which case it was.
    return jsonResponse(UNAUTHORIZED, 401);
  }

  return jsonResponse({ success: true, user: userRow }, 200);
});
