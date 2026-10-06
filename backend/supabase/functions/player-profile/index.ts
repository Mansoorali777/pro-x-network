// Pro-X Network — "player-profile" Edge Function.
//
// POST /functions/v1/player-profile
//
// Two actions:
//   Get wallet status:  { "action": "get" }              (default if omitted)
//   Connect wallet:     { "action": "connect_wallet",
//                          "wallet_address": "<string>",
//                          "wallet_network": "ton" }        (network optional, defaults "ton")
//
// This is Phase 2/3's backend profile + wallet-onboarding surface. It
// does NOT create a second auth/profile system: identity is the
// existing public.users row (via auth.uid()), and this function only
// adds a read/write surface for the NEW public.player_wallets table
// (0052_player_wallet_and_withdrawals.sql). It does not read or write
// public.user_profiles, public.mining_state, public.referrals, or any
// marketplace/leaderboard table.
//
// Authentication: identical pattern to functions/me, functions/marketplace,
// functions/admin-users — a per-request, caller-scoped supabase-js
// client (anon key + the caller's own Authorization bearer token) is
// used for auth.getUser(), which is the ONLY source of the caller's
// identity. The service-role client (getSupabaseAdmin()) is used only
// to invoke public.connect_wallet(), which is service_role-only by
// grant. "get" uses the user-scoped client directly against
// player_wallets, relying entirely on the existing
// player_wallets_select_own RLS policy — never the admin client — so
// a caller can only ever read their own row, enforced by Postgres
// itself, not by this file's logic.
//
// wallet_address / wallet_network are the ONLY fields ever read from
// the connect_wallet request body. There is no user_id/owner_id field
// anywhere in this file — the authenticated user's id (from
// auth.getUser()) is the only identity ever passed to the RPC.
//
// Response envelope (both actions):
//   Success: { "success": true, "wallet": { user_id, wallet_address,
//              wallet_network, wallet_connected_at, ... } | null }
//   Error:   { "success": false, "error": { "code": "...", "message": "..." } }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getSupabasePublicEnv } from "../_shared/env.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";

interface AppError {
  code: string;
  message: string;
}

function errorResponse(status: number, code: string, message: string): Response {
  return jsonResponse({ success: false, error: { code, message } as AppError }, status);
}

const UNAUTHORIZED = () => errorResponse(401, "UNAUTHORIZED", "Unauthorized");

function extractBearerToken(req: Request): string | null {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header) return null;
  const match = header.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token.length > 0 ? token : null;
}

// Maps public.connect_wallet()'s PXNxx SQLSTATEs (see
// 0052_player_wallet_and_withdrawals.sql section 5) to a clean
// application error. Never forwards a raw PostgreSQL error message.
function mapPgError(code: string | undefined, rawMessage: string): { status: number; error: AppError } {
  switch (code) {
    case "PXN80":
      return { status: 400, error: { code: "VALIDATION_ERROR", message: "Invalid request" } };
    case "PXN81":
      return { status: 400, error: { code: "INVALID_WALLET", message: "That does not look like a valid TON wallet address" } };
    case "PXN82":
      return { status: 409, error: { code: "WALLET_ALREADY_CONNECTED", message: "A wallet is already connected to this account" } };
    default:
      console.error("[player-profile] unrecognized database error:", code, rawMessage);
      return { status: 500, error: { code: "INTERNAL_ERROR", message: "Something went wrong. Please try again." } };
  }
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return errorResponse(405, "METHOD_NOT_ALLOWED", "Method not allowed");
  }

  const accessToken = extractBearerToken(req);
  if (!accessToken) return UNAUTHORIZED();

  let url: string;
  let anonKey: string;
  try {
    ({ url, anonKey } = getSupabasePublicEnv());
  } catch (err) {
    console.error("[player-profile] server misconfigured:", err instanceof Error ? err.message : "unknown error");
    return errorResponse(500, "INTERNAL_ERROR", "Service temporarily unavailable");
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) return UNAUTHORIZED();
  const userId = authData.user.id;

  let body: unknown = {};
  try {
    const text = await req.text();
    if (text) body = JSON.parse(text);
  } catch {
    return errorResponse(400, "VALIDATION_ERROR", "Request body must be valid JSON");
  }
  const rec = (typeof body === "object" && body !== null ? body : {}) as Record<string, unknown>;
  const action = typeof rec.action === "string" ? rec.action : "get";

  if (action === "get") {
    // RLS (player_wallets_select_own) is what actually restricts this
    // to the caller's own row — the .eq() below is belt-and-suspenders,
    // not the security boundary.
    const { data, error } = await userClient
      .from("player_wallets")
      .select("user_id, wallet_address, wallet_network, wallet_connected_at")
      .eq("user_id", userId)
      .maybeSingle();

    if (error) {
      console.error("[player-profile] get failed:", error.message);
      return errorResponse(500, "INTERNAL_ERROR", "Could not load wallet status");
    }
    return jsonResponse({ success: true, wallet: data ?? null }, 200);
  }

  if (action === "connect_wallet") {
    const walletAddress = typeof rec.wallet_address === "string" ? rec.wallet_address.trim() : "";
    const walletNetwork = typeof rec.wallet_network === "string" && rec.wallet_network.length > 0
      ? rec.wallet_network
      : "ton";

    if (!walletAddress) {
      return errorResponse(400, "INVALID_WALLET", "wallet_address is required");
    }

    const admin = getSupabaseAdmin();
    const { data, error } = await admin.rpc("connect_wallet", {
      p_user_id: userId,
      p_wallet_address: walletAddress,
      p_wallet_network: walletNetwork,
    });

    if (error) {
      const mapped = mapPgError((error as { code?: string }).code, error.message);
      return errorResponse(mapped.status, mapped.error.code, mapped.error.message);
    }

    return jsonResponse({ success: true, wallet: data }, 200);
  }

  return errorResponse(400, "VALIDATION_ERROR", "action must be one of: get, connect_wallet");
});
