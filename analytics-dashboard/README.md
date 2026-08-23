# analytics-dashboard

A sport analytics dashboard for the NFL and NCAAF data in this account: a thin FastAPI API
over a dbt-built serving layer, rendered by a React app in the Glass Prism look. It is a
sibling of `ops-dashboard/`, copies its patterns (query cache, fixture mode, SPA mount,
typed client) and shares no code with it. Own ports, so both run side by side.

Status: Phase 3 of the development plan (canvas `semantic-view-dashboards`, page 4): the
scaffold and Prism shell, the sport profiles and capabilities endpoint, and the first two
pages, the game day board and the game prop board, over the `app_game_slate` and
`app_game_prop_board` marts. The Explorer (Phase 4) and the team, market and player pages
follow.

## Running it

```bash
make install            # uv sync for the api, npm install for the web
make dev                # both services: API on :8010 + Vite on :5174; open localhost:5174
make dev-fixtures       # the same on recorded fixtures, no Snowflake connection
make dev-api            # FastAPI on :8010, live data as ANALYTICS_DASHBOARD_ROLE
make dev-api-fixtures   # the same on recorded fixtures, no Snowflake connection
make dev-web            # Vite on :5174, proxies /api to :8010
make serve              # build the web app and serve everything on :8010
make test               # api tests in fixture mode (live tests skipped)
make test-live          # includes the live contract tests (needs the role)
make lint               # ruff + tsc -b
make smoke              # build, then walk every route in headless Chrome on fixtures
make nav                # build, then drive the app over DevTools: back, memory, dock
make fixtures           # recapture fixtures/app/nfl from your dev build (see Fixtures)
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

## Pages and the tiles behind them

Every page is one React module rendered at every width (the dock on wide screens, bottom
tabs under 900px) and gated by `CapabilityGate` on the capability its mart provides. Every
tile that reads a mart shows the SQL it ran in a "Show query" expander; the API renders the
bound statement with literals in place of the binds for exactly that purpose.

| Route | API | Mart | What the API does beyond the select |
|---|---|---|---|
| `/:sport/slate` | `GET /api/{sport}/slate?season&season_type&week&vendor` | `app_game_slate` | lists the season's weeks (picker + default resolution: the first week whose last kickoff is still ahead, else the last week); collapses the week's game × vendor rows to one card per game carrying the requested book's line, blank when that book has none |
| `/:sport/games/:game_key` | `GET /api/{sport}/games/{game_key}?vendor` | `app_game_slate`, `app_game_prop_board` | the game's row at the chosen book, plus the prop board for every book split into the away and home columns; the page filters by book and stat family without another round trip |
| `/:sport/teams` | `GET /api/{sport}/teams?season&season_type&split` | `app_team_standings` | one select of the season (every season type and split), filtered to the chosen season type and split; the season type defaults to the one in progress (latest last game); the page groups by division or shows the league |
| `/:sport/teams/:team` | `GET /api/{sport}/teams/{team}?season&season_type&vendor` | `app_team_standings`, `app_team_weeks`, `app_team_allowed`, `app_team_ats` | four selects on the team's label: the splits, the weeks collapsed to one row per game carrying the chosen book's line from the team's side, the defense-allowed rows by position and stat, and the against-the-spread row per book; `team` is the label (KC), case-insensitive |

Each tile lives in `api/app/sports/tiles/<name>.py` as a pydantic row model, the
`COLUMNS` it selects (the contract test checks them against the mart schema), and a `load`
function that issues one select through `app/sports/source.py` (live SQL or the same
selection over fixture rows). Pins on the game page are per-browser `localStorage`; the
matchup notes are sentences generated on the client from the columns already on the page
(extreme opponent ranks by position, the forecast, line movement, news headlines).

### Navigation and state

The URL is the source of truth for the page that is open: every choice on a page (season
type, week, book, outdoor, stat family) is a search param, so any view is shareable and a
reload lands on the same view. Three things sit around that rule so moving between pages
feels continuous:

- **A remembered view per sport** (`web/src/state/view.tsx`): the last slate choice is kept
  in `sessionStorage`, the dock's "Game day" link and a game page's breadcrumb return to
  that week and book rather than the defaults, and a bare `/nfl/slate` adopts it once. A new
  tab starts clean. Pins use `localStorage` instead, because a board you built should
  outlive the tab.
- **Back that behaves** (`hooks/useBack.ts`): "Back to board" on a game page uses browser
  history when you came from inside the app and falls back to the remembered board when the
  page was the entry point. Chip clicks update the URL with `replace`, so browser Back leaves
  the page instead of stepping through every filter you touched.
- **Scroll memory** (`hooks/useScrollMemory.ts`): window scroll is restored on Back and
  Forward and reset on a new page; the board's own scroll position is remembered per URL, so
  returning from a game lands on the same kickoff slot.

`make nav` asserts all of this by driving the built app in headless Chrome over the DevTools
protocol (`scripts/navcheck.mjs`); `make smoke` only renders routes.

Two facts about the data the pages show, both from the marts rather than the app:

- Weather columns are null until the forecast run inside the game week; the card says
  "Forecast arrives inside the week" rather than rendering zeros.
- `team_label` on a prop row is the player's team as of the game: this season's most recent
  box score, else the roster feed's current team (so offseason movers sit with the team
  that priced them). The page still keys each row to its column's team and would mark a
  row `ex-<team>` if the two ever disagreed, a guard that the fixtures show never firing.

## Fixtures

`api/fixtures/app/nfl/*.json` are rows captured from a dev build by
`api/scripts/capture_fixtures.py` through `app.db.query`, so they have exactly the shape
live tiles see. The selection is small and deliberate (2026 Regular Season weeks 1 and 2,
2026 Preseason week 3 which is partly played, 2025 Regular Season week 18 which is complete
with scores; every 2026 prop row; 2025 and 2026 standings for every split; KC and DET's
weeks and defense-allowed rows for both seasons), enough to exercise every branch a page
has. The same script writes `fixtures/app/schema/<table>.json` from `DESCRIBE TABLE`, the
column contract the tiles are tested against. No 2025 game carries a closing line (the odds
feed begins with the 2026 regular season), so the team weeks' vendor collapse is covered by
a unit test on synthetic rows and `app_team_ats` is captured empty. The tests pin the clock
to `2026-08-23T02:00:00Z` (`tests/conftest.py`) so the default week is stable. Recapture
after a mart change with `make fixtures DEV_SCHEMA=DEV_<user>` (reads `NFL_DEV_DB` as
`SYSADMIN` on `DEVELOPMENT_WH`) and commit the result.

## Layout

```
analytics-dashboard/
├── Makefile
├── scripts/smoke.sh           headless-Chrome route walk on fixtures (make smoke)
├── scripts/nav.sh + navcheck.mjs   DevTools-driven navigation contract (make nav)
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
│   │       ├── source.py         select(): one SELECT of named columns, live or over fixtures
│   │       ├── tiles/            slate.py, game_board.py: row model + COLUMNS + load()
│   │       ├── router.py         /api/{sport}, includes the page routers as they land
│   │       └── routers/          capabilities.py, slate.py, games.py
│   ├── scripts/capture_fixtures.py
│   ├── fixtures/
│   │   ├── app/schema/        DESCRIBE TABLE of each mart: the profile contract
│   │   ├── app/<sport>/       recorded rows per mart
│   │   └── catalog/           SHOW SEMANTIC ... per view, for the Explorer
│   └── tests/                 fixture mode by default; `live` marker needs ANALYTICS_DASHBOARD_LIVE=1
└── web/                       Vite + React 19 + react-router 7
    └── src/
        ├── api/               client.ts (get<T>), sports/client.ts + types.ts
        ├── hooks/             api state, sport from the path, viewport, pins (localStorage), tilt
        ├── layouts/           SportLayout: loads capabilities once, provides them, renders the chrome
        ├── components/        Aurora, sports/ (SportNav, TileFrame, Chips, CapabilityGate, Crumbs)
        ├── lib/format.ts      number, odds and spread formatting; null renders blank
        ├── pages/sports/      SportHome, Slate, Game; one module per page at every width
        └── styles/            tokens.css (palette), sports.css (primitives), pages.css (pages)
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
