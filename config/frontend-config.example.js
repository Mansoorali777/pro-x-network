// Pro-X Network — frontend backend config template.
//
// Copy this file to `frontend-config.js` (same folder) and fill in
// your real project values, OR just edit frontend-config.js directly
// — a placeholder copy already ships alongside this file so the app
// keeps loading with no backend configured.
//
// SUPABASE_ANON_KEY is a PUBLIC key by design — Supabase's security
// model expects it to ship in client code, with real protection coming
// from Row Level Security policies on the database and from
// verify_jwt / in-function checks on Edge Functions. It is kept in its
// own file (rather than hardcoded in index.html) so it's obvious where
// it lives, and so different environments (local/staging/prod) can
// swap it without touching app code.
//
// NEVER put SUPABASE_SERVICE_ROLE_KEY, TELEGRAM_BOT_TOKEN, or any TON
// key/seed phrase in this file or anywhere else under config/ or js/ —
// those are server-only secrets (see backend/supabase/.env.example).

window.PROX_CONFIG = {
  SUPABASE_URL: "https://YOUR_PROJECT_REF.supabase.co",
  SUPABASE_ANON_KEY: "your-anon-public-key",
  // Edge Functions are served from `${SUPABASE_URL}/functions/v1`.
  FUNCTIONS_URL: "https://YOUR_PROJECT_REF.supabase.co/functions/v1",
};
