// Pro-X Network — Telegram Mini App auth client.
//
// This module is additive infrastructure, same spirit as
// js/api-client.js: it does not touch the existing game state
// (STORAGE_KEY / PLAYER_ID / PLAYER_NAME below in index.html) and
// does not change anything visible.
//
// What it does:
//   1. Reads the RAW, signed `Telegram.WebApp.initData` string (never
//      the parsed, client-trusted `initDataUnsafe`).
//   2. Sends it to the auth-telegram Edge Function for server-side
//      verification against the bot token, which returns a real
//      Supabase Auth session (access_token + refresh_token).
//   3. Hands that session to supabase-js via `setSession()`.
//      supabase-js owns persistence, auto-refresh, and sign-out from
//      that point on — this module does NOT keep its own copy of the
//      tokens or implement its own refresh/expiry logic, only a
//      small cache of the (non-secret) `user` display object.
//
// Requires the supabase-js UMD build to be loaded before this file
// (see the <script> tag in index.html) and config/frontend-config.js
// for SUPABASE_URL / SUPABASE_ANON_KEY.
//
// Usage:
//   const result = await ProXAuth.authenticate();
//   if (result.ok) {
//     console.log("Pro-X session established for", result.data.user.telegramUserId);
//   } else {
//     console.warn("Pro-X auth failed:", result.error);
//   }
//
//   ProXAuth.getSupabaseClient(); // the shared supabase-js client instance
//   ProXAuth.getUser();           // last-known display user, or null
//   ProXAuth.isAuthenticated();   // boolean (checks supabase-js's live session)
//   ProXAuth.logout();            // real sign-out (invalidates refresh token too)

(function (global) {
  "use strict";

  // Separate from the existing game-state key. Holds only the
  // non-secret `user` display object for a fast render before the
  // async `authenticate()` round-trip completes — never tokens.
  const USER_CACHE_KEY = "proxnetwork_user_v1";

  let supabaseClient = null;

  function getTelegramWebApp() {
    return global.Telegram ? global.Telegram.WebApp : null;
  }

  /**
   * Lazily creates the shared supabase-js client, using the same
   * public SUPABASE_URL / SUPABASE_ANON_KEY already used by
   * js/api-client.js. supabase-js manages its own session storage
   * (localStorage, under its own key), auto-refresh, and sign-out —
   * this module never re-implements any of that.
   */
  function getSupabaseClient() {
    if (supabaseClient) return supabaseClient;

    const cfg = global.PROX_CONFIG;
    if (!cfg || !cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY) return null;
    if (typeof global.supabase === "undefined" || !global.supabase.createClient) return null;

    supabaseClient = global.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
      auth: { persistSession: true, autoRefreshToken: true },
    });
    return supabaseClient;
  }

  function readCachedUser() {
    try {
      const raw = localStorage.getItem(USER_CACHE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (e) {
      return null;
    }
  }

  function writeCachedUser(user) {
    try {
      localStorage.setItem(USER_CACHE_KEY, JSON.stringify(user));
    } catch (e) {
      console.warn("[ProXAuth] could not cache user info:", e);
    }
  }

  function clearCachedUser() {
    try {
      localStorage.removeItem(USER_CACHE_KEY);
    } catch (e) {
      // ignore
    }
  }

  /** Last-known display user (non-secret), or null. */
  function getUser() {
    return readCachedUser();
  }

  /**
   * Whether supabase-js currently holds a live (unexpired) session.
   * This is a client-side read of supabase-js's own stored session —
   * it does not make a network call.
   */
  async function isAuthenticated() {
    const client = getSupabaseClient();
    if (!client) return false;
    const { data } = await client.auth.getSession();
    return !!data.session;
  }

  /**
   * The current Supabase Auth access token (JWT), or null if there is
   * no live session. This is a client-side read of supabase-js's own
   * stored session (auto-refreshed by supabase-js itself, per
   * `getSupabaseClient()` above) — it never mints, stores, or
   * refreshes a token itself. Intended for callers (e.g. ProXBackend)
   * that need to attach `Authorization: Bearer <token>` to an
   * authenticated backend request.
   */
  async function getAccessToken() {
    const client = getSupabaseClient();
    if (!client) return null;
    const { data } = await client.auth.getSession();
    return data && data.session ? data.session.access_token : null;
  }

  /**
   * Real sign-out: invalidates the refresh token server-side (unlike
   * the previous client-only "forget the token" logout) and clears
   * supabase-js's stored session. Existing game state (STORAGE_KEY)
   * is left untouched.
   */
  async function logout() {
    const client = getSupabaseClient();
    if (client) {
      await client.auth.signOut();
    }
    clearCachedUser();
  }

  /**
   * Verifies this Telegram session with the backend and hands the
   * resulting real Supabase session to supabase-js. Safe to call
   * multiple times (e.g. on every app load) — it always re-verifies
   * against the backend rather than trusting anything cached about
   * identity, though it will reuse a still-live supabase-js session
   * instead of making a redundant network call unless
   * `options.force` is set.
   *
   * Always resolves (never throws) with { ok, data, error } like
   * ProXBackend's other calls.
   */
  async function authenticate(options) {
    options = options || {};

    const client = getSupabaseClient();
    if (!client) {
      return {
        ok: false,
        data: null,
        error: "Backend not configured yet — edit config/frontend-config.js.",
      };
    }

    if (!options.force) {
      const alreadyAuthed = await isAuthenticated();
      if (alreadyAuthed) {
        const cachedUser = getUser();
        if (cachedUser) {
          return { ok: true, data: { user: cachedUser }, error: null };
        }
      }
    }

    const tg = getTelegramWebApp();
    const rawInitData = tg && typeof tg.initData === "string" ? tg.initData : "";

    if (!rawInitData) {
      return {
        ok: false,
        data: null,
        error: "Not running inside Telegram (no initData available).",
      };
    }

    if (!global.ProXBackend || !global.ProXBackend.isConfigured()) {
      return {
        ok: false,
        data: null,
        error: "Backend not configured yet — edit config/frontend-config.js.",
      };
    }

    const result = await global.ProXBackend._callFunction("auth-telegram", {
      method: "POST",
      body: { initData: rawInitData },
    });

    if (!result.ok || !result.data || !result.data.session) {
      return { ok: false, data: null, error: result.error || "Authentication failed." };
    }

    const { accessToken, refreshToken } = result.data.session;
    const { error: setSessionError } = await client.auth.setSession({
      access_token: accessToken,
      refresh_token: refreshToken,
    });

    if (setSessionError) {
      return { ok: false, data: null, error: setSessionError.message || "Could not establish session." };
    }

    writeCachedUser(result.data.user);

    return { ok: true, data: { user: result.data.user }, error: null };
  }

  global.ProXAuth = {
    authenticate: authenticate,
    getSupabaseClient: getSupabaseClient,
    getUser: getUser,
    getAccessToken: getAccessToken,
    isAuthenticated: isAuthenticated,
    logout: logout,
  };
})(window);
