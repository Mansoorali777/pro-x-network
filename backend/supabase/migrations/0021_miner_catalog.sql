-- Pro-X Network — Miner Management backend foundation.
--
-- Table: public.miner_catalog.
--
-- Context: this is the first step of a multi-step Miner Management
-- feature. It creates ONLY the database-backed miner catalog —
-- schema, constraints, RLS, and a seed of the 7 tiers already live in
-- the game — so a later step can build the admin CRUD Edge
-- Function(s)/UI on top of it. This migration does NOT wire anything
-- up yet: purchase-miner/index.ts, accrue-mining/index.ts,
-- set-miner-applied/index.ts, admin-set-mining-speed/index.ts,
-- public.mining_config, public.mining_state, public.mining_inventory,
-- public.users, auth-telegram, and every existing frontend file
-- (index.html, admin.html, js/*.js) are all left completely
-- untouched by this migration. In particular:
--   - public.mining_config.miner_tiers (0003_mining_config.sql)
--     remains the value accrue-mining and every other existing
--     server-side formula actually reads. This new table does not
--     replace it yet — that migration (pointing purchase-miner/
--     accrue-mining at miner_catalog instead) is explicitly a later,
--     separate step per this step's instructions.
--   - The existing 7 hardcoded tiers in index.html's DEFAULT_UPGRADES
--     / admin.html's mirrored defaults / mining_config.miner_tiers
--     are not modified, removed, or superseded here.
--
-- Cardinality: one row per miner TIER (not per owned unit — that's
-- mining_inventory, see 0014_mining_inventory.sql), so miner_tier is
-- unique. This mirrors mining_config.miner_tiers' shape (one entry
-- per tier) but as first-class rows an admin can eventually manage
-- individually (add/edit/deactivate a single tier) instead of
-- rewriting one big JSON array.
--
-- Trust model: every column here will be admin/service-role-managed
-- once the write side exists. This migration deliberately creates NO
-- client write policy of any kind, per instructions — "Admin/service-
-- role management will be added in a later step" (which will use
-- public.is_current_user_admin(), see 0019_admin_auth_foundation.sql,
-- exactly the same way any future admin-only write path in this
-- project should). For now:
--   - authenticated players may SELECT active (is_active = true)
--     rows only, so a future frontend can render "what miners exist
--     right now" without exposing inactive/retired/wip catalog
--     entries.
--   - No INSERT/UPDATE/DELETE policy exists for anon or authenticated
--     — with RLS enabled and no matching policy, Postgres denies
--     those operations to those roles by default. service_role
--     bypasses RLS entirely (same pattern as every other
--     server-authoritative table in this schema) and is the only way
--     this table can be written, e.g. from the SQL editor for this
--     step, or from a future admin Edge Function.

create table public.miner_catalog (
  id            uuid          primary key default gen_random_uuid(),

  -- Which tier this catalog entry represents. One row per tier —
  -- unique, not a per-unit id (see mining_inventory for owned units).
  -- Upper bound is a sanity cap, not a real expected value: the game
  -- has 7 tiers today and is very unlikely to ever need thousands.
  miner_tier    integer       not null
                  check (miner_tier >= 1 and miner_tier <= 1000),

  miner_name    text          not null
                  check (char_length(miner_name) between 1 and 200),

  -- Free-form icon value (data URI, URL, emoji, or inline SVG
  -- fragment — no format is enforced at the schema level, since the
  -- admin UI that will populate/validate this is a later step). Not
  -- null so every catalog row always has SOME renderable icon value;
  -- see the seed INSERT below for what's used for tiers 1-7 today.
  miner_icon    text          not null
                  check (char_length(miner_icon) > 0),

  -- PXN cost to purchase one unit of this tier. Upper bound is a
  -- sanity cap well above the highest existing tier (26000) to catch
  -- accidental fat-finger/overflow values (e.g. an extra zero or two)
  -- without constraining legitimate future pricing.
  price_pxn     numeric(20,8) not null default 0
                  check (price_pxn >= 0 and price_pxn <= 100000000),

  -- PXN/sec this tier contributes when owned and applied. Same
  -- reasoning as price_pxn's upper bound, scaled to mining_speed's
  -- much smaller current range (highest existing tier is 6.50).
  mining_speed  numeric(20,8) not null default 0
                  check (mining_speed >= 0 and mining_speed <= 100000),

  -- Whether this tier is currently offered/visible. Distinct from
  -- deleting the row, so historical pricing/speed for a retired tier
  -- is never lost (matters for anyone who already owns units of it —
  -- see mining_inventory's denormalized miner_name/miner_icon/
  -- miner_speed captured at purchase time, which this column has no
  -- effect on retroactively).
  is_active     boolean       not null default true,

  created_at    timestamptz   not null default now(),
  updated_at    timestamptz   not null default now(),

  constraint miner_catalog_miner_tier_key unique (miner_tier)
);

comment on table public.miner_catalog is
  'Database-backed miner catalog: one row per miner tier (name, icon, price_pxn, mining_speed, is_active, miner_tier). Schema/RLS/seed only as of this migration — purchase-miner, accrue-mining, and mining_config.miner_tiers still remain the values actually used by existing game logic (see this file''s header). No client write policy exists yet; only service_role can write, pending a future admin-only write path built on public.is_current_user_admin().';
comment on column public.miner_catalog.miner_tier is
  'Unique tier number, e.g. 1-7 for the tiers live today. One row per tier, not per owned unit (see public.mining_inventory for ownership).';
comment on column public.miner_catalog.miner_icon is
  'Free-form icon value (data URI / URL / emoji / inline SVG fragment). Format is intentionally unconstrained at the schema level.';
comment on column public.miner_catalog.is_active is
  'Whether this tier is currently offered. Set false to retire a tier without deleting its historical row.';

-- Reuse the existing shared trigger function from 0001_helpers.sql
-- rather than redefining it here (same pattern as mining_inventory).
create trigger miner_catalog_set_updated_at
  before update on public.miner_catalog
  for each row execute function public.set_updated_at();

-- Lookup indexes. Expected query patterns: "give me this tier"
-- (miner_tier — already covered by the UNIQUE constraint's implicit
-- index, but declared explicitly below for clarity/documentation) and
-- "give me every currently-active tier, in order" (is_active, plus
-- miner_tier for ordering) — the latter is the shape the future
-- player-facing SELECT policy's typical query will use.
create index if not exists miner_catalog_miner_tier_idx
  on public.miner_catalog (miner_tier);

create index if not exists miner_catalog_is_active_idx
  on public.miner_catalog (is_active);

alter table public.miner_catalog enable row level security;

-- Authenticated players may read active catalog entries only. No
-- policy exists for anon (no policy = default-deny for that role
-- under RLS) and no INSERT/UPDATE/DELETE policy exists for anyone —
-- admin/service-role write access is explicitly a later step (see
-- header comment above and public.is_current_user_admin() in
-- 0019_admin_auth_foundation.sql).
drop policy if exists "miner_catalog_select_active" on public.miner_catalog;
create policy "miner_catalog_select_active"
  on public.miner_catalog
  for select
  to authenticated
  using (is_active = true);

-- ---- seed: the 7 tiers already live in the game today ----
--
-- Values copied verbatim from index.html's DEFAULT_UPGRADES /
-- admin.html's mirrored defaults / mining_config.miner_tiers
-- (0003_mining_config.sql) so this table starts in agreement with
-- what players already see — this migration does not change any
-- price or speed value.
--
-- Icon values:
--   - Tier 1 ("Miner Power") reuses the EXACT existing data-URI icon
--     already shipped in index.html's DEFAULT_UPGRADES[0].icon (a
--     base64 image/webp), since a real value already exists for it.
--   - Tiers 2-7 have NO stored icon value anywhere in the project
--     today — index.html renders them with a per-level, generated
--     inline-SVG glyph function (MINER_ICON_INNER / minerIconSvg(),
--     computed in JS at render time, not a persisted string), and
--     0003_mining_config.sql explicitly documents excluding icon from
--     miner_tiers as "cosmetic ... not authoritative". Since the
--     column is NOT NULL and no real value exists to reuse for these
--     6 rows, a simple, safe PLACEHOLDER string is used instead:
--     the single-character emoji '⛏' for every one of tiers 2-7. This
--     is a deliberate placeholder, not a design decision — replace it
--     when the admin UI (a later step) lets an admin set real icons.
--
-- ON CONFLICT makes this insert idempotent: re-running this migration
-- (or a future migration that also happens to touch these tiers)
-- never errors or duplicates rows, and never silently overwrites a
-- value an admin may have already changed by then (see DO NOTHING).
insert into public.miner_catalog
  (miner_tier, miner_name, miner_icon, price_pxn, mining_speed, is_active)
values
  (1, 'Miner Power',
   'data:image/webp;base64,UklGRgo3AABXRUJQVlA4WAoAAAAQAAAAKwEAKwEAQUxQSNwRAAAB/yckSPD/eGtEpO4TjiTJbRsiCYRq/f8HU4BBZ98i+j8B443Tiiqld4gsnaolRtucsxJ9fHJBNphVIqIrgAKHSJMgIrKIaNIa9wlKAWbmDkSNL1sAd/fMutabamLABlLPbAvgV2y8g5mTy2ezB+H/gGHqA4wTrqpNgGXT3f3oAcQsGeqOlYiAGkFEsqELtReGO22sbGc4cttGkmT5/6+e7tQy6HtETABf3iZQSNImLbRLZdGHtCvZvdL9I7s9M/aVcQ96BzdQFneVS9pOtNltO4Dslw48kPCeswM4koGfwSW5hGHODjzCdXyQvULpZrF9A2l51CyWsbbNq1PmogIqOJ8hgvNokpVfNSYxSf/Uj2Tbqm3btuWpz8NMIrPE56h8xKMfiSJwokkaUxBOCDbO0bPQ2tjU69i2tB0RE+BJtm1ZkiRJ2hdJCtX5D6PWyShor2prSxQIf/Huu7vxP34kYEWgi82ImAC5jSRJkmSlv87rRGbVPpjjjoiICbC9bf/5SNLzfn5JOmW0rbVt2/xXvKc6s23b9tieqdk2y1Wp6gqqknzfg6SX1d86jYgJ8D3/f8/+uorvDCEQ/77/R74mZ4GEzSYbED9KXPB/TRjja1oiwfDE0GB12/BAqVCaOZZl7CNz5qzyub23dZFCEXW3y+PxiFCdmbluWj/Kjx6ysQ8qevLIFz7l0L7JaqVchJB11swc68iROdPT0IZniD4kExOBQzmzctty3zNzWrPb7ZooilK5VJSK4CY155w5tn3f77OLFKXBaqVSrlSKoni0LqGwU3tjY21hsbawlCg89iGB2PX3f/NbP+jEzz23mT1n1aNHaidSVVWzqhIiIoooIkIo33AgVo29uXjhnutuXUICXZsYf/Jff7+tdZqcefbG7/+Ra3EgqRZlz3LkvU7fAh+J+m+PKCTQh3ItalNty3fRRozVQpL4UMOxceuCyHfXdrruUpm+fSCieGgK8113iju/RyCwD4PLl/+alGGO+kfPb7PIB5r82zMyWf713w5Y2IfQSL/8/a8E33Erpigiqj4AouYf/hl+y9DQQ2sVRVSna0n7x1/5povq5UsVdKWztVBf+8t/wu8ZVvtEIeVDTPj+v/F918BUqxBdOllaenz19/4TftekgbOzJXeTgyfSHn/FN96xfKLgdnQuRH3tt38j6vuGuL+jGzl3ghC8HpHz+4+4IDm/tP6EJ5AyTh57QiFE50ogvO3tmKzX0aoKkw51K7TxnMPk/tExck3OnIA89GYcmbd3hz/dRUe6jWi9aMQi80d26fuWg6eLumOvJf/Kw/o+t3UmXRYbL6iS/d5oxKe7Q4v+afhVOPJOlFtTnUdXlY4TCES0nj1G7ksLN82WXOToMfJaHHlnrf72ASnIkVuEWs/aQe6rc8NdEvd1IgQSxcJrcWReTN3SDV/l2mmya2NhN5mvFq9bCWBdVtFZBAQxHziyzmjdeDFsPDM2p82u9sJucn+7836BzebQUU+x4FGUdS5WvvxnzX1LdhoBVmd6p8h7bVz84594er9lDhsRFEtpAmWdYqb+C18XplaL2UkYoO7sHpHzUnl5Md40hFZz2ERysdyZRDnnaMygZ25D2M7iQqSZSZmcV/tiK8jItQg7SBCKWms7yjnp0mqgiRU5cWHyzFiQ84rZOYCGmkRmBxG9clz4fkfOOHPb+nOVIFEw1xxVYOC3t5L1evjU84e7ojePOWr0L6a/u45zbtetT9rblqGULnSSWwF/ukkm28XIwR1PaMtA1lDOGtEbV77ZiIxz6cDwc2R6vyr56Jr5G1m/Z9zjXRmZvkK2S2epTzTqa3LGje0qYoO+akLlrLnX4gQm3wf3lAi5Ry7JB0430WjtI9vl0t5BhZiWSlo6yr3x0mQZ5RrsGU8RMbeVQg6bLsRa2ke2m8m9hULhGop8bHlxVwnlGoMHtqGIoFHIB06QY1W7EZlu9g8RUo8WdeksGFK6sifIdbOwi4joJx4Fx3EriFp5O8o12t8vFKFQaBHLx00b6tR2B7lubn2XQ0UfSqMPFEIsagLlGgd28ZNfb4/15KH22KDDXKPu+VGR7RP7C33tMWtFBDltcv1UW57INbl6uEo014ianHo64wLlGdo9ThFzjYgcOCGPL58YELk+Pq5QaK4lgk5z3z79/6l8G9sTiojWJCRy4Aw+/d/FAmXZBo8PExFCi0Ry3rz/L9MyOb6e+EgXV9FK5MyF2A+OkOu/8HxuPBFJUMcJIVXOtl99Y9uTRCjnzh6bs+3nP2e2hVpBO06y0NLNNHV/8mu2WSstIodepLdMMwvNdYJC7FAEb+tZZuKeL7U76pGxnDdty/Xx9RWUYdKF059zX3z+zCenz+fpLGucvPc5D1H1/Pz5B37ut379v/71gXakyuPRY5fWcWZZq3+af94TEkh2t1s9+PgnPXagffxP9QB0JLr9vvlV8nvl1LGJTrK7Kao7n/mcowGw+7qTJYAOlEQ+zc5k2OXh8Y1UGZrcOTFx8HAAJFE5cV0BQp0mSelRv5xd8sOHqt3Hv3hfuUIbsKUgxfzvUrAJl2uVR/ssyitrZW3/+mNeQX8Tolf8fqncr6Pc5rZ0uoWzCprlNP5a3Eeiv1T565me0HF0Iy7Pkdci7S09vg3q+VdVue+OEpt6VsyfyywYe8bBZRD/phwX/4b6rPMEUevOrjLrq1N87x2d1OnayGiz2bNu/P16bkl8hfWxD6vT7mCM0TFqCUdS7Wu/7GTW16b6e35cTp0OfcVBQ/aklbtbuAHNH/zs1Eq9gySxyUZIsrW+zpawe/mfp06cXrvSbCZCpVNE0kypG1uD3u7KYw4NRqe2XH97oo4gSkoppVJpi2AQO48+5TlPetze9Gc/WjlmFZycysUWATCYYnjPY17wD3/5fdLLxcztEPKzfVhnYuzMSqmnXup+rAXDj2jGbeLm35REby8Vc10WyAcddcy/f6GCkl7sOiYDbrZE6X03DSKvP/O+4S06Anzo+0P0Tq8UhjUB3GxJ0hc/XrUNerGGxYAbREfih+8v0zPz4tOa2w/paIpfvjeRZtArzXqrlvDpsTHDep2oXuxKY8y8fg+0NI9sTWMvlkhA3HqCB5aNXmyGcAujJ/t0cZ2X3hkSGHR1j6wNTa8TSkjwYVPePoWFeeXLWmB80NTnJ9dBr/TsT115k5w2bm15PlLpGEpf3xBS6ABHuzLlvNOmvJUDF019orMEcGtMDhuQNmVO7N6VSbyeqB1sSfJiA7hJT9NH24t1cz97EkzAm6NmtQSS851FmjrBw2HLpqRc38sNwmyKyQuWUR2ROV5HyyGQsyMwE1/FHiDSnjg57hwEUNWTOjuqQDbFAl/McY6enHoambMnFi+5bIqX9nqlg9UTCi+c8ARpq3K+Q3ScRmfmfq93tZoyCrG7E0YAm5Kc7hhTpCkCuu4AbaBdCc7n5fM4m1LyakMY1ROzs6Szm4NGVn1/PEpTz3MIYE+eT3aQTo42ZYMdYzdo6p6Xg3YAak+eTzvKvSsC2mnsSvFig7S1Kl7M1Z7M4uIOYlPq0Zw0aOqFs9oVfTnRVhEUdox0dvMFv2hPthMBTbnfcayO5HmZ89oRPl/OGzZlO4+A1RMHOrUnBYKdxqYo13cKenRMqyf1orAnAr4gqydTHu4LkLpwSON9kntTtk6yS1tn7DAIduV+RwGiJ553X4y+fW7sPNGTb3B2lKbuvcNqTw5uRzqVvEHTUpN4fzwWLd1OUydiS7Cj7EpLL9hp3qdCYE9mxznalk4kRXTkbU4cFi19sgMZ9HS+SD1WvFOiKzvUR0/eHPrWk112HG8/N6bj8PH7nhza2689ydhOw+3nrpw54p3S1WPVGyUqe3LqGu8UZ08eBwqA6kkH6uwXe91YPdFZIiDce5Izp7WtyaHVWbQ60qkurWNDzlvG1vQS78+sjkvntiQ7zGqI1Tva0ZDnDoSNb5nChjjtYeNUTP/qv2E7vn6cZM3jH8+0JG8xNrzJlMF6O3fXHNpiNK1NpKBZ9tCFG++vS1sIsWY2yQgVjEkLt9w47a2DaS5hbw44hLGGVGycuP6B5tbBV2YF3ixmYT0bsLR4x531rYGxTswWZvNMY80aOFkbJxauGOdZDwK49MtV2XjbEWZpGGw7OaXl+TZ53EuX53azdvozd4WNwfZqCSmIKiSvztVRvngWPFs1K3Nb99HpNK+s1upDf/S7Dy1zwiiS0CUY6nN18tBn4vDYzJE5xsixb/u+j33b79vIaVQemdw5+eNvaO/t5d7tqJPI7ESntuZrkFfi7Atrzpm5bcvy+Xm/r+s+56xZWYIgWIVKJYn0Vsjs8uLpJkKRYTvRrdcTvhb4KHi6Hloz98x9jH3s+7bv654jcy/kGJwLolXGGKh1YfZycp/XME62WyttNm3PguuVMzPHNvbct5GZY2bmnGPOOWtW1SyRY0AIhgIigoey6BWCWtscMCFpdBl2Mjb1hSbaVDwJLs8xxxjbtu3rcV/XnHNWpQhyagDBQ0FEEEUEQUQ8sRCQRHMEEc7XKeuMU3JKTmwsrPB/3yW4Ombm2Nd1vX8u67ot+8w5UxEgAEKOAgIIgiAiKB4QURAR1SpEr6j14LJOgAhhZinZyU6mu7yc8Eu0HM8jM7flfv+8L+u2rSNzZiLH4FQQQQS8IPiEoig+EBEfAEIUyWaOGSHXoBjVzrC/jP4HvBRcHSPHvq7rcl/WdbtvY8wxCYcjEkkSiUToQUuSUindMrEQseHikBF3nBEKYaJ1cm3voKz/iCdx8myOfdvvy/K53Nd1WTPnTOUYEI0kFUmSSLpFRCJJKaVSSilltBA17+3Sy933DiJZja10YXrvdsl91GMguFpZpVhz5li3Zbkv9+VzHZkpAsGpoKAjSUqXpCiJRCQSLUqplJKSFrQQ7jByzlyDoBRsI80xPDkoSfzrNcbYt/t9ud+3nGXVnPvInJXJaQAHRRRFFJVSKaVUUrpFIpJISkl5k2q5TeS5u7l2DOaamWc71F5fW20018vlUinorG/Lb7/973NZ1mXPnHMC8jAgBBFRRBRRRNFDKpWWjKTcEpFIkpKyKSmSd4PHHmaXk3bTDclMMNh2EenK9OmpqcFqtVLyRuPzcx+jBAggEAQEQfFMRFFUFEWlS6pUSikpSbJFcpOSkix6aJH2mDl7RmZcNaRCqd1UIBBEcBSR4oEggiIexBNRUfGaSqVSknITEYkkSRZtkuQ+i8iReyeERBj3lZCkCEUfEUU8iIgIIooodRCPeEQVNZVKZZGS/BTJ90TykoVa7EjPyyCiE9EJBU1rYRomiaSkyhdMGLFULrkpKUmyiBARkTxJREQkFdKxQjGYx+hEJ521fIOLaUpKklKpEkawlEqllFKSMiQSEfINkSy5iIhctBx/JCKHdCKdsJbFMjFNSdJFFSPvNiml8iDJlk2EEPINiciSRUhus5N1eTchM4l8k4uJVZKUjJTIZLJQSh4kSSIiQr4lIuQ7hCCjm+MvZo4ZIexmsljefZGSSmmy3FdSskiSRUOEEAShEyJECLkJYqF1tHKdmb1TR6TGwppM1kWSFimlpmla1iySJC8SIQhZg8wQQshsyMy9taPRBSFkDZ3OjKHlvkGSvMm00NBK8iARESIIMrPmQRCyZm8gsrR2Nt3toRNEp/lmGyLKRZJSbltuh0QiFyEEQa4NZM3MbKFl5t8aEkMnHeY6WIwkKYmIJJIkiSSRyCYiCLnJ3uGYe3YPgIfHetzdDjfDDEFi7xhFkkQiJG+SSDYREYIuZGbPczdajnJdvnA+1hHzTY4kS160SeQmZBFCCPKk7e7hNa9ee34+1NFJsEu7W7JERIh4EJEHIQiZC42Zb8rzb1/b7QONQSfkOtrlmkjIgxAigiCEzKyZjXu+7XPf96l/cu5zndZgkU2bzLyIIDNzozHzmD/sle9hl6CFNdeMEHk4oRNCXMjMtZPHHn7T731Dc80crJv7BEEne+Yga+5dePrBfuJbHMaQ8F7LzMLDnKzy+Gue9Yl8z3XvOSPzjeHJ2ngoX+6lNna5hlyz5hpP++hZX5ranXzTnQf4zHWvNLibfCufvtAL7c53oE/1vm9NL+/Jo5f/fANWUDggCCUAALCdAJ0BKiwBLAE+YSySRqQioaEm8rtogAwJZW7hcIDA641Z9jPexJ7zPj4r5zp3Mrsj+oDcM851p7FOc+bP8t6JfNP914V+ZH5DKicVNTv5x+Q/4X+K9MvBn5lain5J+uPRrht9YftPQj94Puf/d9IT7jzy+zv7A/AB/QP7l44Xidfif+p7An9H/v3q6/6P/19An1n7C/8+/xm+WmnZFj826+yRsix+bdeyvZ5C7U2TguYtdoGYuD/oaM2RppDjrO6+bPY9nNpsLIvsjVHeUjJpxmIpaFUfHGEXuCty2+z8ln98kEWWwN2gbabxUV0YZBoD/8vTSb7vywzCuMcV93vIi5NIPutZdZ+bY21fg70oB5Vc3chcJTQlTR2BAfqyY2Y6qkAF0x8/i60WkOuLPSV5SYil2/oV1oKXrAiYeESzMJ/HkMLHWRMtuuXWLKNMLeQkwlyInsd0uB9u+Fww9nxAPJGnJhNSw2MQhy2MON7w0L9u748vvJZ5ozRp1QG3OkPCFGP+9ZA/o3rgOjxZb/ekvWi+coiL3PjBt1TR3xKXifJWhnzFHVA0PTBr2TPZJA53HjjnyexJhiVPWZINLa0gLke0L5h9RyOL3weXK5oxhHhFP/kxPxrkQh8fdi6bo54Opw5f1Py4VRhFASSheRkQwELRjyJuEl1KgqzMm8OgsG0+Sn3aC2YOvQ9MEJzT1rCVOqlm1FpEDVvRgV9h+XMm5lNoWZ/MClvUca2wOOM45nufui1rOw62dyW4hcqVg47+HXbDeMVuQHxgYezCCUVapKBmTNaGr3KcbIw7F9FhLsfTIupiKDQ/H26QsYbZoyDBuSadVGZ1oL73zo7ObswHnS70HjQM5eptqy66A2LOXIB2HyRPDPb3ZRifLNb/KTL7pIqU1h9vmiL1k9hFiM01wvwJYSQZvf9zHESG4Slkq6v2yn3edzLQLsNbcyR0YfnWK7FaOm1PRekjPvS7+iRKruPCrWPtUtYVjA930QWeRjR3iOn+TnQOZkN1xjoAK3b49+mTo9AhztXFSkQFP1OfcyjEIJPCNH3tFFDDYWNW428ySoyF01ivTfmG+fWSdlKuGEFbISzSpiiVXoheE2ANxr4TY0YAiLxk/QswZEODTgKZeGuQQIQsS9auYVLS0D6P1D6I5TtexCAsaNgxUbxalP54I8Ac5vBg3CO+ttew3zUyGoyZroziK/7VRYcXdIi6dNA3QVuYghjsvp2WnwywWsENrZ7SmR3nPbu5GiitvthlOWA5jwCXn1+4k+LEP37/R+4ETODHIB9y8gIs6BTMkGoBm8kZe3icBx9aje4o+gTe+l3bhYUbWQe70HNp10sHK+N4FNKHhq2yR7RgM5tB5k1dhdzPKmY3Qdfp8ToyLMHfmkL3SImLAMfVOQ+sKNstXbiUkUZD9QXcXLUVqJDyqsGbh+i4R087fqOf8XWlCFUJcXzS+OQfT5ignQOMDZV9egQ9C0px6wIrEmL6gJMHLmukwECvxVOkDfPuz042elj+x+Nsx3yaqpTXnEp2pG2JVOTn7nJ2qT3ye5PKj8DL3mKoHIUkghIM5WnzZt+qwHJ13ggHqkbfslrou+paWdGUM+6Jt/493+/87WVXdNt6zxqGY/4HQwkzZp6L5sfw4ml9thgyIDOXyrKxpNYRqZAVQGiQaoM26amQD0tJrCNTIB6WkOAA/v9psAAAAEp9JJB4KnBHt7avuZfuvYDX+55x3LiWIRp7PUzl820h96mOE9WldWzlLqsWysvxg+Wi41DCRb2d2uFkBmaor0UdP+vAwuwF7j17gG6HvOuX9H0NgOxIodLuJy2Xqn1T7/Rl5at11lRjhaI9u1XqVdsO7c2SMLuRxXv/qjyZI//z7tqH701wiFa9N3kkAXseD39MfSFi5a5Hh7VPJhkJnpmGORvf8T/+micB6cUqz0Jg5cUG+WEpStz8PRmU8GQ2vVHMrD/JLMu/vWK8GFko+SiTBPpndZIJTm+Jl/UscQ1Hye12YVUBRZQ9/pSNdVVC4Hq6Bkun1cPBHm2KfVPF67Nz8EYOBNbjU66MKogkoMi0XMeygfN2CYoUwkL5wKjcrfG193dWpbm8k0v8+x6HagkiExlHOGSImBUb7Bpa61vCp7Tra6jbPYP5ISxVoMdPXa0VrFWc+h1c94rWRjIe5KVPs7/2KtWJO3szyoPeeoXLMusAziQcKKggWe1LE9rZfcZrF1lbU68qsccLuEuZC9X4j2Ofvwhn+mpZtjEDg6qGs29i0VOjk1PP7w0EGCLvY7BHIdLrVFkji5f15fNHKnbw8VoG7zs5bB3BQdfqfb+eLAbGFqg0nrYILjC+WBPl3CJ10/mWTdDc6yI3tmF8WHh3HlYFs0/+6sJs+FCgMI1IFk+xyXMsQIceuoPwkeqkjtF6JbA+hZUG0jlG1x2W+QiJbnkNSMLcmeUmT63Nael2XoZsborwwl4qqGL+HxZ9nFYKvBj7FGiq2puNSoumOf7/OAcps37EAB5O4Nd4xsNu/XTiT4WKF0yfUq97g9oGsMaWCI/m2FZKQzVr75DtAz2hpXhEOqu3rQEOxh1OTVn3iWgaCRnSCXEK+AKlkUKC8Pf5hwDGIAK9HVXetiyjZ+w3B9m2W/ju8eBgGWKbZJ3zypObhNyRJ01sYTsWmXyoTyAv8Zod2MLjqtvLpgSyTSaNa3lmrAt4dO3eVLbVf0H4bcqjJTt9pimESLIRsqcbUkXuopuxz6dzCj0RVXub3Ih7B2U46yes/wtEoeJucj8XM+53fU2HzuXeTm2MVO7bBVXhdEA3H8Xl4dglbU8mKLwiNX8zGedRTzfieqFc3JasvBt55rv83eWekceowGBNGq0a3rl8+zzvV7jhAlc6vMo38u47/dO9DvOuIUCGiYQcDBimm9Kr4CZ4evmyoosRCY3KbXGEaqKKiqoswYs2WXZnXcUbMRtLlxffMab7/BijKBkOv10r1/kog/tw+Cf8oIQmSHT2AZkMG/fqXYAKtCi31o+RPULw4nLTdDSfT3AyGjhk6yMyV2gbK7qAIs7o5XbHMAVh1slBN0IeIgn8y9DzPWkxa0YBRd7bQYXQC/LX3ODwY5XrFYDWvrx6TZfvSP3JaGZ5aqquI9CQfA6LuYomfPIfXlXSzNYhD4YrjvYbF2RHjpUByYMzs97CCwpYt1b4hVKH+ZeNLoWKbXvu6osW6amyvNUa2OR29KgFmQqUXsFKmvQaHfLcIi8IoElbeUcWoU+YnkuTi+nosKbmBupASr402iV24iAG7AO1iFVbgW+KU4StEJps3KeYOyv/QeHVp489LExcEZuj6uREq9zI1WKvto9iY3ua+dfnlMQKADygG5QeGaQn23zdESJvEwT/+slAcjAA50dYrZG7L/04oUAIbHkjHbho0Kt9zXxtrPKAiAn31wydHM1wqz0vWsdRaS+P2OOkjoBpYI7O0WA4tfojPqiMQF0FIB2z4dl4vbmd7Cp8zQWT69mQkk5hblNik0scoFc+npO7/jjymbc8IKO9mCY64qqWQ+srgMV8Tid6h1eZLw+U4PhWL3KalCt2DwFJBNH5jbQZL1847oJR7wBaAPuNXU6Hx2SVP6XTUGyQjPcjRs15aXVoCqjltigXKU1Vhm1zhl/gOq2s7Hv3v13A4rxnumf0bnUeVV9u1Mw+lZvSEOidPad6yNjqoJ1xV4Q0O1aptDAXiZBu7Uthne0CuTzJAkmXW+9aTmKX1zhhR45L/yPFTqls6SZEbafB+jCZrf4z4vnysC0NYAl4b4HVxp2+irqSwzXqMiVF8724tsOxz9/+aTqV73ZmC2pczn6zJwrU81U9Se2/auCSPBKIRX7rtR9+VLY03sX7xEzdHVKChWKa1oxqNZTb0Op/qPdivYVi16hiKr+mnQkeoo6VdUJ8301DvN1BsVNXF73afP+WAJMSZW4/0MHNWsTB3q0IRPOPQrNm2DOo8MafAG5qXaMMQR2xdUekLCyez6i9MzBnV3FBqoPToHc7srsmJYvtgfozjX/XIQS2Rv5cxbDr7rk/9L2Yry3bwPPv1vD1EqB6MFtuWZa/L1pVGKpTUzILDJ0MmDzvc+ChZqmOyiHJOq25lIf+k23zeuReY/EZwxn8I6xEvDXJLAoyP9OY/BqDMOIpMVzW2p2X67vNycoLphrNOWYJ04jZQ7R9ZrY5j6wr8RBhqH2cQbFN32eZ0h4GqyoIsHm97nY6f6Q4XsIp6TNQZyx88/fdhDPcs0OapJnXQhKvmV8rGpMvE5sy0/XEdexZ4tKxJxiK+rRwtRpT0nhXzfdD39heOTcWVB5uzZ/vpxsVuZ9BzZONfiu66+t1Hggu82oohGiyp0AwG0lFxF50txHZa54AIX1NhfQnINErcOacno7BMS+VNkMvekCvjCMyrawAx76h0IAHcYrf4CqCc8pEQ6dgfpqe54EnQ2nm4I1dLSDMd27DtoeK//Lph0peRPG8rEkawUvJrum7b/Qrgwz7S5y2wKYEVnq9ryxy0NOtOy9I/PI0J5t7SgUIhQ2/30fRAuia6lCbBhzH4ClnLiLjcLhSn3ZN9BJrOURXq9KJ5iBoMKeNT4mHJqJpunHkPL9AANYZv+LmvoWSN6oP1FfCPMYlBiipUhN4whKyeeGxiOUgVZco4UwVnoVgpw78ubxNs0/AUfZ6uAmZ5Vq/0uv8A+zn+wSwo/MgF/+A/Q+Yd5mYglqrK7h08wlf5PL6m9CoD9/OdDmhIBh8AJAvDKpaeuR3DFM1+SFfR/6QLIQZCmTSZViZSVAEaogoP2rsLKkKSKnoLV4ZQHdev0ivOp50tP6yR+pEneFJxSau1gFI8Yn8cIHMXrAzKmN8YCq603i8Rq1anYoY1CmQwYWsPbGsShRNaUQAbifePliwF5x8H6QGR7XuQVX6q2t7DYIGpkPoRsmy/NwAut5t1QYgUp57dl236Dv3WQFPA+mkfoxc6AVg1VSCOppZbIYAABFav55168FTdYYdloWtvXss1CEPiWmqFcNFH7pVYB549Q3Jf3V5WYt6SfEJiMBmZ93EZqmkMYCuPwk2eRU5P42oMGd7T3TzPPJSRc4QEHIxyPMr69+27BfuON02qXmXy1TWKuX9tmxDSh/FEKNsItcCYk4IYjEfxa04iYj3Fsd6oUsjDuXRcx7yKw5EjpNfpRhoEq8ed836jUKbIRl3udRPGPMBFfY4OwkhBZEKcCAl9FAJMRZbBK+QpqsQ3N77k0uXd/jB4fEnTjawCeOVmJrMH7CEWjr2qRKlRSyb6jV+3Xi39fd6c9ZmT0PvfmLJoSSyjFWaEpbvC14qmUzcjHN5miDjSf+j+F3vp9oLRwW+E2E2hVxw17GEGntaqp7o3DNjy3h2JmaCu3qsMXNCYihp5MFk8M4Ok8Fe4n6m7Z3ZI9Eh6whZqPiWKmwjPXnnfEdquxMo6309N5s0CFJw2sKunGaSh1GFTHNFh0fSqEFctBZSYzQYNgOavG8f66sZ2clQXqr0++b33R6zLfIbL9qxelvOxmY8jI6fpR/8cgrQqgFfTels7XNjDTjsPIi8oOhHURjXlA/rUt6eufMUOUq03kj8CEexMa+DG0nNRW3mWTeSYXDtC6znJpBfJsPG6cDyFqXmaj6IfjwYAlmeK/n6LOJozZfuVMZhK0HJ7yolLvHDvxrQoviMl/BEgyWypLP/mnvsZd9+jQYXUluOoeYGFIPyeNmC3wRBbNUtp5izhClYte7pDg0DjR2zGFRdkOr15uzxNCGpipGN1pnUO53sxBrpHhPdlNWNKLIt2mMZbKiHPqwu2yY+vEohz6eYis6s3mzHmNfzH5ynvpHIHoK3gsX4Hh8SV7gs67TOTfv1r2KvMy2VRmeiZKSzJSW8S6GWtUQPHz2aqn5iDWSF7bVyDpM3Bh7bZ9rGXJmpxxLO2ZeqqcNiDx3Ep9I+GyqE31tOrVWGVfsN21f3obXHRgttm/agWmIXWGEmCf/CTQsQbnq5/U+i+5Vkn2td2Mo5t7E5tBjeU9CmntLFL850rHQTljzogTY/b0DNPMtSfCR9J38D3tbBN06goHWi9YRsP3d/ISrNs4OVQjfVYFR6RJWolPKNbuuiNaPWS2qXYFEnc8sde9UpaDWwcjXMWQcaGhB2KtVefsM2lgimHL5B7bhYWZmfUHs/J/bIjZmah+VHVxl4IwrfCNK4nXF+8J1P4SZgxCLgJ/cBqHdB6RlVv4/q/c26yU7XbGow79RQAaGlT1fRSfVVJFP5WbE3Gdr0FNNN+XUBpdEe/fB9TATbqVoiLZe0J40zXrvVp72Xhq+Zt1GFbAxsy1LMDIfm2RCpn3MB+s569JU5wYK0fRTZjwM9I1rj/YR1/K/h8TBTwOIdsQOj3u1QmiXbCNFLiJoneFNWQgBsObBIyxjrhxlRI4/vPUamsVKU/BkIfV9evgIlXNFKNY3MFH42m7Tav9uxtTNwgOo7RKYOmbcOPioLrWX+RNk4u3LPW+ea6O9/qUTRA7+5wZc/QS+icdJH//4nZ/4f+zxeJRUbTvP/67GRBs6d5KB9drmuecj02fEgNbRrnZ+77sOSYhisZvuJhmOrkl8n/3IAf8PMiS1P9K2Zlnf8MignKGy3v8atydw/38PK6ce9Wn+ajA9BRyM4VuubxcMGo0CULpSfrYu80cF1NtDPBnjV0OfqKgERS4E/2e4RjkAMrGsY2I0ObD1k1MIY0kYl/MmjOtCsDFqK6X0uxFd3eVgbzttVDRxzzQRkMwC1olmfxyvisBHghv7J2e2opXB/lUTf/cR2yPzuW3I8Q8349H0eRC8sgmiY2QUF8yeiMQpjnsE+/u8diDm2iLEz3SsQek06A94F3vv5DAWTNE9IpHrLUAmj5MuvHoHOw1/kocRjPvLke/zdF+EnNJQkfuyboVqo91YcjYOcdeElx4DAbt6dkVD9I0hmX3rdvT7W1UgQxM85UecKzoRg7t2NdZpcvvT5xXuu+e3645Nbbl/VmOebPcYtLNf1lPb83nHkaoo+QimVLBjrsp/vx9YCyI+XLkdsXSEB8n8Hvq1wAH8b4ekzyp9lDbFNZhBKgrJlW4VJfztpgU9UUkLiruZviOv/bTtHQqSBGSQOfl7fx7j4YqjxMCiNklSX3bHuxmQ4vSLDPZWSJy7zEo3zUUQtemT5jNMnqgDHSEnBB2ZEbPVBo8pboW2iGcw3f7HYjCr7N7NoqRbL9z+tI2SZN/WJjvXq49ZVrPoOKmSUdr1a9hXvPvFQNpGgUl1gn+2n6QPwAZLcLSobDLJOZ7R5MNhvR+XWzGcwrWdz4iVcpZgq84C3+rryxIfHCscEuXzsWJqsrAF4ErVKcyaAKF2176iebJXCOCuZTQ35VrJTSuh7wvMmQK/1RXKqnx/tLv9omlSwEC55FTzmP5rOqzmXdIWQzz2/HhiS5mgrHAoY3nbtDxhZmI/NExHlqUJfzcyWs14c0LP2Xx3+6/l40pGu73cJu4bdKUQyZJRUg/+GRADzIN6QYhXzCkasAR4AZ6i3cUp8NNRjR0CnTZc5AVIovmPSY4SD8XySdzVahgWSbOAtT4pN/iSlI0eOqtKo3ps+t202aMFq3Jra/xeBqjBmepc8DIGGSdOBpCw+7oR6ZtDKe+TpKQQ6Vifg3Sh4nEgOKIKkIj5b2CZQJ+56H6lITuT6Tsbpr+/XCWWTxReoYepW0f22tMJoxmH+R1iZjtwFMWHlprJXRWFawx8wlyJsIqQ4IBSmY13W0O4Yd0y5dWfgCHfWMIqphc9IPGRHzntes0ginQANnbl/Or5eKzHyKfPytkusqnWrut7PFIR/vtV0SY7f5y3EoMyMmUNJNhTmglj0dgJA5Sz3Ouw8fIyoVulb40g8yoB1j5PdDp22eMy61XBJd8P+zN3S6zRtKRksxmX+jsTioOJrfx8eLD9IhLRYbQ8vJThZ/efERtMl3lH+rIZQU1jt0bbISrNPqsX61ShvxHJ14valFN3cY+EMjP2rHVLqMUzEYaK+10yBpol82bxShfa814HwvWf8/kr86CJI+fgdSgk5h6yB2Ll6/gXK260uXPxLBXd4Qv83lPBnu2iwmJLJPwcTEKEag6SryXI+x0LdFgjiAvMZpp2YbrxPsCCPcdGUES2m8lRB1ALAIX93x58SbJzlJydsaf+aAsE7o5mO1fC1EZ1WrmeFU06sDTrfekQ5Yqukp9Dr03z4pJBQ8UJsm5I7hIQpTm4yvVvt3BGxk011BTNGNKB2EQ2gdww5muw9r2C3pyJY67FrR6aeY2citj4kc+doD3P8qyr02d4W9YuPjBRCFsf9tl6WuGAZ08LTQaTqHrIFZp/gNCynAA9doYhQgZ9p/7HYl3lBA0ZtG7bUpx5cwznoNLayU44/6QpBjNsDrrvEY0ElNxZoAlEI47ADscoHaPacnxPtFzqwCE7z1IM4wFhXJrUesMPahRwUCe0c38w1DaxjvJo2a0Uu8mBHi0f7SZbrh73BvuqylPSGTQaNd0ydsnMB+4GQV94sWf3ViyMaV7jY4hyMjF8y9aBrNv/0f/foDXFfCGUzw/zYhZq1fQ1JdncJllBorXds9Nxx86Cw0CvXXt4R/FRX36zi2bKdYz16UIALU7QKR3Nn3jHXlTvWguDVJoI8lBWaIxMTBlS2mSvyADgtk+DRgivTKHUTHX5lYO2G9De7uZX8tWfSa5nyeOxn3DgLpWAywAO88eMZ7yGDPfOC8GsxCzJhpJ5RGM7cvtgZEweDZZF/OxlfDLdGOzZ/dBB2tabR3k0xgZ/Tf/B4ivPHs7Z8XI78FIC8A0u5rsC05J6heE/BDSibS3l8inQJDJBTWz4JmuPk5zUWn+QWucsk1lY3tzIB30zNn1OIxajlkejT6l5bVpuyleAiZM8v6pcEYvAeVt/fJz655UPW0qX+DHUUEslggfs3VjZe7lhclaMbHn39IvXPmql5D06cEcMjCIZBNqyPwREwuZx7MG/hD4XvJqC45Hs7Pf/QAr10ox2s4iWJb/DnLfHlpqsf9XqsfJlM47lMNV88rebL2SZXM0+HCgPgGqUKBDQN1LUlBwsuax1AeXhgwUTuTybRumSzUYKFnLG1ojdjmD9KSLrs4cTnQJzNilqmC4ILD1l2BMAvNp/kguGEuCwP3Y2IfN1LNtU+XvrBHe4R5ObgS5rxUvb7wcUFSFukA7O3+Aez5WO8x9A/G07BrWypybwtVZZEISbyImjn85pSjqM47gjw/PyQAbl1aIZf+NPETtcPLDiioY8+oczzt+PpyS+Smpjz6fYvK1pVpoKPIvJozylvPt8qgHUtOPjOChDAyO5kuu8BFRaje1uuyiXMvqVjjGyBxbrUX0rRmQu1SsmIepXpPsAYl/CfaAG2hgu1JLI+VAxUAgAPxPE7cxd+M/Z/ZZnekzkgZcuGUsquM/auutjK87I72toEQjaN+C7swNl4fqPlA1JowSuN0J3VkRRbcZT7T4PNmcLMRjq4LXMeNh8AJnFePXDd2J/b+53aw8cyuWQo1aF22GwlLJlz2XahQ5DHahaoRmbi3CaRWuIU+sb5MWWg/I0e8k4Ly/cHqOPDcNl3AFNcQxSTE4WsDMgHwLToa+Sax1xu14EB3fCfvLg5tYi0ScQ9e6ljHpHcmXMIDQ6d9xx2p7aR28U+z+nIplrzd/xhO6cMosi0Uts4a/75ohM9un+D6wnXiVZwkbHIRNXrzpblIk6uaMI6nB3TOTKE3MXUhCKYr7QFJChddPUPjzkQeLdrHK7QoQr+EqBuqQE7sGX72kr2ETB21sv6jTJG+JJvylv5yvlbmZQBv/FkMUVypShT1afzrYIvFJjyfYhacuC8DEYh9meRVaq9pBA5ggsgNpKilE99vYMZa/9ps1jAlckCB1p27+nXCcv/JhOmOSJ+7MB1hm5/dJU/wDy7pJcpCd7Y+ET40aLtDT8pLMrNNIcZUeGAKzXRtJnVbPPa4RtI8OVGYGTxP+inu5lLKe6O4jhNtDpm0lTKTbMxahEdWqdLj6BavlZRWmRbZjBYiphEMDAP66plvgGGjspCc6V4IkVV1ayghDFCDvINFhrCwRHC2Tgm2jPvib0cFS9GrqG556nYWiEEk4ZhMibkvUQ//ozmEdL45Rhuha7RpJdUU3AiirC8CIly5RmVcZcvmIdbqCj8rj+JhLRMI3WFx48lL1Sl2wFZO8/lQcl8iT6S7cOfdGAyQ7RZhtfbj8oWnS9m0j/yyVJBirzCfDRxuv43dy1c1Y4nzJLzxjnaidMYDV+bFBEUIl89mCE9bTjGQ3a9nGr/xMfOPJLwIVjUbYVd7duZuczYrZr3aTmL7jaLCwXm0q0OcExLNtn75Cx/eBRLnCdrVf8NqObvMl2mVWWr/k7H1tb1BuE+tkprJvcdG+K+HILIjX8peCYTWftmnslNQwOcUjEs5BREsp7GjXGcN0Z7rvqtJG/NtXljz4D4uVxLlJdggndYctxkekQPVS5feba+j9yY2lAdryk+I3tyEmYdaeLbc3JE5RyJMvX8b3rTuVmwNHoHvW0N+zZpy57178BpEjs/yTis7Nc96YUUJjg2n+ESmUhrXf/kLszY5jLbJejtxYl+nuvMLdYjzx9dn18EmaiyhN8HZmwLrSZ2CgVJqGkDEwlYoqpvMbqPu/PaI8C/s72q9DmiMgDdJPjlnDkHl9/ahPVxMdxQKezzddZ6eMwGjwgaiV1z6E0C1kRCcbTLUTsqOKRqqOGxGrsXVj6zOIPAxdj48988aOtfaBN+tQujTwQpJ9CKV4FmcDFzi2EkhvLnk/kH936Qb82EowBtMeyMoDVGZH+8QBK4cbPTb4TVXg1glVWW4U8qDfsEazm/lq8GBVE3UaK6UAl/+21QuKKBNB/r0ZO435vMXLFkTnYRtj7evGGeXJQWXgNrO6AjFkj5zFZ1EauYPUZGQPtDmaqMzuHBP72ssobJSaDirrfUuG71CbfKCXkO7FbhkswjTNP0W1HZ5RrxqWRZS8J0mOTDI1Ba04bv3rHNMWTJHsjI+ODMqLbs+beBmKDpPpxP05TRsCbpcuULKw/jZk9MZ9dAI9lQYqsn51D+p59O254S3qnHYTRanT/PmiQxX77NOy201ZiAgi2PkqeV2az5zNYSAzF7mYlzhUTqhvpvcdCjOLrarrXxTjen3D70ryzp2eLHGMpLpyD7J30n7VSUHA9D9cKX759AtF41UoQkR2Ctu9snGYSNjFmSoEZKppRwcbtPqSQqdr0TPK1iGRiLVj/3TL4FG62w2yRRYHKI8GGKtPbhctCwXI9v4LZuOmCQeN/ev+HC/4GU6c/yn/soPX7j7AJADxWSvsdTrEXUi/S4f1if5NP+UfAWGra9bnmhycQzez4RK1xzedeVWHMzSR07jLpRzWJAdQInzifdCRlpAS+JXWdxOscSTdck+M8xwXbldjYYJk+SfqYDTCPJn9Tjaf0XMF2Sk8KZVssb4DOxxbE6cUVkcwo2EeOlDe1eJId4EBvkv+JSuZn3UV6BvFqht6sMj496wC22r8vR1qABFBxptI60aJZyS7a4f0pCv8MN+Qlp4q3bQnknSsf5wPQOzStgutkTsuqaViSWQKo/WsgbBUCMm/qXFdZXAf2N3O0T6m8/WUttPhaSyI87EcrQgEGPr+Lh1p3X55y1LF0Dv5qz8/rYTf9eGgzOE7ZPpl5CYCZack77wCVFViYj+mMedn4SFnvlmifvJrIodkkwOwEl/2enBPeAYuw7r16JwEqxd1tBbI8QCc6nIMMzl2iLoKu3XvStgdc9zk/dpA/UXlrk6N/tdOMCu2h2pHZcxpql4w4GzNG7mGZCg2q1bLn7ExbYt7aZQ0NpnxmT/Sds1pN8YQoiGsfwTQHk30awSasLPeBnSbHnnbT1xx2abiGoHqaQH93DC07FQ63XtpEnMMBBppWSr5osMQha1mPAtP8ZEtl1b+AbOhtYYjc22+I5bUpRtBzDVZV3ni/AKp0mBGt6xw7Hfxu2S1B9Bs4YZ3bOmvTAxV70tEMGCYoqFHY3iHSUqp7E0GMHrAWRM2DidCBKQf274peSewh5t3f3aofRvHjgupl7ZuxGLdiYYd00rV7vATHJXrVAFb+43RVBd3L2jQnzIGWHlCoejwH0OpYhKJRYnZj8im3lDjdrQxl7I8/SW5ksc2UgoyhSqdISxA3bvm+LRi2DEv/EZ9RawDJbDUhqmtFi5kARrT5zq2mP9PwpQTUML3+L+r+BIsF3fBstkuTGiAK/vkMU11F71seJDOL2YwQhc9ftXxelZdXmecrqis1fntm+sczu/DF+BoeoY1o6YmkfzH82qQbUNrikU6ikGGQ7/gwFhuF7gxC1a1ugWuC/BvIS51rTzfcl7hkCBsbVQ++coP7EPXIujQCsRFUU8e5tl6MHlTsQvcHEwmqlF+9s8yOfbju12eA4v3VXT2pzdieyN+g6DiqaTarUV61KX3I2DZE4Jmc5YBrR5D795BQ2yYQx21p442hCg/Rth61el1Ow8Y3sWovc4uCEOowz9Wz6ZvPW88oWQhDsinyfwH97bRfaw337ueL4TdzETTcH35TZ9KS7JQdj4t55oAU1fKBOKTeJIDMkmvKXAQCVXPZBqTVIXliGH5k7f/as4niO/gByaYXnWwAAAAAAAAAAAAAAAA==',
   0, 0.10, true),
  (2, 'Reinforced Bore Rig', '⛏', 200, 0.22, true),
  (3, 'Cryo-Cooled Extractor', '⛏', 650, 0.45, true),
  (4, 'Plasma Cutter Array', '⛏', 1800, 0.90, true),
  (5, 'Quantum Drill Core', '⛏', 4500, 1.75, true),
  (6, 'Deep Vein Harvester', '⛏', 11000, 3.40, true),
  (7, 'Fusion Mining Node', '⛏', 26000, 6.50, true)
on conflict (miner_tier) do nothing;

-- Nothing else is touched. In particular, this migration does NOT:
--   - alter mining_config, mining_state, or mining_inventory in any way;
--   - grant anon/authenticated any INSERT/UPDATE/DELETE on this table;
--   - change purchase-miner/index.ts, accrue-mining/index.ts,
--     set-miner-applied/index.ts, or admin-set-mining-speed/index.ts;
--   - change index.html, admin.html, or any js/*.js file.
