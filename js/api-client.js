// Pro-X Network — frontend API client (backend foundation).
//
// This module is new infrastructure only. Nothing in index.html's
// existing game logic calls it yet, and it makes no network requests
// on its own — it only runs when something explicitly calls
// `ProXBackend.*`. Loading this file changes nothing about current
// app behavior.
//
// It exists so future migration steps (mining, marketplace, tasks,
// referrals, wallet) have one safe, already-tested place to add
// backend calls, instead of each one hand-rolling its own fetch logic.
//
// Usage (from future code — not wired in yet):
//   const result = await ProXBackend.checkHealth();
//   if (result.ok) {
//     console.log("backend status:", result.data.status);
//   } else {
//     console.warn("backend check failed:", result.error);
//   }

(function (global) {
  "use strict";

  function getConfig() {
    return global.PROX_CONFIG || null;
  }

  /**
   * True only once frontend-config.js has been edited with real
   * project values. False for the placeholder values it ships with,
   * so callers can show a clear "backend not connected yet" state
   * instead of a confusing network error.
   */
  function isConfigured() {
    const cfg = getConfig();
    if (!cfg || !cfg.FUNCTIONS_URL || !cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY) {
      return false;
    }
    if (cfg.SUPABASE_URL.indexOf("YOUR_PROJECT_REF") !== -1) return false;
    if (cfg.SUPABASE_ANON_KEY.indexOf("your-anon") !== -1) return false;
    return true;
  }

  /**
   * Calls a Supabase Edge Function by name and normalizes the result.
   * Always resolves (never throws) with:
   *   { ok: boolean, data: any|null, error: string|null }
   * so callers never need a try/catch of their own.
   */
  async function callFunction(name, options) {
    options = options || {};
    const method = options.method || "GET";
    const body = options.body;
    const timeoutMs = options.timeoutMs || 10000;
    // Optional: a caller's own Supabase Auth access token (e.g. from
    // ProXAuth.getAccessToken()). When provided, it's used as the
    // Authorization bearer instead of the anon key, so the Edge
    // Function can identify the calling user (see functions/me).
    // "apikey" always stays the public anon key — Supabase requires
    // it to identify the project regardless of who the caller is.
    const accessToken = options.accessToken;

    if (!isConfigured()) {
      return {
        ok: false,
        data: null,
        error:
          "Backend not configured yet — edit config/frontend-config.js with your Supabase project values.",
      };
    }

    const cfg = getConfig();
    const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
    const timeoutId = controller
      ? setTimeout(function () { controller.abort(); }, timeoutMs)
      : null;

    try {
      const res = await fetch(cfg.FUNCTIONS_URL + "/" + name, {
        method: method,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer " + (accessToken || cfg.SUPABASE_ANON_KEY),
          "apikey": cfg.SUPABASE_ANON_KEY,
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: controller ? controller.signal : undefined,
      });

      if (timeoutId) clearTimeout(timeoutId);

      let json = null;
      try {
        json = await res.json();
      } catch (parseErr) {
        // Non-JSON or empty response body — leave json as null.
      }

      if (!res.ok) {
        const message =
          (json && (json.message || json.error)) ||
          ("Request failed with status " + res.status);
        return { ok: false, data: json, error: message };
      }

      return { ok: true, data: json, error: null };
    } catch (err) {
      if (timeoutId) clearTimeout(timeoutId);
      const message =
        err && err.name === "AbortError"
          ? "Request timed out"
          : (err && err.message) || "Network error — check your connection";
      return { ok: false, data: null, error: message };
    }
  }

  // Non-secret cache of the last-loaded backend profile (the
  // `public.users` row returned by POST /me), so the existing UI can
  // read it synchronously after the initial fetch without re-hitting
  // the network. Mirrors the pattern already used for the display
  // user in js/auth-client.js — never holds tokens.
  let cachedBackendUser = null;

  // Non-secret cache of the last accrue-mining call's response (the
  // raw JSON from POST /accrue-mining), so a caller can inspect the
  // outcome afterwards without re-hitting the network. As of the
  // mining-rate display/sync fix, index.html's game logic DOES read
  // this response's `mining_rate` field (via fetchAccrueMining()'s
  // return value) to drive the "MINING RATE" UI — see
  // syncMiningRateFromBackend() in index.html. It still never
  // overwrites the existing localStorage mining state itself, and
  // never holds tokens.
  let lastAccrueMiningResult = null;

  /**
   * Calls the authenticated `me` Edge Function using the current
   * Supabase session (obtained from ProXAuth — never re-implemented
   * here) and caches the resulting profile.
   *
   * Always resolves (never throws) with { ok, data, error }, same
   * shape as every other ProXBackend call. Safe to call when there is
   * no session yet or it has expired — that's reported as a normal
   * `ok: false` result, not an exception, so a fresh/expired/missing
   * session can never break the rest of the Mini App.
   */
  async function fetchMe() {
    console.log("[ProXBackend] fetching user");

    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      console.warn("[ProXBackend] failed");
      return { ok: false, data: null, error: "Auth module not available." };
    }

    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      console.warn("[ProXBackend] failed");
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("me", { method: "POST", accessToken: accessToken });

    if (result.ok && result.data && result.data.success && result.data.user) {
      cachedBackendUser = result.data.user;
      console.log("[ProXBackend] user loaded");
      return { ok: true, data: { user: cachedBackendUser }, error: null };
    }

    console.warn("[ProXBackend] failed");
    const message =
      (result.data && (result.data.message || result.data.error)) ||
      result.error ||
      "Could not load profile.";
    return { ok: false, data: null, error: message };
  }

  /**
   * Calls the authenticated `accrue-mining` Edge Function using the
   * current Supabase session (via ProXAuth.getAccessToken(), same
   * pattern as fetchMe() above — never re-implemented here).
   *
   * This performs a real (server-side) accrual on every call — that
   * behavior lives entirely in accrue-mining/index.ts and is
   * unchanged here. On the frontend, this is used both once at init
   * and on a periodic interval (see syncMiningRateFromBackend() in
   * index.html) purely to read back the authoritative `mining_rate`
   * for display — including any admin_speed_override — so the
   * "MINING RATE" UI never shows a stale locally-computed value. It
   * does NOT touch localStorage and does NOT modify any existing
   * mining/claim state itself; index.html decides what, if anything,
   * to do with the response.
   *
   * Always resolves (never throws) with { ok, data, error }, same
   * shape as every other ProXBackend call. The access token itself is
   * never logged or exposed — only high-level status messages are.
   */
  async function fetchAccrueMining() {
    console.log("[ProXBackend] verifying accrue-mining connectivity");

    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      console.warn("[ProXBackend] accrue-mining check failed");
      return { ok: false, data: null, error: "Auth module not available." };
    }

    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      console.warn("[ProXBackend] accrue-mining check failed");
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("accrue-mining", { method: "POST", body: {}, accessToken: accessToken });

    if (result.ok && result.data && result.data.success && result.data.mining_state) {
      lastAccrueMiningResult = result.data;
      console.log("[ProXBackend] accrue-mining connectivity verified");
      return { ok: true, data: result.data, error: null };
    }

    console.warn("[ProXBackend] accrue-mining check failed");
    const message =
      (result.data && (result.data.message || result.data.error)) ||
      result.error ||
      "Could not verify accrue-mining connectivity.";
    return { ok: false, data: null, error: message };
  }

  const ProXBackend = {
    /** Returns true once real Supabase project values are configured. */
    isConfigured: isConfigured,

    /**
     * Calls the `health` Edge Function to confirm the backend is
     * deployed and configured. Safe to call anytime — read-only,
     * no player data involved.
     */
    checkHealth: function () {
      return callFunction("health", { method: "GET" });
    },

    /**
     * Fetches the authenticated player's backend profile from
     * POST /me using the current Supabase session, and caches it.
     * See getCurrentUser() to read the cached result afterwards.
     */
    fetchMe: fetchMe,

    /** Last-loaded backend profile (the /me `user` row), or null. */
    getCurrentUser: function () {
      return cachedBackendUser;
    },

    /**
     * Calls POST /accrue-mining using the current Supabase session,
     * purely to verify frontend -> backend connectivity. Read/verify
     * only — never writes to localStorage, never touches existing
     * mining/claim state or UI. Intended to be called once after
     * successful authentication (see index.html), not on an interval.
     */
    fetchAccrueMining: fetchAccrueMining,

    /** Last accrue-mining verification response (raw JSON), or null. */
    getLastAccrueMiningResult: function () {
      return lastAccrueMiningResult;
    },

    // Internal — exposed so later migration steps (and this module's
    // own tests) can call other functions without duplicating the
    // fetch/error-handling logic above. Not part of the public API
    // surface used by today's game logic.
    _callFunction: callFunction,
  };

  global.ProXBackend = ProXBackend;
})(window);
