-- Pro-X Network — initial migration.
--
-- This migration intentionally creates NO game-data tables yet
-- (no players, balances, inventory, marketplace, tasks, referrals, or
-- wallet tables). Per the current migration step, only the backend
-- foundation is being built — schema for those systems arrives in
-- later steps, one system at a time.
--
-- This just enables the extensions nearly every future table will
-- need, so later migrations don't each have to repeat it.

-- UUID generation (used for future primary keys, e.g. player ids,
-- listing ids, transaction ids).
create extension if not exists pgcrypto;
