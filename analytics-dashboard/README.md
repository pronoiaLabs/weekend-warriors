# analytics-dashboard

A sport analytics dashboard for the NFL and NCAAF data in this account: a thin FastAPI API
over a dbt-built serving layer, rendered by a React app. It is a sibling of
`ops-dashboard/`, copies its patterns (query cache, fixture mode, SPA mount, typed client)
and shares no code with it.

Status: Phase 0 of the development plan (canvas `semantic-view-dashboards`, page 4). This
directory holds the role, the catalog fixtures and the findings. The dbt `APP` layer arrives
in Phase 1, the API and web app in Phase 2.

## Two lanes

**Pages read `APP` tables.** Every curated page (game day board, game prop board, teams,
markets, players, news) is served from `<SPORT>_PROD_DB.APP`, a dbt layer of page-shaped
marts beside `CORE`, `ANALYTICS` and `FEATURES`. Definitions live in dbt, tested and
versioned, rebuilt by the triggered prod build when data lands; the API is one `select` per
tile with bound filters and no SQL logic. Marts carry sport-agnostic column names, so the
differences between NFL and NCAAF are absorbed in dbt and the API's sport profile is a
table map plus a capability list.

**The Explorer reads semantic views.** `SELECT ... FROM SEMANTIC_VIEW(...)` is the right
tool for a metadata-driven sheet where the user picks dimensions and metrics; the catalog
fixtures in this directory are its allowlist and its contract. It is the wrong tool for
curated pages, for the reasons under "Semantic SQL is stricter than the agent" below.

No materialized views sit on top of the marts: Snowflake MVs are single-table,
Enterprise-only and refreshed by a billed background service, and the `app_*` tables are
already the materialization. If one page ever needs sub-load freshness, that one model
becomes a dynamic table.

## Layout

```
analytics-dashboard/
├── deploy/sql/
│   ├── 01_role.sql          ANALYTICS_DASHBOARD_ROLE: semantic-view SELECT, warehouse USAGE
│   ├── 02_cost_tag.sql      cost attribution note (no dedicated compute in v1)
│   └── 03_app_grants.sql    SELECT on all and future tables in each APP schema; run after
│                            the first prod build creates APP, idempotent after that
└── api/fixtures/catalog/    one JSON per semantic view: dimensions, metrics, facts as returned
                             by SHOW SEMANTIC DIMENSIONS | METRICS | FACTS IN <view>.
                             The Explorer's allowlist.
```

## Role

`ANALYTICS_DASHBOARD_ROLE` holds USAGE on the two databases, `SELECT` on all and future
tables in each `APP` schema (pages), `SELECT` on all and future semantic views in each
`ANALYTICS` schema (Explorer), and USAGE on `DLT_OPS_WH`. Nothing on CORE, PREP or RAW.
Apply `01_role.sql` and `02_cost_tag.sql` now, `03_app_grants.sql` after Phase 1
(`snow sql -c weekend-warriors -f deploy/sql/<file>`; a `make setup CONFIRM=1` target
lands with the Makefile in Phase 2). Marts are built with `+copy_grants` so dbt's
`CREATE OR REPLACE` keeps the grant between runs of the grant file.

One trap when verifying: an interactive session carries the user's secondary roles, so a
`--role ANALYTICS_DASHBOARD_ROLE` session can still read CORE through SYSADMIN. Prove the
boundary with `USE SECONDARY ROLES NONE` first, and the API sets the same on every
connection (`api/app/db.py`, Phase 2) so it only ever holds the primary role. Verify:

```bash
snow sql -c weekend-warriors --role ANALYTICS_DASHBOARD_ROLE --warehouse DLT_OPS_WH --format JSON \
  -q "use secondary roles none; select count(*) from NFL_PROD_DB.CORE.FACT_PLAYER_GAME_OFFENSE"
# expected: Schema 'NFL_PROD_DB.CORE' does not exist or not authorized.

snow sql -c weekend-warriors --role ANALYTICS_DASHBOARD_ROLE --warehouse DLT_OPS_WH --format JSON \
  -q "use secondary roles none; select * from semantic_view(NFL_PROD_DB.ANALYTICS.SV_NFL_PLAYER_OFFENSE dimensions players.player_name metrics player_games.total_fanduel_points where weeks.season = 2025 and weeks.season_type = 'Regular Season') order by total_fanduel_points desc limit 3"
```

## Semantic SQL is stricter than the agent

Cortex Analyst generates physical SQL against the base tables; `SEMANTIC_VIEW()` is
resolved by Snowflake from the view's own graph, and it enforces rules the agent never
hits. Each of these cost a failed query in Phase 0, and together they are why pages do not
use this lane:

- **Names are the declared names.** `players.player_name`, not `players.full_name`;
  `weeks.season_type`, not `season_type_name`. The catalog fixtures are the source of
  truth, never the dbt column names. The same role is spelled differently across views
  (`players.player_name` on offense, `players.full_name` on props and news).
- **A FACTS query is single-entity.** Every fact and dimension in the clause, and in
  WHERE, must come from one logical table. Facts on a table with no dimensions of its own
  (the weather table on the schedule view, the line values on the odds view) cannot be
  selected with the identity of the row they belong to.
- **Multi-path relationships are refused.** If a dimension entity is reachable from the
  metric's entity by two relationship paths, any query touching it fails with
  "Multi-path relationship ... is not supported". The odds and props views have this
  shape (closing and opening both reference games, teams and players), so neither is
  queryable through semantic SQL today.
- **Cross-view tiles are CTEs.** A `SEMANTIC_VIEW()` relation can be a CTE and joined to
  another; the join keys are the declared dimension names, which must match across views.

What works through this lane, verified against the live account: player offense and
defense (dimensions + metrics, including week trends), team performance (including the
`opponents` dimension), the schedule as dimensions only (no weather), news, and all four
NCAAF views. What does not: odds lines per game, props lines per player, kickoff weather
per game, any opponent split on the player views. dbt issues #44 to #46 describe the view
changes that would fix the first three; they are Explorer-only improvements now and not on
the critical path. #47 (an `opponents` dimension on the player views) is still worth doing
for the agent; the `APP` marts derive the opponent from `dim_game` and do not wait on it.

## Querying notes

- Regular season is `weeks.season_type = 'Regular Season'` on the NFL views and
  `is_postseason = false` on NCAAF, where season and week live on the fact entity
  (`team_games.season`, `player_games.week`).
- `ORDER BY` and `LIMIT` go outside the parentheses; there is no GROUP BY, the listed
  dimensions are the grouping.
- The current season on the schedule views is 2026; completed-season analytics use 2025.
