# analytics-dashboard

A sport analytics dashboard for the NFL and NCAAF data in this account: a thin FastAPI API
over a dbt-built serving layer, rendered by a React app in the Glass Prism look. It is a
sibling of `ops-dashboard/`, copies its patterns (query cache, fixture mode, SPA mount,
typed client) and shares no code with it. Own ports, so both run side by side.

Status: Phase 2 of the development plan (canvas `semantic-view-dashboards`, page 4): the
scaffold, the Prism shell, the sport profiles and the capabilities endpoint. Pages arrive
from Phase 3.

## Running it

```bash
make install            # uv sync for the api, npm install for the web
make dev-api            # FastAPI on :8010, live data as ANALYTICS_DASHBOARD_ROLE
make dev-api-fixtures   # the same on recorded fixtures, no Snowflake connection
make dev-web            # Vite on :5174, proxies /api to :8010
make serve              # build the web app and serve everything on :8010
make test               # api tests in fixture mode (live tests skipped)
make test-live          # includes the live contract tests (needs the role)
make lint               # ruff + tsc -b
```

Environment, all optional (`api/app/config.py` is the contract):

| Variable | Default | Meaning |
|---|---|---|
| `ANALYTICS_DASHBOARD_DATA` | live | `fixtures` serves recorded JSON and never imports the connector |
| `ANALYTICS_DASHBOARD_NOW` | wall clock | pins the clock (ISO-8601) for fixture-era tests |
| `ANALYTICS_DASHBOARD_CONNECTION` | weekend-warriors | snow CLI connection name |
| `ANALYTICS_DASHBOARD_ROLE` | ANALYTICS_DASHBOARD_ROLE | applied with `USE ROLE` on connect, then `USE SECONDARY ROLES NONE` |
| `ANALYTICS_DASHBOARD_WAREHOUSE` | DLT_OPS_WH | `USE WAREHOUSE` on connect |
| `ANALYTICS_DASHBOARD_CACHE_SECONDS` | 60 | default query cache TTL; tiles can override per call |
| `<SPORT>_APP_DB`, `<SPORT>_APP_SCHEMA` | `<SPORT>_PROD_DB`, `APP` | where a sport's marts live; point NFL at `NFL_DEV_DB` / `DEV_<user>` to read a dev build |

## Two lanes

**Pages read `APP` tables.** Every curated page (game day board, game prop board, teams,
markets, players, news) is served from `<SPORT>_PROD_DB.APP`, a dbt layer of page-shaped
marts beside `CORE`, `ANALYTICS` and `FEATURES`. Definitions live in dbt, tested and
versioned, rebuilt by the triggered prod build when data lands; the API is one `select` per
tile with bound filters and no SQL logic. Marts carry sport-agnostic column names, so the
differences between NFL and NCAAF are absorbed in dbt and the API's sport profile is a
table map plus a capability list (`api/app/sports/profiles/`).

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
├── Makefile
├── deploy/sql/
│   ├── 01_role.sql            ANALYTICS_DASHBOARD_ROLE: semantic-view SELECT, warehouse USAGE
│   ├── 02_cost_tag.sql        cost attribution note (no dedicated compute in v1)
│   └── 03_app_grants.sql      SELECT on all and future tables in each APP schema; run after
│                              the first prod build creates APP, idempotent after that
├── api/
│   ├── app/
│   │   ├── main.py            create_app(): /api/health, the sports router, the SPA mount last
│   │   ├── config.py          the ANALYTICS_DASHBOARD_* contract
│   │   ├── db.py              query(sql, params, ttl=, tag=): one role, no secondary roles,
│   │   │                      JSON query tag, per-call cache TTL
│   │   └── sports/
│   │       ├── capabilities.py   Capability enum, one per mart family
│   │       ├── profile.py        SportProfile: table map + capabilities, no SQL, no columns
│   │       ├── profiles/         nfl.py, ncaaf.py
│   │       ├── registry.py       get_profile / require(cap) dependencies (404 by name)
│   │       ├── fixtures.py       recorded rows and DESCRIBE TABLE schemas
│   │       ├── router.py         /api/{sport}, includes the page routers as they land
│   │       └── routers/          capabilities.py (more per phase)
│   ├── fixtures/
│   │   ├── app/schema/        DESCRIBE TABLE of each mart: the profile contract
│   │   ├── app/<sport>/       recorded rows per mart (from Phase 3)
│   │   └── catalog/           SHOW SEMANTIC ... per view, for the Explorer
│   └── tests/                 fixture mode by default; `live` marker needs ANALYTICS_DASHBOARD_LIVE=1
└── web/                       Vite + React 19 + react-router 7
    └── src/
        ├── api/               client.ts (get<T>), sports/client.ts + types.ts
        ├── hooks/             api state, sport from the path, viewport (wide | narrow)
        ├── layouts/           SportLayout: loads capabilities once, provides them, renders the chrome
        ├── components/        Aurora, sports/SportNav (dock wide, tabs narrow)
        ├── pages/sports/      SportHome; one module per page at every width
        └── styles/            tokens.css (Prism palette), sports.css (primitives)
```

## Role

`ANALYTICS_DASHBOARD_ROLE` holds USAGE on the two databases, `SELECT` on all and future
tables in each `APP` schema (pages), `SELECT` on all and future semantic views in each
`ANALYTICS` schema (Explorer), and USAGE on `DLT_OPS_WH`. Nothing on CORE, PREP or RAW.
`make setup CONFIRM=1` applies the three files in order; `03_app_grants.sql` fails until
the first prod dbt build has created `APP` and is idempotent after that. Marts are built
with `+copy_grants` so dbt's `CREATE OR REPLACE` keeps the grant between runs.

One trap when verifying: an interactive session carries the user's secondary roles, so a
`--role ANALYTICS_DASHBOARD_ROLE` session can still read CORE through SYSADMIN. Prove the
boundary with `USE SECONDARY ROLES NONE` first; `db.py` runs the same statement on every
connection so the app only ever holds the primary role. Verify:

```bash
snow sql -c weekend-warriors --role ANALYTICS_DASHBOARD_ROLE --warehouse DLT_OPS_WH --format JSON \
  -q "use secondary roles none; select count(*) from NFL_PROD_DB.CORE.FACT_PLAYER_GAME_OFFENSE"
# expected: Schema 'NFL_PROD_DB.CORE' does not exist or not authorized.

snow sql -c weekend-warriors --role ANALYTICS_DASHBOARD_ROLE --warehouse DLT_OPS_WH --format JSON \
  -q "use secondary roles none; select count(*) from NFL_PROD_DB.APP.APP_GAME_SLATE"
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
