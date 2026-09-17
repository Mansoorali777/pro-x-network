// Pro-X Network — auth rate limiting.
//
// Simple, DB-backed fixed-window limiter keyed by caller IP. Backed
// by public.auth_attempts (service_role only — see migration
// 0012_auth_rate_limiting.sql). A DB-backed approach (rather than an
// in-memory counter) was chosen because Edge Functions run as many
// independent, short-lived instances — an in-memory counter would
// not be shared across them and would under-count real abuse.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const WINDOW_SECONDS = 5 * 60; // 5 minutes
const MAX_ATTEMPTS_PER_WINDOW = 20; // per IP, across success + failure

export function getClientIp(req: Request): string | null {
  // Supabase Edge Functions run behind a proxy; these are the headers
  // it (and the underlying Deno Deploy/Cloudflare path) populate.
  const forwardedFor = req.headers.get("x-forwarded-for");
  if (forwardedFor) return forwardedFor.split(",")[0].trim();
  const cfIp = req.headers.get("cf-connecting-ip");
  if (cfIp) return cfIp;
  return null;
}

/** Returns true if this IP is currently allowed to attempt auth. */
export async function checkRateLimit(
  supabase: SupabaseClient,
  ipAddress: string | null,
): Promise<{ allowed: boolean }> {
  if (!ipAddress) {
    // No IP available (e.g. local dev without a proxy) — fail open
    // rather than lock out local testing; every deployed environment
    // in front of Supabase does set one of the headers above.
    return { allowed: true };
  }

  const windowStart = new Date(Date.now() - WINDOW_SECONDS * 1000).toISOString();
  const { count, error } = await supabase
    .from("auth_attempts")
    .select("id", { count: "exact", head: true })
    .eq("ip_address", ipAddress)
    .gte("created_at", windowStart);

  if (error) {
    // If the rate-limit check itself fails, fail open on the limit
    // decision but the caller will still log this attempt — an
    // outage in this table should not take down login entirely.
    console.error("[auth-telegram] rate limit check failed:", error.message);
    return { allowed: true };
  }

  return { allowed: (count ?? 0) < MAX_ATTEMPTS_PER_WINDOW };
}

export async function recordAttempt(
  supabase: SupabaseClient,
  params: { ipAddress: string | null; telegramUserId: number | null; success: boolean; reason: string },
): Promise<void> {
  const { error } = await supabase.from("auth_attempts").insert({
    ip_address: params.ipAddress,
    telegram_user_id: params.telegramUserId,
    success: params.success,
    reason: params.reason,
  });
  if (error) {
    // Never let audit logging failures break the auth response —
    // just surface it in the function logs.
    console.error("[auth-telegram] failed to record auth attempt:", error.message);
  }
}
