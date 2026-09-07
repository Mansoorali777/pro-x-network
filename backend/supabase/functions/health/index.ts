// Pro-X Network — Health Check Edge Function
//
// Purpose: a simple, unauthenticated endpoint to confirm the backend
// foundation is deployed and correctly configured. It does NOT touch
// game state, the database rows for players, or any secret value's
// contents — it only reports whether expected secrets are *present*.
//
// GET  /functions/v1/health
//
// Response 200 (all required secrets present):
//   { "status": "ok", "service": "pro-x-network-backend", "timestamp": "...", "checks": { ... } }
//
// Response 503 (backend deployed, but missing configuration):
//   { "status": "degraded", ... }
//
// Response 500 (unexpected error):
//   { "status": "error", "message": "..." }

import { handleCors, jsonResponse } from "../_shared/cors.ts";

// Secrets this function checks FOR PRESENCE ONLY — it never reads or
// returns their values. Extend this list as later migration steps add
// secrets that must exist for the backend to function correctly.
const REQUIRED_SECRETS = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY"];

Deno.serve(async (req: Request) => {
  const preflight = handleCors(req);
  if (preflight) return preflight;

  try {
    const missing = REQUIRED_SECRETS.filter((name) => !Deno.env.get(name));

    const status = missing.length === 0 ? "ok" : "degraded";

    return jsonResponse(
      {
        status,
        service: "pro-x-network-backend",
        timestamp: new Date().toISOString(),
        checks: {
          environment:
            missing.length === 0
              ? "all required secrets present"
              : `missing: ${missing.join(", ")}`,
        },
      },
      status === "ok" ? 200 : 503,
    );
  } catch (err) {
    return jsonResponse(
      {
        status: "error",
        message: err instanceof Error ? err.message : "Unknown error",
      },
      500,
    );
  }
});
