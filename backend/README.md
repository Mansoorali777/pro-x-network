# Pro-X Network — Backend (Supabase)

This folder is the entire backend: PostgreSQL (via Supabase) + Supabase
Edge Functions for anything sensitive. At this stage it contains
**only the foundation** — project structure, config, and a health
check. No game logic (mining, marketplace, tasks, referrals, wallet)
has been moved here yet; that happens in later, separate steps.

```
backend/
└── supabase/
    ├── config.toml                  # Supabase project config (which functions need auth, etc.)
    ├── .env.example                 # Template for local-dev secrets — copy to .env, never commit .env
    ├── functions/
    │   ├── _shared/
    │   │   ├── cors.ts              # Shared CORS headers/helper used by every function
    │   │   └── env.ts               # Shared "require this env var or throw clearly" helper
    │   └── health/
    │       └── index.ts             # GET /functions/v1/health — the only function that exists so far
    └── migrations/
        └── 0000_extensions.sql      # Enables the pgcrypto extension only — no game tables yet
```

## Prerequisites

- A free [Supabase](https://supabase.com) account and a new project.
- [Supabase CLI](https://supabase.com/docs/guides/cli) installed locally
  (`npm install -g supabase` or via your package manager).
- [Deno](https://deno.land/) is not required to be installed separately
  for deploying — the Supabase CLI bundles what it needs — but it's
  useful for editor type-checking if you work on functions locally.

## 1. Link this folder to your Supabase project

```bash
cd backend/supabase
supabase login
supabase link --project-ref YOUR_PROJECT_REF
```

`YOUR_PROJECT_REF` is in your Supabase dashboard URL
(`https://supabase.com/dashboard/project/<this-part>`), and also under
Project Settings → General.

## 2. Configure secrets (production/deployed)

Never put real secrets in any committed file. Set them on the Supabase
platform instead:

```bash
supabase secrets set TELEGRAM_BOT_TOKEN=xxxxx
# (TON secrets are placeholders for a future step — do not set them yet)
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` do **not** need to be
set with `supabase secrets set` — Supabase automatically injects both
into every deployed Edge Function.

To confirm what's currently set (values are never shown, only names):

```bash
supabase secrets list
```

## 3. Configure secrets (local development only)

```bash
cp backend/supabase/.env.example backend/supabase/.env
# then edit backend/supabase/.env with your real local values
```

`backend/supabase/.env` is in `.gitignore` — it will never be
committed. This file is only read by `supabase functions serve` on
your machine; it has no effect on the deployed project.

## 4. Run the database migrations

```bash
cd backend/supabase
supabase db push
```

This applies, in order: the pgcrypto extension, shared trigger
helpers, the `users`/`user_profiles` tables, and `auth_attempts`
(used to rate-limit login). No mining/balance/marketplace tables yet.

## 5. Deploy the Edge Functions

```bash
cd backend/supabase
supabase functions deploy health
supabase functions deploy auth-telegram
```

## 5a. Telegram Mini App authentication

`POST /functions/v1/auth-telegram` — verifies a Telegram Mini App's
`initData`, creates or loads the matching `users` row, and returns a
short-lived session token.

**Request:**
```json
{ "initData": "query_id=...&user=%7B...%7D&auth_date=...&hash=..." }
```
This must be the raw, signed string from `Telegram.WebApp.initData` —
never the parsed `initDataUnsafe` object, which is not signature-
protected and must never be trusted as identity.

**Response 200:**
```json
{
  "user": { "id": "<uuid>", "telegramUserId": 123456789, "username": "alice",
            "firstName": "Alice", "lastName": null, "languageCode": "en" },
  "session": { "accessToken": "<jwt>", "refreshToken": "<token>",
               "expiresAt": "2026-09-07T12:00:00.000Z" }
}
```

**Error responses:** `400` malformed request, `401` bad/expired
signature, `403` banned account, `429` too many attempts from this
caller recently, `500` server misconfiguration or session-issuance
failure.

**How verification works:** the function recomputes Telegram's HMAC-
SHA256 signature over `initData` using `TELEGRAM_BOT_TOKEN` and
compares it (constant-time) to the `hash` field Telegram included.
Only once that matches is the embedded `user` JSON — and therefore
the Telegram user id — treated as real. See
`backend/supabase/functions/_shared/telegram.ts` for the exact
algorithm (it follows Telegram's documented spec).

**The session token is a real Supabase Auth session** — not a
custom-signed JWT. After the `public.users` row is loaded/created,
the function:
1. Ensures a matching `auth.users` row exists with
   `id = public.users.id` (via `supabase.auth.admin.createUser`,
   using a deterministic internal-only synthetic email that's never
   shown to the user or delivered anywhere — see
   `syntheticEmailFor` in `auth-telegram/index.ts`).
2. Mints a session for that user via
   `supabase.auth.admin.generateLink` + `verifyOtp`, both officially
   supported Admin/Auth API methods.

Because `auth.users.id` is set equal to `public.users.id` at
creation, `auth.uid()` resolves to `public.users.id` natively —
every existing RLS policy (`auth.uid() = users.id` / `auth.uid() =
user_id`) works with zero changes. The session is signed by
Supabase's own Auth server, exactly like any normal email/OAuth
login — no project secret is used to sign it, and none needs to be
kept in sync with Supabase's JWT signing keys.

**Rate limiting:** every call (success or failure) is logged to
`public.auth_attempts` with the caller's IP. Before doing any real
work, the function checks whether that IP has made 20+ attempts in
the last 5 minutes and returns `429` if so. This table is
service-role-only — never client-readable.

**Required secrets for this function:**
```bash
supabase secrets set TELEGRAM_BOT_TOKEN=xxxxx
```
(`SUPABASE_URL`/`SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY` are
auto-injected as always — no custom signing secret is needed.)

## 6. Test the health check

**Locally**, before deploying (reads `backend/supabase/.env`):

```bash
cd backend/supabase
supabase functions serve health
# in another terminal:
curl -i http://localhost:54321/functions/v1/health
```

**Against your deployed project:**

```bash
curl -i https://YOUR_PROJECT_REF.supabase.co/functions/v1/health \
  -H "Authorization: Bearer YOUR_SUPABASE_ANON_KEY" \
  -H "apikey: YOUR_SUPABASE_ANON_KEY"
```

Expected response when everything is configured correctly:

```json
{
  "status": "ok",
  "service": "pro-x-network-backend",
  "timestamp": "2026-09-06T12:00:00.000Z",
  "checks": { "environment": "all required secrets present" }
}
```

If `SUPABASE_SERVICE_ROLE_KEY` isn't available in the function's
environment for some reason, you'll get HTTP 503 with
`"status": "degraded"` and a `checks.environment` message naming what's
missing — nothing else in the app is affected by this either way, since
nothing calls this function automatically yet.

**From the browser**, once `config/frontend-config.js` (see the repo
root) has your real project values: open `index.html`, open the
browser devtools console, and run:

```js
await ProXBackend.checkHealth();
// { ok: true, data: { status: "ok", ... }, error: null }
```

## Security model going forward

- The frontend (`index.html`/`admin.html`) is never trusted with
  balances, mining rewards, inventory, marketplace state, referrals,
  task rewards, or withdrawals — those will all be verified and
  mutated by Edge Functions / Postgres, once each system is migrated
  in its own step.
- Identity is never trusted from the client either: `initDataUnsafe`,
  a self-reported user id, a username, or a referral code are all
  ignored as proof of who someone is. The only trusted identity path
  is `auth-telegram` verifying raw `initData`'s signature against
  `TELEGRAM_BOT_TOKEN` server-side (see 5a above).
- `SUPABASE_SERVICE_ROLE_KEY` (full database access, bypasses Row
  Level Security) is only ever available inside Edge Functions —
  never sent to, or usable by, the frontend. Session tokens are real
  Supabase Auth sessions minted server-side (see 5a above); there is
  no custom signing secret in this codebase to protect or rotate.
- `TELEGRAM_BOT_TOKEN` and any future TON private key / seed phrase
  follow the same rule: server-only, via `supabase secrets`, never in
  a committed file or frontend code.
- `SUPABASE_ANON_KEY` is the one value that's meant to be public — it
  lives in `config/frontend-config.js` deliberately, and real security
  comes from Row Level Security policies, each Edge Function's own
  checks, and (as of this step) verified Telegram identity — not from
  hiding this key.
