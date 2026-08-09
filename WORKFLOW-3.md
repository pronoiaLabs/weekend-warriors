# WORKFLOW-3: WNBA dbt build log

Build log for the WNBA dbt loop (models/wnba prep -> core -> semantic views ->
Cortex agent), same format as WORKFLOW-1/2: one section per phase, appended as
each phase closes. Plan of record: the approved "WNBA dbt models and Cortex
agent: loop-based autonomous build" plan.
Branch: `feat/wnba-dbt` off `main`.

Ground rules this loop (user-confirmed): dev AND prod dbt writes granted,
including the prod build and prod agent deploy, plus the one-time EXECUTE TASK
backfill. Everything else read-only. No push until told.

## Phase 0 - branch + prod backfill

**Ran:** `git checkout -b feat/wnba-dbt main`. Fired six backfill tasks
(`EXECUTE TASK DLT_DB.OPS.DLT_TASK_WNBA_{GAMES, STANDINGS, SEASON_STATS,
ADVANCED_GAME, ADVANCED_SEASON, SHOT_LOCATIONS}`); deliberately did NOT fire
`DLT_TASK_WNBA_PLAYS` (broken upstream: endpoint returns bare `{data: []}` the
cursor paginator cannot walk; no PLAYS table exists even in dev). Verified
tables, grains, variant twins, season-type encodings and the advanced-family
overlap against prod.

**Result:** all six SUCCEEDED first try, which also proves those seven-day
crons work in prod (nothing had). `WNBA_PROD_DB.RAW` now has all 22 data
tables. Spot checks all matched the profile: player_stats unique on
(game__id, player__id), season-type encodings '2' vs 'regular' confirmed,
advanced family covers an identical 224-player set (224 = 224 = 224 on the
intersection), 26 variant-twin columns across 9 tables captured verbatim into
sources.yml.

**Surprises:** prod STANDINGS spans 2008-2026 (all 19 seasons, 235 rows),
wider than the 2017-2026 the dev-schema profile showed. Team history gets nine
extra seasons for free. Advanced tables are one player richer than dev
(224 vs 223) and player_game_advanced grew to 5,569 rows: prod fetched a day
fresher.

**Changed from plan:** nothing.

**Open:** nothing.

## Phase 1 - the per-sport mechanism

**Ran:** env.yml gained `wnba_dev` / `wnba_prod` plus a `DBT_SPORT` variable
on all four environments; dbt_project.yml gained the `wnba:` sibling block and
`+enabled: "{{ (env_var('DBT_SPORT', 'nfl') == '<sport>') | as_bool }}"` gates
on both sport trees plus a per-sport `tests:` config; the five NFL singular
tests moved `tests/*.sql` -> `tests/nfl/` via `git mv` (content untouched);
sources.yml gained the full `wnba_raw` block (22 tables, tests at nfl_raw
density, variant-twin registry in the descriptions);
`macros/wnba/wnba_helpers.sql` created (parse_record with no ties and a
compiler error if asked for them, win_pct with no tie term, season_type_name,
coalesce_variant, parse_minutes). Deployed the project object and gated.

**Result:** GATE GREEN. `dbt list` under `--env dev` shows the NFL set
unchanged (30 models, disabled trio still disabled) with the moved tests
applying under `data_tests.cortex_agent_lifecycle.nfl`; under `--env wnba_dev`
NFL is fully gated off ("No nodes selected", zero cross-sport leakage). All
83 wnba_raw source tests PASS against the backfilled prod tables.

**Surprises:**
- The deployed project object is named `NFL_PROD_DB.ANALYTICS.NFL_ANALYTICS`
  (not the `cortex_lifecycle` the docs use as an example). It now carries both
  sports, so the name is a misnomer; left in place, flagged in HANDOFF.
- `snow dbt execute` rejects `source freshness` (validates the first token
  against its command whitelist), so the freshness config cannot be run
  through dbt Projects on Snowflake from the CLI. Config shipped anyway,
  identical mechanism to nfl_raw's.
- VSCode's YAML schema flags the jinja `+enabled` strings, the
  `semantic_view` materialization and the inline `relationships:` shorthand
  as errors. All three are editor false positives; the NFL block already uses
  two of them and dbt 1.9.4 parses all of it.

**Changed from plan:** the plan said the seven weekly tables might need
disabled-model gating; the Phase 0 backfill made that moot, everything ships
enabled.

**Open:** rename/move of the NFL_ANALYTICS project object (cosmetic,
user's call, HANDOFF).
