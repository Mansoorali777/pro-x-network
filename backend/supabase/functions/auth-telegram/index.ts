// Pro-X Network — Telegram Mini App Authentication Edge Function.
//
// POST /functions/v1/auth-telegram
// Body: { "initData": "<raw Telegram.WebApp.initData string>" }
//
// This is the ONLY place in the backend allowed to decide "who is
// this player". It:
//   1. Verifies initData's signature against TELEGRAM_BOT_TOKEN
//      (never trusts initDataUnsafe, a client-sent user id, a
//      username, or a referral code as identity proof).
//   2. Loads the existing `users` row for that Telegram id, or
//      creates one if this is a first login.
//   3. Ensures a matching Supabase Auth (`auth.users`) row exists,
//      with the SAME id as the `public.users` row, then mints a
//      real Supabase Auth session for it (admin.createUser +
//      admin.generateLink + verifyOtp — see _shared/supabaseAdmin.ts
//      usage below). This is a genuine Supabase session: GoTrue
//      signs it with the project's own key, so auth.uid() and every
//      existing RLS policy work natively — no custom JWT signing.
//
// Response 200:
//   {
//     "user": { "id": "<uuid>", "telegramUserId": 123, "username": "...",
//               "firstName": "...", "lastName": "...", "languageCode": "..." },
//     "session": { "accessToken": "<jwt>", "refreshToken": "<token>",
//                   "expiresAt": "<ISO 8601>" }
//   }
// Response 400: malformed request (missing/malformed initData)
// Response 401: initData failed verification or has expired
// Response 403: this Telegram account is banned
// Response 429: too many attempts from this caller recently
// Response 500: server misconfiguration or unexpected error
//
// Every branch below logs a clear, non-secret reason on failure
// (see _shared/rateLimit.ts's recordAttempt) — never the bot token,
// the service-role key, or the raw initData string itself.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleCors, jsonResponse } from "../_shared/cors.ts";
import { getTelegramEnv, getAuthEnv, getSupabasePublicEnv } from "../_shared/env.ts";
import { verifyTelegramInitData } from "../_shared/telegram.ts";
import { getSupabaseAdmin } from "../_shared/supabaseAdmin.ts";
import { getClientIp, checkRateLimit, recordAttempt } from "../_shared/rateLimit.ts";

/**
 * Deterministic, internal-only email used purely as GoTrue's join
 * key for this user's auth.users row. Never real, never delivered
 * to, never shown to the user. Keyed off the permanent users.id
 * (not the mutable Telegram username).
 */
function syntheticEmailFor(userId: string): string {
  return `tg-${userId}@auth.pro-x-network.internal`;
}

/**
 * True only for the specific "this user already exists" condition
 * Supabase's Admin API returns from createUser — every other error
 * must propagate and fail the request, not be silently swallowed.
 */
function isUserAlreadyExistsError(err: unknown): boolean {
  const anyErr = err as { code?: string; status?: number; message?: string } | null;
  if (!anyErr) return false;
  if (anyErr.code === "email_exists" || anyErr.code === "user_already_exists") return true;
  const msg = (anyErr.message ?? "").toLowerCase();
  return msg.includes("already been registered") || msg.includes("already exists");
}

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  if (req.method !== "POST") {
    return jsonResponse({ status: "error", message: "Method not allowed" }, 405);
  }

  const supabase = getSupabaseAdmin();
  const ipAddress = getClientIp(req);

  // --- Rate limit first, before doing any real work. ---
  const { allowed } = await checkRateLimit(supabase, ipAddress);
  if (!allowed) {
    console.warn(`[auth-telegram] rate limited ip=${ipAddress ?? "unknown"}`);
    await recordAttempt(supabase, {
      ipAddress,
      telegramUserId: null,
      success: false,
      reason: "rate_limited",
    });
    return jsonResponse(
      { status: "error", message: "Too many attempts. Please try again shortly." },
      429,
    );
  }

  // --- Parse the request body. ---
  let body: { initData?: unknown };
  try {
    body = await req.json();
  } catch {
    await recordAttempt(supabase, { ipAddress, telegramUserId: null, success: false, reason: "malformed_body" });
    return jsonResponse({ status: "error", message: "Invalid JSON body" }, 400);
  }

  if (typeof body.initData !== "string" || body.initData.length === 0) {
    await recordAttempt(supabase, { ipAddress, telegramUserId: null, success: false, reason: "missing_init_data" });
    return jsonResponse({ status: "error", message: "initData is required" }, 400);
  }

  // --- Verify the Telegram signature. This is the entire trust boundary. ---
  let botToken: string;
  let authEnv: ReturnType<typeof getAuthEnv>;
  try {
    botToken = getTelegramEnv().botToken;
    authEnv = getAuthEnv();
  } catch (err) {
    console.error(
      "[auth-telegram] server misconfigured:",
      err instanceof Error ? err.message : "unknown error",
    );
    return jsonResponse({ status: "error", message: "Authentication is temporarily unavailable" }, 500);
  }

  const verification = await verifyTelegramInitData(
    body.initData,
    botToken,
    authEnv.initDataMaxAgeSeconds,
  );

  if (!verification.ok) {
    console.warn(`[auth-telegram] verification failed reason=${verification.reason} ip=${ipAddress ?? "unknown"}`);
    await recordAttempt(supabase, {
      ipAddress,
      telegramUserId: null,
      success: false,
      reason: verification.reason,
    });
    const status = verification.reason === "expired" ? 401 : verification.reason === "malformed" ? 400 : 401;
    return jsonResponse({ status: "error", message: "Telegram identity could not be verified" }, status);
  }

  const tgUser = verification.data.user;

  // --- Load or create the user row. telegram_user_id is the only identity key. ---
  let userRow: {
    id: string;
    telegram_user_id: number;
    telegram_username: string | null;
    telegram_first_name: string | null;
    telegram_last_name: string | null;
    language_code: string | null;
    is_premium: boolean;
    is_banned: boolean;
  } | null = null;

  try {
    const { data: existing, error: selectError } = await supabase
      .from("users")
      .select("id, telegram_user_id, telegram_username, telegram_first_name, telegram_last_name, language_code, is_premium, is_banned")
      .eq("telegram_user_id", tgUser.id)
      .maybeSingle();

    if (selectError) throw selectError;

    if (existing) {
      // Refresh display-only fields and last_login_at; never touch
      // is_banned or anything moderation-related here.
      const { data: updated, error: updateError } = await supabase
        .from("users")
        .update({
          telegram_username: tgUser.username ?? null,
          telegram_first_name: tgUser.first_name ?? null,
          telegram_last_name: tgUser.last_name ?? null,
          language_code: tgUser.language_code ?? null,
          is_premium: tgUser.is_premium ?? false,
          last_login_at: new Date().toISOString(),
        })
        .eq("id", existing.id)
        .select("id, telegram_user_id, telegram_username, telegram_first_name, telegram_last_name, language_code, is_premium, is_banned")
        .single();
      if (updateError) throw updateError;
      userRow = updated;
    } else {
      const { data: created, error: insertError } = await supabase
        .from("users")
        .insert({
          telegram_user_id: tgUser.id,
          telegram_username: tgUser.username ?? null,
          telegram_first_name: tgUser.first_name ?? null,
          telegram_last_name: tgUser.last_name ?? null,
          language_code: tgUser.language_code ?? null,
          is_premium: tgUser.is_premium ?? false,
          last_login_at: new Date().toISOString(),
        })
        .select("id, telegram_user_id, telegram_username, telegram_first_name, telegram_last_name, language_code, is_premium, is_banned")
        .single();
      if (insertError) throw insertError;
      userRow = created;
    }
  } catch (err) {
    console.error(
      "[auth-telegram] database error while loading/creating user:",
      err instanceof Error ? err.message : "unknown error",
    );
    await recordAttempt(supabase, {
      ipAddress,
      telegramUserId: tgUser.id,
      success: false,
      reason: "db_error",
    });
    return jsonResponse({ status: "error", message: "Could not complete sign-in" }, 500);
  }

  if (!userRow) {
    // Should be unreachable, but guard anyway rather than issue a
    // session for a user we don't actually have a row for.
    console.error("[auth-telegram] no user row after upsert — this should never happen");
    return jsonResponse({ status: "error", message: "Could not complete sign-in" }, 500);
  }

  if (userRow.is_banned) {
    console.warn(`[auth-telegram] banned account attempted login telegram_user_id=${tgUser.id}`);
    await recordAttempt(supabase, { ipAddress, telegramUserId: tgUser.id, success: false, reason: "banned" });
    return jsonResponse({ status: "error", message: "This account is not allowed to sign in" }, 403);
  }

  // --- Ensure a matching auth.users row exists (same id as public.users). ---
  const syntheticEmail = syntheticEmailFor(userRow.id);

  try {
    const { error: createUserError } = await supabase.auth.admin.createUser({
      id: userRow.id,
      email: syntheticEmail,
      email_confirm: true,
      user_metadata: { telegram_user_id: userRow.telegram_user_id },
    });
    if (createUserError && !isUserAlreadyExistsError(createUserError)) {
      throw createUserError;
    }
  } catch (err) {
    console.error(
      "[auth-telegram] failed to provision auth.users row:",
      err instanceof Error ? err.message : "unknown error",
    );
    await recordAttempt(supabase, {
      ipAddress,
      telegramUserId: tgUser.id,
      success: false,
      reason: "auth_user_provision_failed",
    });
    return jsonResponse({ status: "error", message: "Could not complete sign-in" }, 500);
  }

  // --- Mint a real Supabase Auth session for that user. ---
  let accessToken: string;
  let refreshToken: string;
  let expiresAt: number;
  try {
    const { data: link, error: linkError } = await supabase.auth.admin.generateLink({
      type: "magiclink",
      email: syntheticEmail,
    });
    if (linkError) throw linkError;

    const hashedToken = link?.properties?.hashed_token;
    if (!hashedToken) {
      throw new Error("generateLink returned no hashed_token");
    }

    // Deliberately a separate, non-admin client — verifyOtp is a
    // normal Auth API call and only needs the anon/publishable key,
    // same key already shipped to the frontend. The service-role
    // key is never used past this point.
    const { url: supabaseUrl, anonKey } = getSupabasePublicEnv();
    const anonClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: verified, error: verifyError } = await anonClient.auth.verifyOtp({
      token_hash: hashedToken,
      type: "email",
    });
    if (verifyError) throw verifyError;
    if (!verified?.session) throw new Error("verifyOtp returned no session");

    accessToken = verified.session.access_token;
    refreshToken = verified.session.refresh_token;
    expiresAt = verified.session.expires_at
      ? verified.session.expires_at
      : Math.floor(Date.now() / 1000) + (verified.session.expires_in ?? 3600);
  } catch (err) {
    console.error(
      "[auth-telegram] failed to mint Supabase session:",
      err instanceof Error ? err.message : "unknown error",
    );
    await recordAttempt(supabase, {
      ipAddress,
      telegramUserId: tgUser.id,
      success: false,
      reason: "session_mint_failed",
    });
    return jsonResponse({ status: "error", message: "Could not complete sign-in" }, 500);
  }

  await recordAttempt(supabase, { ipAddress, telegramUserId: tgUser.id, success: true, reason: "ok" });

  return jsonResponse({
    user: {
      id: userRow.id,
      telegramUserId: userRow.telegram_user_id,
      username: userRow.telegram_username,
      firstName: userRow.telegram_first_name,
      lastName: userRow.telegram_last_name,
      languageCode: userRow.language_code,
    },
    session: {
      accessToken,
      refreshToken,
      expiresAt: new Date(expiresAt * 1000).toISOString(),
    },
  });
});
