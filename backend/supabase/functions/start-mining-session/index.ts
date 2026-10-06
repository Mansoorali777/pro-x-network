// Pro-X Network — "start-mining-session" Edge Function.
//
// POST /functions/v1/start-mining-session
//
// Starts (or restarts) the caller's 8-hour mining session by
// delegating entirely to public.start_mining_session (see
// 0057_mining_sessions.sql).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

const UNAUTHORIZED = { success: false, message: "Unauthorized" } as const;

const PG_ERR_INVALID_INPUT = "PXN90";
const PG_ERR_NO_MINING_STATE = "PXN91";

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

interface StartMiningSessionRow {
  session_started_at: string;
  session_ends_at: string;
  level: number;
  claimed_total: number | string;
  pending_claim: number | string;
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
      "[start-mining-session] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonResponse(UNAUTHORIZED, 401);
  }
  const userId = authData.user.id;

  let admin;
  try {
    admin = getSupabaseAdmin();
  } catch (err) {
    console.error(
      "[start-mining-session] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ success: false, message: "Service temporarily unavailable" }, 500);
  }

  const { data: rpcData, error: rpcError } = await admin
    .rpc("start_mining_session", { p_user_id: userId })
    .maybeSingle();

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;

    switch (code) {
      case PG_ERR_INVALID_INPUT:
        return jsonResponse({ success: false, message: "Invalid request" }, 400);
      case PG_ERR_NO_MINING_STATE:
        return jsonResponse(
          { success: false, message: "Mining data not ready yet — please try again in a moment" },
          409,
        );
      default:
        console.error("[start-mining-session] start_mining_session RPC failed:", rpcError.message);
        return jsonResponse({ success: false, message: "Could not start mining session" }, 500);
    }
  }

  const row = rpcData as StartMiningSessionRow | null;
  if (!row) {
    console.error("[start-mining-session] start_mining_session RPC returned no row");
    return jsonResponse({ success: false, message: "Could not start mining session" }, 500);
  }

  return jsonResponse(
    {
      success: true,
      user_id: userId,
      session_started_at: row.session_started_at,
      session_ends_at: row.session_ends_at,
      level: row.level,
      claimed_total: Number(row.claimed_total),
      pending_claim: Number(row.pending_claim),
    },
    200,
  );
});