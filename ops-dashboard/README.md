# ops-dashboard

Observability for the ingestion fleet and the dbt builds: a React front end and a
FastAPI back end over the `DLT_DB.OPS` layer. Live, the API reads the
`obs_to_postgres` copy in Snowflake Postgres `app.observability` as `app_api`.
Snowflake warehouse SQL remains `OPS_DASHBOARD_BACKEND=snowflake` for fixture
capture, the SPCS service, and rollback. It shares its shell, tokens and
patterns with the analytics dashboard (`../analytics-dashboard`), copied rather
than imported so either app can move alone.

**This runs locally, by design.** Postgres live needs `APP_API_PASSWORD` in
repo-root `.env.postgres`. Queries are cached for 60 seconds per statement.

## Running it

```bash
make install        # api deps (uv) + web deps (npm), one time
make dev            # API on :8000 (live Postgres) and the Vite dev server on :5173, together
make dev-fixtures   # the same on recorded fixtures: no database connection at all
make serve          # build the web app, serve api + web on http://localhost:8000
```

`make dev` is two processes in one terminal (Ctrl-C stops both); `make dev-api` and
`make dev-web` are the halves. Ports are :8000 and :5173, so this and the analytics
dashboard (:8010 / :5174) run side by side. Rollback:
`OPS_DASHBOARD_BACKEND=snowflake make dev-api`.

| Variable | Default | Meaning |
|---|---|---|
| `OPS_DASHBOARD_DATA` | `live` | `fixtures` serves the recorded JSON and never opens a connection |
| `OPS_DASHBOARD_BACKEND` | `postgres` | live store: `postgres` (`app.observability` as `app_api`) or `snowflake` |
| `OPS_DASHBOARD_NOW` | wall clock | ISO-8601 pin; the fixture snapshot is frozen, so windows are measured from here |
| `OPS_DASHBOARD_CONNECTION` | `weekend-warriors` | snow CLI connection on a laptop (`BACKEND=snowflake` only) |
| `OPS_DASHBOARD_ROLE` | unset | `USE ROLE` after connecting (`BACKEND=snowflake` only). The SPCS spec sets `OPS_DASHBOARD_ROLE` |
| `OPS_DASHBOARD_WAREHOUSE` | unset | `USE WAREHOUSE` after connecting (`BACKEND=snowflake` only) |
| `OPS_DASHBOARD_CACHE_SECONDS` | `60` | per-statement cache TTL |
| `OPS_DASHBOARD_STATIC` | `web/dist` | the built front end to serve |
| `PGHOST`, `PGPORT`, `APP_API_PASSWORD` | from repo-root `.env.postgres` | Postgres live login. User is always `app_api` |

On Snowflake, every statement carries a JSON `QUERY_TAG`
(`{"app":"ops-dashboard","tile":"slate"}`). Postgres live does not.

## Pages and the statements behind them

Every page renders inside one shell (the dock on wide screens, bottom tabs under 900px)
with the sport filter as a visible switch in the topbar: `?sport=` survives navigation
so views stay deep-linkable, and an invisible sticky filter is a trap. Every payload
carries the SQL the request built, rendered with literals, and each page shows it in a
"Show query" expander. The theme toggle in the topbar switches the two palettes in
`tokens.css` (the OS preference until a choice is made, then `localStorage`).

Three conventions the colours and the clock follow:

- **One colour per run state.** Sage is a run that succeeded, rose a run that broke,
  amber a no-show (the slot passed and nothing fired, which is a task or schedule
  question rather than a failure), rose hatched a run that happened but never recorded
  itself, grey dotted a slot still ahead. The dashboard carries a legend; the day strip
  and the KPIs count failures and no-shows separately.
- **A pipeline's slots begin when the pipeline did.** A cron expanded over a day says
  nothing about whether the Task existed to fire it, so the API floors each pipeline
  at the earlier of its registry row's `updated_at` (the deploy that registered it;
  stamped with `SYSDATE()`, UTC, because the account's session zone is Pacific) and
  its first run ever (`MIN(RUN_STARTED_AT)` over the whole run table). Slots before
  the floor are not slots: the morning before a new Task existed is not a row of
  no-shows, an old pipeline floors at a run weeks ago and is unaffected, and a new
  Task whose first fire never came still shows it.
- **Every card and row names its source.** The registry's `source` (the vendor: `rest_api`
  is BallDontLie, then `nflverse`, `sleeper`, `firecrawl`, `openmeteo`) rides on each
  pipeline row and each slot or run card, and the Source chips on the dashboard and the
  pipelines page slice by it, persisted as `?source=` beside `view` and `kind`. A dbt
  build belongs to no single source (it fired because data landed), so picking one hides
  builds; the chip row only appears once the day spans more than one source.
- **The slate's day is the viewer's day.** The page sends the browser's IANA zone
  (`tz=`), and the API cuts the day at local midnight, so the first card of "Sunday" is
  not Saturday evening. Crons stay UTC (they are the Task definitions); only the day's
  edges move. Without `tz` the day is UTC, which is what the tests use.
- **The clock is the payload's.** "Refreshed" in the topbar is the API's clock, never the
  browser's, so a stale tab does not age itself.

| Route | API | Reads | What the API does beyond the select |
|---|---|---|---|
| `/` | `GET /api/slate?sport&date`, `/api/headlines?date`, `/api/pipelines?sport` | `PIPELINE_REGISTRY`, `PIPELINE_RUNS`, `V_DBT_RUNS`, `HEADLINES` | expands each cron over the day, matches runs to slots, emits one score card per slot (final, failed, no-show, upcoming) plus the dbt builds that fired; tallies the seven days around the one in view; the wire serves the newest day at or before the request |
| `/pipelines` | `GET /api/pipelines?sport` | `PIPELINE_REGISTRY`, `PIPELINE_RUNS` | the standings: last-14 W-L, pct and streak per pipeline, the form strip, the worst-state-per-day cells, next fire from the cron |
| `/ingestion/:sport/:name` | `GET /api/pipelines/{sport}/{name}?limit` | `PIPELINE_RUNS` | the heat strip (worst state per day), the run history with each run's anomalies and provenance |
| `/runs/:query_id` | `GET /api/runs/{id}`, `/logs?severity&limit`, `/metrics`, `/rowcounts` | `PIPELINE_RUNS`, `V_LOG_LINES`, `V_METRICS` | the run's two verdicts side by side, prior runs of the same slot, logs paged by severity, CPU and memory strips shaped from the samples, row counts against the previous run |
| `/builds` | `GET /api/dbt/builds?sport&limit` | `V_DBT_RUNS` | newest first; the page rolls up per sport and marks a sport paused after 14 quiet days |
| `/dbt/builds/:build_id` | `GET /api/dbt/builds/{id}`, `/queries?limit`, `/api/dbt/queries/{qid}/operators` | `V_DBT_RUNS` / `dbt_runs`, `DBT_QUERY_LOG`, `DBT_QUERY_OPERATOR_STATS` | the queries slowest first, the operator tree fetched when a row is expanded. The loads tile (`<SPORT>_PROD_DB.OPS.DBT_TRIGGER_LOADS`) is Snowflake-only: that table is per-sport and is not in the observability copy, so Postgres live returns an empty list |

The shaping lives in `api/app/assemble.py` (slots, cards, records, heatmaps),
`derive.py` (anomalies, the worst verdict, error provenance) and `schedule.py` (cron
expansion); the routers in `api/app/routers/` only validate, call and attach the trace.
`datasource.py` is the seam: every function builds its statement once, then either runs
it or applies the same predicate to the recorded rows, so fixture and live can never
drift. Its column lists are explicit rather than `SELECT *`: they are the contract.

## Fixtures

`api/app/fixtures/*.json` are a frozen snapshot of the fleet from early August 2026; the
tests and `make dev-fixtures` pin the clock to `2026-08-09T18:00:00Z` so every "last N
days" window lands inside it. `api/app/fixtures/schema/*.json` are `DESCRIBE` of every
object the datasource reads, recorded by `make schema` and checked by the contract test
in both forms: the fixture form in CI, the live form (`make test-live`) against the real
objects, which is the early warning for a view change.

`make fixtures CONFIRM=1` re-snapshots the rows through `app.db.query`, so they have
exactly the shape live tiles see. It is gated because the endpoint tests assert dates,
counts and query ids from the current snapshot: a new snapshot means re-pinning
`FIXTURE_NOW` in the Makefile, `SNAPSHOT_NOW` in `tests/conftest.py` and the values in
`tests/test_*.py` in the same change.

## Quality

```bash
make test       # api pytest, fixture mode, no network (live tests skipped)
make test-live  # plus the contract test against app.observability
make lint       # ruff + tsc
make build      # production bundle into web/dist
make smoke      # every route in headless Chrome against fixtures, ~30 seconds
```

The smoke walk starts the API on :8027 serving `web/dist` in fixture mode, renders each
route with a 2s virtual-time budget (one retry before a route counts as broken), and
fails on a missing expected text or a console error; it refuses to run if something
already listens on its port, since it would otherwise test stale code.

## Layout

```
ops-dashboard/
  api/
    app/
      config.py        the env contract
      db.py            one cached connection, role and warehouse pins, query tag, TTL cache, render()
      datasource.py    the seam: one statement per function, live or fixtures, column contracts
      assemble.py      slots, cards, records, heatmaps
      derive.py        anomalies, worst verdict, error provenance
      schedule.py      cron expansion
      registry.py      sports and pipelines from PIPELINE_REGISTRY
      routers/         health, sports, slate (+ headlines), pipelines, runs, dbt
      fixtures/        the snapshot; schema/ the DESCRIBE contracts
    scripts/capture_fixtures.py
    tests/
  web/src/
    layouts/OpsLayout.tsx      shell, topbar, sport switch, freshness pill, dock
    components/                TileFrame, Chips, Crumbs, OpsNav, the investigation visuals
    components/slate/          day strip, league rows, score cards, headlines, records
    hooks/                     useApi, useBack, useViewport, useScrollMemory, useTilt, URL params
    pages/                     Dashboard, PipelinesRecords, PipelineDetail, RunDetail, Builds, DbtBuildDetail
    styles/                    tokens.css, ops.css (primitives), components.css, pages.css, pages/*.css
  scripts/smoke.sh
  deploy/                      the parked SPCS path
```

## Role

Postgres live always connects as `app_api`. Snowflake rollback
(`OPS_DASHBOARD_BACKEND=snowflake`) uses the connection's default role unless
`OPS_DASHBOARD_ROLE` is set. `deploy/sql/01_ops_role.sql` creates
`OPS_DASHBOARD_ROLE` with SELECT on exactly the objects the datasource reads and
USAGE on `DLT_WH`; to prove those grants before relying on them:

```bash
OPS_DASHBOARD_BACKEND=snowflake OPS_DASHBOARD_ROLE=OPS_DASHBOARD_ROLE \
  OPS_DASHBOARD_WAREHOUSE=DLT_WH make test-live
```

The session runs `USE SECONDARY ROLES NONE` after `USE ROLE`, so a grant the role lacks
fails here rather than passing on a laptop (where secondary roles would paper over it)
and failing in the container.

## SPCS deployment: parked, not deleted

`deploy/` holds a complete but UNAPPLIED path to run this as an SPCS service
(Dockerfile, spec template, role/pool/service SQL, `make setup` / `image-push` /
`deploy` targets). It is parked because an always-on XS pool costs real money 24/7
and local serves the same pages for warehouse-seconds. If that trade ever flips,
start at `deploy/sql/01_ops_role.sql`, whose header explains the service-owner-role
trap that shaped the design. The spec sets `OPS_DASHBOARD_ROLE`, so the container
never relies on a default role. The spec pins `OPS_DASHBOARD_BACKEND: snowflake`
until the service has Postgres secrets; a laptop `make dev` defaults to Postgres.
