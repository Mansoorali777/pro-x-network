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
          "Authorization": "Bearer " + cfg.SUPABASE_ANON_KEY,
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

    // Internal — exposed so later migration steps (and this module's
    // own tests) can call other functions without duplicating the
    // fetch/error-handling logic above. Not part of the public API
    // surface used by today's game logic.
    _callFunction: callFunction,
  };

  global.ProXBackend = ProXBackend;
})(window);
