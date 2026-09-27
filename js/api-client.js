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

  // Non-secret cache of the last get-current-leaderboard call's
  // response (the `leaderboard` jsonb object from
  // public.get_current_leaderboard()), so a caller can inspect it
  // afterwards without re-hitting the network. Same caching pattern
  // as lastAccrueMiningResult above — never holds tokens.
  let lastLeaderboardResult = null;

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

  /**
   * Calls the authenticated `start-mining-session` Edge Function
   * (0057_mining_sessions.sql / public.start_mining_session) using the
   * current Supabase session — same auth pattern as
   * fetchAccrueMining()/claim-mining above, never re-implemented here.
   * Starts (or restarts) the caller's 8-hour mining session; the
   * response includes session_started_at/session_ends_at plus
   * level/claimed_total/pending_claim as of that moment, for the
   * caller to render an updated Mine/Wallet screen without a second
   * round trip. Never touches localStorage — index.html decides what
   * to do with the response, same as every other ProXBackend call.
   *
   * Always resolves (never throws) with { ok, data, error }, same
   * shape as every other ProXBackend call.
   */
  async function startMiningSession() {
    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      return { ok: false, data: null, error: "Auth module not available." };
    }

    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("start-mining-session", { method: "POST", body: {}, accessToken: accessToken });

    if (result.ok && result.data && result.data.success) {
      return { ok: true, data: result.data, error: null };
    }

    const message =
      (result.data && (result.data.message || result.data.error)) ||
      result.error ||
      "Could not start mining session.";
    return { ok: false, data: null, error: message };
  }

  /**
   * Calls the authenticated `claim-mining` Edge Function using the
   * current Supabase session (via ProXAuth.getAccessToken(), same
   * pattern as fetchMe()/fetchAccrueMining() above — never
   * re-implemented here).
   *
   * This performs a real (server-side) claim on every call — moving the
   * caller's own public.mining_state.pending_claim into claimed_total via
   * public.claim_mining (see backend/supabase/functions/claim-mining/
   * index.ts and 0027_secure_mpxn_claim.sql). Sends no request body:
   * there is no field that identifies which player or which amount to
   * claim — the backend determines the authenticated user from the
   * access token alone. Never reads or writes pxn_balance.
   *
   * Always resolves (never throws) with { ok, data, error }, same shape
   * as every other ProXBackend call. On success, `data` is the raw JSON
   * body from claim-mining: { success: true, user_id, claimed_amount,
   * pending_claim, claimed_total, claim_count }. On a recognized backend
   * rejection (e.g. nothing to claim), `ok` is false and `data` still
   * carries the backend's own { success: false, message } body so the
   * caller can show that exact message. This function does NOT touch
   * localStorage and does NOT modify any existing mining/claim state
   * itself — index.html decides what, if anything, to do with the
   * response.
   */
  async function fetchClaimMining() {
    console.log("[ProXBackend] claiming m.PXN");

    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      console.warn("[ProXBackend] claim failed");
      return { ok: false, data: null, error: "Auth module not available." };
    }

    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      console.warn("[ProXBackend] claim failed");
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("claim-mining", { method: "POST", body: {}, accessToken: accessToken });

    if (result.ok && result.data && result.data.success) {
      console.log("[ProXBackend] claim succeeded");
      return { ok: true, data: result.data, error: null };
    }

    console.warn("[ProXBackend] claim failed");
    const message =
      (result.data && (result.data.message || result.data.error)) ||
      result.error ||
      "Could not process claim.";
    // result.data is deliberately still passed through (not null) so the
    // caller can read the backend's own status/message shape, same
    // pattern the raw callFunction() result already uses.
    return { ok: false, data: result.data, error: message };
  }

  /**
   * Calls the authenticated `get-current-leaderboard` Edge Function
   * using the current Supabase session (via ProXAuth.getAccessToken(),
   * same pattern as fetchMe()/fetchAccrueMining()/fetchClaimMining()
   * above — never re-implemented here).
   *
   * This is a read-only call: it exposes the existing
   * public.get_current_leaderboard() RPC
   * (0049_monthly_leaderboard_foundation.sql) and does not write
   * anything. On success, `data.leaderboard` is exactly the jsonb
   * object that RPC returns: { period, status, prizes, top100, self }.
   * Does NOT touch localStorage and does NOT modify any existing
   * mining/claim/task/marketplace state — index.html decides what, if
   * anything, to do with the response.
   *
   * Always resolves (never throws) with { ok, data, error }, same
   * shape as every other ProXBackend call.
   */
  async function fetchCurrentLeaderboard() {
    console.log("[ProXBackend] fetching current leaderboard");

    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      console.warn("[ProXBackend] leaderboard fetch failed");
      return { ok: false, data: null, error: "Auth module not available." };
    }

    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      console.warn("[ProXBackend] leaderboard fetch failed");
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("get-current-leaderboard", {
      method: "POST",
      body: {},
      accessToken: accessToken,
    });

    if (result.ok && result.data && result.data.success) {
      lastLeaderboardResult = result.data.leaderboard;
      console.log("[ProXBackend] leaderboard loaded");
      return { ok: true, data: { leaderboard: lastLeaderboardResult }, error: null };
    }

    console.warn("[ProXBackend] leaderboard fetch failed");
    const message =
      (result.data && (result.data.message || result.data.error)) ||
      result.error ||
      "Could not load leaderboard.";
    return { ok: false, data: null, error: message };
  }

  // Non-secret cache of the last player-profile "get" response (the
  // player's own player_wallets row, or null if none connected), so a
  // caller can inspect it afterwards without re-hitting the network.
  // Same caching pattern as the other lastXResult fields above — never
  // holds tokens. Added alongside the wallet-onboarding /
  // withdrawal-request feature (0052_player_wallet_and_withdrawals.sql).
  let lastWalletResult = null;

  // Non-secret cache of the last withdrawals "list" response.
  let lastWithdrawalsResult = null;

  /**
   * Calls the authenticated `player-profile` Edge Function ({action:"get"})
   * to read the caller's own wallet-connection status. Same
   * auth/error-handling pattern as fetchMe()/fetchCurrentLeaderboard()
   * above. On success, `data.wallet` is either the player's
   * player_wallets row or null (no wallet connected yet).
   */
  async function fetchWalletStatus() {
    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      return { ok: false, data: null, error: "Auth module not available." };
    }
    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("player-profile", {
      method: "POST",
      body: { action: "get" },
      accessToken: accessToken,
    });

    if (result.ok && result.data && result.data.success) {
      lastWalletResult = result.data.wallet || null;
      return { ok: true, data: { wallet: lastWalletResult }, error: null };
    }

    const message =
      (result.data && result.data.error && result.data.error.message) ||
      result.error ||
      "Could not load wallet status.";
    return { ok: false, data: null, error: message };
  }

  /**
   * Calls `player-profile` ({action:"connect_wallet"}) to save the
   * caller's TON wallet address. The backend (public.connect_wallet(),
   * 0052) is authoritative: it validates the address format and is the
   * only thing that ever writes player_wallets — this function only
   * relays the caller's input and the backend's response, never
   * pretends the save succeeded locally.
   */
  async function connectWallet(walletAddress, walletNetwork) {
    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      return { ok: false, data: null, error: "Auth module not available." };
    }
    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("player-profile", {
      method: "POST",
      body: {
        action: "connect_wallet",
        wallet_address: walletAddress,
        wallet_network: walletNetwork || "ton",
      },
      accessToken: accessToken,
    });

    if (result.ok && result.data && result.data.success) {
      lastWalletResult = result.data.wallet || null;
      return { ok: true, data: { wallet: lastWalletResult }, error: null };
    }

    const message =
      (result.data && result.data.error && result.data.error.message) ||
      result.error ||
      "Could not connect wallet.";
    return { ok: false, data: null, error: message };
  }

  /**
   * Calls `withdrawals` ({action:"list"}) for the caller's own
   * withdrawal-request history.
   */
  async function fetchWithdrawals() {
    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      return { ok: false, data: null, error: "Auth module not available." };
    }
    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("withdrawals", {
      method: "POST",
      body: { action: "list" },
      accessToken: accessToken,
    });

    if (result.ok && result.data && result.data.success) {
      lastWithdrawalsResult = result.data.withdrawals || [];
      return { ok: true, data: { withdrawals: lastWithdrawalsResult }, error: null };
    }

    const message =
      (result.data && result.data.error && result.data.error.message) ||
      result.error ||
      "Could not load withdrawal history.";
    return { ok: false, data: null, error: message };
  }

  /**
   * Calls `withdrawals` ({action:"create"}) to submit a new withdrawal
   * request for amountMpxn (a number, in m.PXN). The backend
   * (public.create_withdrawal_request(), 0052) is authoritative for the
   * wallet used, the PXN conversion, the balance debit, and every
   * validation rule (wallet connected, not paused, minimum amount, no
   * existing pending request) — this function only relays the amount
   * and the backend's response.
   */
  async function createWithdrawal(amountMpxn) {
    const auth = global.ProXAuth;
    if (!auth || typeof auth.getAccessToken !== "function") {
      return { ok: false, data: null, error: "Auth module not available." };
    }
    const accessToken = await auth.getAccessToken();
    if (!accessToken) {
      return { ok: false, data: null, error: "No active session." };
    }

    const result = await callFunction("withdrawals", {
      method: "POST",
      body: { action: "create", amount_mpxn: amountMpxn },
      accessToken: accessToken,
    });

    if (result.ok && result.data && result.data.success) {
      return { ok: true, data: { withdrawal: result.data.withdrawal }, error: null };
    }

    const message =
      (result.data && result.data.error && result.data.error.message) ||
      result.error ||
      "Could not submit withdrawal request.";
    return { ok: false, data: result.data, error: message };
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
    startMiningSession: startMiningSession,

    /** Last accrue-mining verification response (raw JSON), or null. */
    getLastAccrueMiningResult: function () {
      return lastAccrueMiningResult;
    },

    /**
     * Calls POST /claim-mining using the current Supabase session,
     * moving the player's own pending_claim into claimed_total
     * server-side. See fetchClaimMining() above for the full contract.
     */
    fetchClaimMining: fetchClaimMining,

    /**
     * Calls POST /get-current-leaderboard using the current Supabase
     * session, exposing the existing
     * public.get_current_leaderboard() RPC
     * (0049_monthly_leaderboard_foundation.sql). Read-only. See
     * fetchCurrentLeaderboard() above for the full contract.
     */
    fetchCurrentLeaderboard: fetchCurrentLeaderboard,

    /** Last get-current-leaderboard response's `leaderboard` object, or null. */
    getLastLeaderboardResult: function () {
      return lastLeaderboardResult;
    },

    /**
     * Calls POST /player-profile ({action:"get"}) using the current
     * Supabase session to read the caller's own wallet-connection
     * status. See fetchWalletStatus() above for the full contract.
     */
    fetchWalletStatus: fetchWalletStatus,

    /** Last player-profile "get" response's `wallet` object, or null. */
    getLastWalletResult: function () {
      return lastWalletResult;
    },

    /**
     * Calls POST /player-profile ({action:"connect_wallet"}) to save a
     * TON wallet address for the caller. See connectWallet() above.
     */
    connectWallet: connectWallet,

    /**
     * Calls POST /withdrawals ({action:"list"}) for the caller's own
     * withdrawal-request history. See fetchWithdrawals() above.
     */
    fetchWithdrawals: fetchWithdrawals,

    /** Last withdrawals "list" response's array, or null. */
    getLastWithdrawalsResult: function () {
      return lastWithdrawalsResult;
    },

    /**
     * Calls POST /withdrawals ({action:"create"}) to submit a new
     * withdrawal request. See createWithdrawal() above.
     */
    createWithdrawal: createWithdrawal,

    // Internal — exposed so later migration steps (and this module's
    // own tests) can call other functions without duplicating the
    // fetch/error-handling logic above. Not part of the public API
    // surface used by today's game logic.
    _callFunction: callFunction,
  };

  global.ProXBackend = ProXBackend;
})(window);
