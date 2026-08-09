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
user's call, HANDOFF). RESOLVED mid-Phase-2: user chose to create a neutral
object now; the loop runs against `DLT_DB.DEPLOY.CORTEX_LIFECYCLE` from
Phase 2 on. Old object left in place; cleanup in HANDOFF.

## Phase 2 - prep layer (23 models)

**Ran:** two parallel implementation agents wrote models/wnba/prep/: 9
box-score/reference models plus `_prep__models.yml`, and 14 advanced/shot
models plus `_prep__advanced_models.yml` (23 models, not the plan's
miscounted 24). Both agents DESCRIBEd every raw table and render-checked
every expression read-only before writing. Deployed to the new
`DLT_DB.DEPLOY.CORTEX_LIFECYCLE` object and built in wnba_dev.

**Result:** GATE GREEN. `dbt build --env wnba_dev`: 23 view models, 284 data
tests, PASS=308 ERROR=0.

**Surprises, data:**
- The season aggregate tables (player/team_season_stats) hold PER-GAME
  AVERAGES, not totals, and every percentage in the source is on a 0-100
  scale. Phase 3's player-season reconciliation test must compare averages
  derived from games, not sums.
- No preseason games exist in the data at all: earliest GAMES date is
  2026-05-08, every completed game from day one has box scores, and the
  standings snapshot's games-played total reconciles exactly to the dated
  games. The Preseason branch of season_type_name is real but currently
  matches zero rows.
- DNPs are spelled two ways (MIN='0' on 1,069 rows, MIN='--' on 7);
  1,076 DNP rows total, never NULL MIN.
- GAMES writes 0-0 into scheduled games' scores; prep nulls scores unless
  status='post' (93 fake shutouts avoided). One completed game (24935) is
  postponed-with-no-result; game_state keeps it visible.
- Player-game four-factors eFG% is NOT a duplicate of the advanced eFG%
  (differs on 4,469 of 5,569 rows, and is not the team value either); kept
  qualified as four_factors_effective_field_goal_pct. corner_3 equals
  left+right corners (double-count trap documented for the core unpivot).
- PLAYER_INJURIES.RETURN_DATE has no year; parsed with the SCD2 validity
  year, wrong across a New Year boundary, stated in the header.
- PLAYER_SEASON_STATS.GAMES_PLAYED can exceed season length (player 384:
  38 games vs max 33). Left as-is, flagged before anything divides by it.

**Surprises, mechanism:**
- nfl_raw SOURCE tests ran inside the WNBA build (sources were not
  sport-gated) and 2 pre-existing NFL failures leaked in:
  team_stats.game__id has 2 rows referencing games absent from GAMES.
  Fixed by gating sources on DBT_SPORT in dbt_project.yml. The NFL drift
  itself is real, untouched here, and listed in HANDOFF.
- Mid-phase, per user: project object moved to
  `DLT_DB.DEPLOY.CORTEX_LIFECYCLE` (sport-neutral, control-plane schema).

**Changed from plan:** model count 23 not 24; neutral project object created
mid-loop instead of at handoff.

**Open:** NFL raw drift (2 orphan team_stats rows); GAMES_PLAYED
overcount oddity.

## Phase 3 - core layer (4 dims, 11 facts, 6 reconciliation tests)

**Ran:** two parallel agents: dims + game facts + 2 singular tests, and
season facts + 4 singular tests. Both render-executed every model body
read-only before writing. Then the collision fix below, redeploy, full build.

**Result:** GATE GREEN. `dbt build --env wnba_dev`: 15 table models, 23
views, 586 data tests, 1 seed, PASS=625 ERROR=0. All six reconciliation
tests pass with evidence-backed thresholds.

**The collision:** dbt model names are project-global, so WNBA core models
reusing NFL's names (dim_team, fact_team_game, dim_date...) failed the
deploy at parse ("two schema.yml entries for the same resource"), enabled
gating notwithstanding. All 15 WNBA core models renamed sport-qualified
(dim_wnba_*, fact_wnba_*), matching the sv_wnba_* pattern. NFL keeps its
generic names; harmonizing NFL to dim_nfl_* someday is a HANDOFF note.
Plan said "12 facts"; it is 11.

**Measured facts worth knowing:**
- Player-box sums reconcile to team box scores EXACTLY (474 rows, threshold
  0), across three independent sources (points from games, rebounds/assists
  from team_stats, player sums from player_stats).
- Standings trail the game log by exactly 3 games today: 2 same-day
  snapshot lag (24989/24990) plus game 24896 (2026-06-30, fully boxscored)
  which the provider's standings endpoint simply omits. Flagship test
  tolerance 2 per team, standings-never-lead and league-balance asserted.
- Season aggregate sources: per-game averages; the two 0-100-scale tables
  normalized to 0-1 fractions in core (NFL's fact_team_season.win_pct
  convention). MINUTES means per-game in advanced/scoring but season-total
  in misc/usage/defense (published as two columns). The advanced five
  disagree on shared columns (games_played 204/224 agreement); each
  duplicate is taken from one named source.
- The advanced game source writes REAL ZEROS into 975 DNP rows, so
  fact_wnba_player_game_advanced republishes is_dnp; averages there must
  filter it (semantic view rule).
- games_played impossibility test derives the season max from
  fact_wnba_team_game each run (18 of 196 rows breach today, max 44 vs 33).
- Postponed game 24935 carries a fake 0-0 'post' line; facts scope on
  winner_team_id is not null.
- fg_pct nulled where fga = 0 in the shooting facts (source writes 0.0,
  which would read as a shooting problem in AVG).

**Changed from plan:** sport-qualified core names (collision); 11 facts not
12; dim_wnba_game carries the final line (only complete schedule, NFL
deviation documented); no made_playoffs flag (playoff field size varies
across 19 seasons; seed published instead).

**Open:** none new.

## Phase 4 - semantic views

**Ran:** one agent wrote all four views (consistent voice; the routing
clauses cross-reference each other), column-verified against the dev core
tables with sample values pulled live. Deploy + full build + one live
SEMANTIC_VIEW() smoke question per view.

**Result:** GATE GREEN. Build 629/629 PASS including 4 semantic view
models. Smoke answers sane: MIN leads franchise avg win pct (.640, best
.824 PHX-adjacent values check out), player views return real leaders,
apostrophe names (Flau'jae Johnson) render, proving the '' escaping.

**Decisions that matter downstream:**
- One rate scale everywhere: fact_wnba_team_game's 0-100 box percentages
  are NOT exposed; the same rates are sum-over-sum metrics instead. All
  stored rates presented as 0-1 fractions with a display rule (0.462 shown
  as 46.2%), matching sv_nfl_team_performance exactly (it never multiplies
  by 100 either).
- Turnover margin is not computable in a single-row aggregation (no
  opponent_turnovers column): direction rule tells the Analyst to group
  opponents' rows; steals flagged as not-the-same-thing.
- team_history uses the fact's season-accurate conference, not the dim's
  (NULL for the 2026 expansion clubs); team_performance warns a conference
  filter silently drops Fire and Tempo.
- season_type_name gets sample_values WITHOUT is_enum (only 'Regular
  Season' and 'All-Star' have landed; Postseason/Preseason legitimate).
- player_advanced avg_* metrics carry unweighted-mean warnings plus a
  minutes-floor rule; no championship data exists and the history view
  says so as its strongest rule.

**Changed from plan:** nothing structural.

**Open:** none new.
