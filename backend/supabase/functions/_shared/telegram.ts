// Pro-X Network — Telegram WebApp initData verification.
//
// Implements Telegram's documented validation algorithm for Mini App
// `initData`:
// https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app
//
// This is the ONLY thing that is allowed to establish "who this user
// is". Nothing else in the backend should ever trust a client-
// supplied telegram user id, username, or referral code as proof of
// identity — those all become available only *after* this
// verification succeeds, and are read out of the verified string
// itself (never out of a separately-sent field).

export interface TelegramWebAppUser {
  id: number;
  first_name?: string;
  last_name?: string;
  username?: string;
  language_code?: string;
  is_premium?: boolean;
}

export interface VerifiedInitData {
  user: TelegramWebAppUser;
  authDate: number; // unix seconds, from the signed payload
  // The raw `start_param` field from a Telegram deep link
  // (`t.me/<bot>?start=<value>`), if this session was launched via one.
  // Per the Friends Referral design, this value is the REFERRER's own
  // telegram_user_id, rendered as a plain decimal string by the frontend's
  // referral link — nothing new is decoded or trusted here. `start_param`
  // is just another field inside the same query-string payload whose
  // signature is verified below (it is already covered by the
  // data-check-string, exactly like `user` and `auth_date`), so exposing it
  // requires no change to the HMAC verification algorithm itself and
  // introduces no new trust boundary. `undefined` when this session was not
  // launched via a referral deep link (an ordinary/organic open) — this is
  // the normal case, not an error. Consumed only by
  // record_pending_referral() (see 0045_record_pending_referral.sql), which
  // does its own strict validation of the value; this module never
  // interprets or validates it beyond extracting it verbatim.
  startParam?: string;
}

export type InitDataVerificationFailureReason =
  | "malformed"
  | "missing_hash"
  | "missing_user"
  | "bad_signature"
  | "expired";

export type InitDataVerificationResult =
  | { ok: true; data: VerifiedInitData }
  | { ok: false; reason: InitDataVerificationFailureReason };

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function hmacSha256(keyBytes: Uint8Array, message: string): Promise<ArrayBuffer> {
  // Copy into a plain ArrayBuffer-backed Uint8Array so this accepts
  // both a freshly-allocated Uint8Array and one sliced from another
  // buffer (e.g. the output of a previous hmacSha256 call).
  const keyCopy = Uint8Array.from(keyBytes);
  const key = await crypto.subtle.importKey(
    "raw",
    keyCopy,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
}

/**
 * Verifies a raw Telegram Mini App `initData` string against the
 * bot token, and returns the trustworthy user info embedded in it.
 *
 * @param rawInitData   The exact string from `Telegram.WebApp.initData`
 *                       (a URL-query-string-shaped payload, NOT the
 *                       parsed `initDataUnsafe` object).
 * @param botToken      TELEGRAM_BOT_TOKEN — never logged, never
 *                       returned, never sent anywhere else.
 * @param maxAgeSeconds  Reject initData whose `auth_date` is older
 *                       than this, to limit replay of a captured
 *                       initData string. Telegram does not expire
 *                       initData itself, so the backend must.
 */
export async function verifyTelegramInitData(
  rawInitData: string,
  botToken: string,
  maxAgeSeconds: number,
): Promise<InitDataVerificationResult> {
  let params: URLSearchParams;
  try {
    params = new URLSearchParams(rawInitData);
  } catch {
    return { ok: false, reason: "malformed" };
  }

  const receivedHash = params.get("hash");
  if (!receivedHash) {
    return { ok: false, reason: "missing_hash" };
  }

  const userRaw = params.get("user");
  if (!userRaw) {
    return { ok: false, reason: "missing_user" };
  }

  // Build the data-check-string: every field except `hash`,
  // "key=value" per line, sorted alphabetically by key.
  const entries: string[] = [];
  for (const [key, value] of params.entries()) {
    if (key === "hash") continue;
    entries.push(`${key}=${value}`);
  }
  entries.sort();
  const dataCheckString = entries.join("\n");

  // secret_key = HMAC_SHA256(key = "WebAppData", data = bot_token)
  const secretKey = await hmacSha256(new TextEncoder().encode("WebAppData"), botToken);
  // computed_hash = HMAC_SHA256(key = secret_key, data = data_check_string), hex
  const computedHashBytes = await hmacSha256(new Uint8Array(secretKey), dataCheckString);
  const computedHash = toHex(computedHashBytes);

  if (!timingSafeEqual(computedHash, receivedHash.toLowerCase())) {
    return { ok: false, reason: "bad_signature" };
  }

  const authDateRaw = params.get("auth_date");
  const authDate = authDateRaw ? parseInt(authDateRaw, 10) : NaN;
  if (!Number.isFinite(authDate)) {
    return { ok: false, reason: "malformed" };
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  if (nowSeconds - authDate > maxAgeSeconds) {
    return { ok: false, reason: "expired" };
  }

  let user: TelegramWebAppUser;
  try {
    user = JSON.parse(userRaw);
  } catch {
    return { ok: false, reason: "malformed" };
  }

  if (typeof user.id !== "number") {
    return { ok: false, reason: "missing_user" };
  }

  // At this point `user` came out of a payload whose signature we
  // just verified against the bot token, so — and only now — it is
  // safe to treat user.id as the caller's real Telegram identity.
  //
  // start_param is read out of this SAME verified `params`, after the
  // signature check above has already passed — it was already covered by
  // the data-check-string, so no additional verification step is needed or
  // added here. `null` (no such field, an ordinary/organic open) becomes
  // `undefined` on VerifiedInitData, matching every other optional field on
  // TelegramWebAppUser above.
  const startParam = params.get("start_param") ?? undefined;

  return { ok: true, data: { user, authDate, startParam } };
}

/** Constant-time string comparison, to avoid leaking hash bytes via timing. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
