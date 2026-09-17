// Shared environment-variable access for all Pro-X Network Edge
// Functions. Centralizing this means every function fails the same,
// clear way if a secret is missing — instead of a raw `undefined`
// silently propagating into a database call or an API request.
//
// These values are configured with `supabase secrets set` (or, for
// local development, `supabase/.env` — see backend/README.md) and are
// NEVER present in any file committed to source control, and NEVER
// sent to the frontend.

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

/** Optional env var — returns undefined instead of throwing if unset. */
export function optionalEnv(name: string): string | undefined {
  return Deno.env.get(name) ?? undefined;
}

/**
 * The env vars every function that touches the database needs.
 * SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically
 * by the Supabase platform for Edge Functions — they do not need to be
 * set manually via `supabase secrets set`, but they DO need to be set
 * manually in `supabase/.env` for local `supabase functions serve`.
 */
export function getSupabaseAdminEnv() {
  return {
    url: requireEnv("SUPABASE_URL"),
    serviceRoleKey: requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
  };
}

/**
 * SUPABASE_URL and SUPABASE_ANON_KEY, needed for the non-admin client
 * used to verify a magic-link token during login (see auth-telegram).
 * Both are auto-injected by the Supabase platform for deployed Edge
 * Functions — same as getSupabaseAdminEnv's values — but also need
 * to be set manually in `backend/supabase/.env` for local
 * `supabase functions serve`.
 */
export function getSupabasePublicEnv() {
  return {
    url: requireEnv("SUPABASE_URL"),
    anonKey: requireEnv("SUPABASE_ANON_KEY"),
  };
}

/**
 * Env vars needed to verify Telegram initData signatures.
 */
export function getTelegramEnv() {
  return {
    botToken: requireEnv("TELEGRAM_BOT_TOKEN"),
  };
}

/**
 * Env vars needed to configure Pro-X authentication behavior.
 *
 * Session issuance itself is now handled entirely by Supabase Auth
 * (see auth-telegram/index.ts: admin.createUser + generateLink +
 * verifyOtp) — there is no Pro-X-signed JWT anymore, so there is no
 * signing secret to configure here. Session token lifetime is
 * controlled by the Supabase project's Auth JWT expiry setting, not
 * by an env var in this codebase.
 */
export function getAuthEnv() {
  const initDataMaxAgeSeconds = parseInt(
    optionalEnv("TELEGRAM_INITDATA_MAX_AGE_SECONDS") ?? "86400", // 24h default
    10,
  );
  return {
    initDataMaxAgeSeconds: Number.isFinite(initDataMaxAgeSeconds) ? initDataMaxAgeSeconds : 86400,
  };
}
