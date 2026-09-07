# Pro-X Network — Backend Foundation (Step 1 of the migration)

This document covers only what was built in this step: the backend
**foundation**. No game system (mining, marketplace, tasks, referrals,
wallet) has been migrated yet — the app behaves exactly as it did
before. See `backend/README.md` for hands-on Supabase setup/deploy/test
instructions, and the original audit report for the full migration
plan this step is #1 of.

## What exists now

```
pro-x-network-main/
├── index.html                          # unchanged, +2 new <script> includes (see below)
├── admin.html                          # unchanged
├── assets/
│   └── bg-mine.png                     # unchanged
├── .gitignore                          # NEW — keeps real secrets out of git
├── README-BACKEND.md                   # NEW — this file
├── config/
│   ├── frontend-config.js              # NEW — active config, ships with placeholder values
│   └── frontend-config.example.js      # NEW — documented template/reference copy
├── js/
│   └── api-client.js                   # NEW — frontend helper for calling the backend
└── backend/
    ├── README.md                       # NEW — Supabase setup/deploy/test instructions
    └── supabase/
        ├── config.toml                 # NEW — Supabase project config
        ├── .env.example                # NEW — local-dev secrets template (never commit real .env)
        ├── functions/
        │   ├── _shared/
        │   │   ├── cors.ts             # NEW — shared CORS helper
        │   │   └── env.ts              # NEW — shared "require env var" helper
        │   └── health/
        │       └── index.ts            # NEW — the one live Edge Function: GET /health
        └── migrations/
            └── 0000_extensions.sql     # NEW — enables pgcrypto only, no game tables yet
```

## File-by-file explanation

| File | What it does |
|---|---|
| `backend/supabase/config.toml` | Tells the Supabase CLI about this project and which functions require an authenticated caller (`health` doesn't). |
| `backend/supabase/.env.example` | Documents every secret the backend will eventually need (Supabase service role key, Telegram bot token, TON key/seed) with placeholder values — never real ones. Copy to `.env` for local testing only. |
| `backend/supabase/functions/_shared/cors.ts` | One shared place for CORS headers and preflight handling, so every current and future Edge Function behaves consistently for the Telegram WebView. |
| `backend/supabase/functions/_shared/env.ts` | One shared place to read required environment variables and fail with a clear error message if one is missing, instead of an obscure `undefined` bug later. |
| `backend/supabase/functions/health/index.ts` | The only live endpoint. Reports whether the function is deployed and whether its required secrets are present — reads no player data and returns no secret values. |
| `backend/supabase/migrations/0000_extensions.sql` | The one database migration so far. Enables the `pgcrypto` Postgres extension (used for UUIDs later). Creates zero tables — no players/balances/inventory/marketplace/tasks/referrals/wallet schema yet, on purpose. |
| `config/frontend-config.example.js` | Documented template explaining what's safe to put in frontend config (the Supabase anon key — public by design) and what never belongs there (the service role key or any other secret). |
| `config/frontend-config.js` | The file `index.html` actually loads. Ships with placeholder values so the app works with zero setup; edit it with your real Supabase project URL/anon key when you're ready to connect the backend. |
| `js/api-client.js` | A small `ProXBackend` object exposed on `window`. Wraps `fetch` calls to Edge Functions with consistent error handling, a request timeout, and a "not configured yet" safe-fail path. Currently exposes one method, `checkHealth()`. Nothing in the game calls it yet — it's pure new infrastructure. |
| `.gitignore` | Excludes real secret files (`backend/supabase/.env`, etc.) from version control. |
| `index.html` (modified) | Two `<script src="...">` lines added right before the existing game `<script>` block, loading the two files above. No other line was touched — no UI, no game logic, no removed `localStorage` calls. |

## How to configure the Supabase environment variables

Full step-by-step is in `backend/README.md`. Summary:

- **Frontend-safe value** (`SUPABASE_ANON_KEY`, `SUPABASE_URL`,
  `FUNCTIONS_URL`) → edit directly into `config/frontend-config.js`.
  These are meant to be public.
- **Server-only secrets** (`SUPABASE_SERVICE_ROLE_KEY`,
  `TELEGRAM_BOT_TOKEN`, and later `TON_PRIVATE_KEY` /
  `TON_WALLET_SEED_PHRASE`) → set with `supabase secrets set KEY=value`
  for the deployed project, or in a local, gitignored
  `backend/supabase/.env` file (copied from `.env.example`) for local
  testing only. These are never written into any file that ships to a
  browser.

## How to run/test the health check

See "6. Test the health check" in `backend/README.md` — three ways:
`curl` against a local `supabase functions serve` instance, `curl`
against the deployed project, or from the browser console via
`await ProXBackend.checkHealth()` once `config/frontend-config.js` has
real values.

## Errors found during this step

None in the existing app code that block this step — the previous
audit's findings (client-trusted balances, hardcoded admin passcode,
unverified Telegram identity, marketplace built on shared
`localStorage`, etc.) all still apply exactly as documented, since
nothing about them has been touched yet. They'll be addressed one at a
time in the later migration steps that specifically target each
system.

One thing worth flagging now rather than later: `index.html` currently
has **no build step and no bundler**, so the two new `<script>` tags
use plain relative paths (`config/frontend-config.js`,
`js/api-client.js`). If the Mini App is ever served from a path where
`index.html` isn't at the web root, these two paths (and the existing
`assets/bg-mine.png` reference) will need adjusting together — this
isn't a new problem introduced by this step, just worth knowing before
deployment.

## What was intentionally NOT done in this step

Per your instructions, none of the following happened yet, and the app
is unchanged in every one of these respects:

- No mining/accrual logic moved or changed
- No marketplace logic moved or changed
- No task/referral logic moved or changed
- No wallet/withdrawal logic added
- No `localStorage` reads/writes removed
- No UI changes
- No database tables for game data created

Say the word for which step to do next (server-side mining accrual,
verified Telegram auth, etc.) and I'll scope just that one before
writing any code.
