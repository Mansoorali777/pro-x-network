// Shared CORS handling for all Pro-X Network Edge Functions.
//
// NOTE: "*" is used for Access-Control-Allow-Origin so the Telegram Mini
// App WebView (which does not have a single predictable, stable origin)
// can call these functions. This is safe as long as every function only
// does two things with the request: (a) read data that is meant to be
// public/anon-readable, or (b) verify a caller-supplied identity token
// (e.g. verified Telegram initData) before doing anything sensitive.
// Never rely on Origin/CORS as an access-control mechanism by itself —
// real authorization must happen inside each function.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

/**
 * Call at the top of every Edge Function. Returns a Response if this
 * request was a CORS preflight (OPTIONS) request — the caller should
 * `return` that response immediately. Returns `null` for all other
 * requests, meaning "continue handling the request normally".
 */
export function handleCors(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  return null;
}

/** Small helper so every function returns JSON the same way. */
export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
