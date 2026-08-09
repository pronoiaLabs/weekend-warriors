# weekend-warriors

**Ask questions about sports in plain English, and get answers from a real data warehouse.**

This is a complete, working, multi-sport data stack on Snowflake: it pulls league data from a public
API on a schedule, models each sport into its own star schema the moment data lands, and puts a
Cortex Agent on top of each so you can ask things like

> *"How has Detroit's third down and red zone efficiency changed season over season?"*

and get a correct answer with the SQL behind it. Two sports run today, NFL and WNBA, and the whole
design is built so the third is a scaffold command plus a registry file, not a refactor. Which
seasons you load is a registry setting, not a property of the stack.

It is also a worked example. Every layer is small enough to read in an afternoon, and the parts that
look strange are commented with why they are that way, usually because the obvious version was tried
first and broke.

---

## Contents

- [What is actually in here](#what-is-actually-in-here)
- [How the pieces fit](#how-the-pieces-fit)
- [Try it locally in five minutes](#try-it-locally-in-five-minutes)
- [Deploying to your own Snowflake account](#deploying-to-your-own-snowflake-account)
- [Adding your own data source](#adding-your-own-data-source)
- [Design decisions worth knowing](#design-decisions-worth-knowing)
- [Known gaps](#known-gaps)
- [Provenance and license](#provenance-and-license)

---

## What is actually in here

Two sports, each with its own database, star schema, semantic views and agent. The NFL raw layer:

| Table | Grain |
|---|---|
| `PLAYS` | one row per play |
| `STATS` | one row per player per game |
| `PLAYERS` | one row per player |
| `ADVANCED_*` | Next Gen tracking stats, split by discipline |
| `TEAM_STATS` | one row per team per game |
| `GAMES` | one row per game |
| `STANDINGS` | one row per team per season |
| `TEAMS` | one row per team |

How many seasons land in those tables is up to you: season-scoped pipelines load the current season
on their schedule, and a backfill parameter replays any year the API carries.

The WNBA side follows the same shape with its own registry, model tree and semantic views. Per sport,
roughly 20 dimensional models and 4 semantic views sit on top of raw, so each agent
(`nfl_analyst`, `wnba_analyst`) can answer team performance and player questions without anybody
writing SQL.

Everything runs **inside** Snowflake. There is no Airflow, no external scheduler, and no compute
outside the account. Ingestion is a container job on a Snowflake compute pool fired by a Snowflake
Task; dbt executes as a Snowflake object, not from a laptop or a CI runner; and production models
rebuild **event-driven**, minutes after a load lands, via a stream on the load ledger and a
triggered task per sport. Every dbt query is tagged with the build and model that ran it, and each
build's query profiles are harvested into observability tables that a local ops dashboard reads.

---

## How the pieces fit

```
          BallDontLie API  (api.balldontlie.io)
                   |
                   |   dlt, running in Snowpark Container Services
                   |   one Snowflake Task per pipeline, per sport
                   v
   <SPORT>_PROD_DB.RAW        loaded as-is, nothing thrown away
                   |
                   |   stream on the load ledger -> triggered task
                   |   dbt, via EXECUTE DBT PROJECT, minutes after data lands
                   v
   <SPORT>_PROD_DB.PREP       staging views   rename, cast, drop dlt bookkeeping
   <SPORT>_PROD_DB.CORE       dims + facts
   <SPORT>_PROD_DB.ANALYTICS  semantic views
                   |
                   v
          Cortex Agent  ("nfl_analyst", "wnba_analyst")
```

`<SPORT>` is `NFL` or `WNBA` today; the registry stores a stem, so a third league reuses every role,
pool and warehouse. Three directories:

| Path | What it does |
|---|---|
| [dlt-pipelines/](dlt-pipelines/) | Gets the data in. Registry-driven [dlt](https://dlthub.com), deployed to SPCS, plus the observability SQL. |
| [dbt-pipelines/](dbt-pipelines/) | Makes it useful. dbt models, semantic views, Cortex Agents, one environment per sport per tier. |
| [ops-dashboard/](ops-dashboard/) | Watches it. A local FastAPI + React dashboard over the pipeline and dbt observability views. |
| [.github/workflows/](.github/workflows/) | CI, and a deploy that only ships what changed. |

The BallDontLie API is documented at [docs.balldontlie.io](https://docs.balldontlie.io). Its OpenAPI
specs are not vendored here; they belong to the provider.

**Where to read next**, depending on what you came for:

- *I want to understand the ingestion side* -> [dlt-pipelines/README.md](dlt-pipelines/README.md), then
  [pipelines/batch/registries/nfl-registry.yml](dlt-pipelines/pipelines/batch/registries/nfl-registry.yml),
  which is the single source of truth for every pipeline.
- *I want to run something right now* -> [dlt-pipelines/MAKE-COMMANDS.md](dlt-pipelines/MAKE-COMMANDS.md).
- *I want to understand the modelling* -> [dbt-pipelines/README.md](dbt-pipelines/README.md), then
  [models/nfl/](dbt-pipelines/models/nfl/).
- *I want to know how an agent is built* -> [agents/nfl_analyst.sql](dbt-pipelines/agents/nfl_analyst.sql).
  It is heavily commented and is the most transferable file in the repo.
- *I want to watch it run* -> [ops-dashboard/README.md](ops-dashboard/README.md) for the local
  dashboard, or the observability SQL in [dlt-pipelines/sql/ops/](dlt-pipelines/sql/ops/).

---

## Try it locally in five minutes

You do **not** need Snowflake to see this work. A local run loads into DuckDB.

**You need:** Python 3.11+, [uv](https://docs.astral.sh/uv/), and a free API key from
[balldontlie.io](https://www.balldontlie.io).

```bash
git clone https://github.com/pronoiaLabs/weekend-warriors.git
cd weekend-warriors/dlt-pipelines

make setup                        # installs deps, writes a .dlt/secrets.toml template
```

Put your API key where `make setup` tells you, then:

```bash
make list                         # every pipeline declared in the registry
make run NAME=nfl_reference       # teams + players -> local DuckDB, ~30 seconds
```

That is the whole loop. `nfl_reference` is the cheapest pipeline; `nfl_plays` is the expensive one at
roughly 334 requests.

---

## Deploying to your own Snowflake account

Longer, and deliberately not one command. The account DDL creates roles, compute pools and grants, so
it is a sequence of **reviewed SQL files you run yourself**, not something a script does behind your
back.

```bash
make setup-base   CONFIRM=1       # roles, control plane, registry table
make setup-dev    CONFIRM=1       # dev database, compute
make setup-prod   CONFIRM=1       # prod database, compute, service users
make setup-source SOURCE=nfl CONFIRM=1   # NFL_DEV_DB + NFL_PROD_DB, secret, egress
make image-push                   # build the container, push to Snowflake
make deploy                       # sync the registry, create the Tasks
```

Then resume the Tasks, which is a separate and deliberate act. Full walkthrough with verification
queries at each step: [MAKE-COMMANDS-PROD.md](dlt-pipelines/MAKE-COMMANDS-PROD.md).

**Watch out for one thing.** `CREATE OR ALTER TASK` resets a Task to suspended. Re-running
`make tasks-apply` over a live schedule silently stops it: the DDL succeeds, nothing errors, and the
next scheduled run simply never happens. `generate_tasks.py --resume` emits the matching resume
statements, and CI applies them automatically. By hand, you have to remember.

### CI/CD

`.github/workflows/deploy.yml` deploys only what a change affects. Edit a registry YAML and it
resyncs the registry and reapplies Tasks without rebuilding a container; edit Python and it rebuilds
the image; edit a dbt model and it rebuilds models and leaves ingestion alone.

Auth is keyless, via GitHub OIDC to a Snowflake `TYPE = SERVICE` user. No credentials are stored. If
your account has an IP allowlist, read
[sql/prod/03b_service_user_oidc.sql](dlt-pipelines/sql/prod/03b_service_user_oidc.sql) before you
start: OIDC removes the stored credential but not the network path, and the fix is not obvious.

---

## Adding your own data source

The point of the registry design is that this is a YAML entry, not a new script.

```bash
make new-source NAME=nba HOST=https://api.balldontlie.io
```

That scaffolds a registry file, the database DDL, the external access integration, the secret, and
the event-driven dbt trigger, with the names already wired together. Fill in the endpoints and you
have a pipeline the runner, the Task generator and the observability layer all already know about;
add a dbt model tree for the sport and its builds trigger themselves.

---

## Design decisions worth knowing

**A Snowflake Task cannot pass arguments,** and that shapes more of this than you would expect. Two
BallDontLie endpoints return HTTP 400 without a `season` parameter, and two more silently return
*every* season. So season-scoped resources declare `season: "{current_season}"` and the runner
substitutes the year at run time, rolling over on 1 August. A literal year would keep reporting
success while quietly loading a finished season.

**One database per sport, crossed with environment.** A shared control plane (`DLT_DB`) plus
`NFL_DEV_DB` and `NFL_PROD_DB`. The registry stores a database *stem* (`NFL`), not a full name, so one
entry covers both environments. Adding a league does not touch roles, pools or warehouses.

**Both halves nest by sport,** `models/nfl/` on one side and `registries/nfl-registry.yml` plus
`sql/sources/nfl/` on the other. That is what makes a second league a copy rather than a refactor.

**dbt config keys mirror folder names.** `models/nfl/prep/` needs `nfl:` then `prep:` in
`dbt_project.yml`. Flattening them does not error; the models just quietly build as views in the
wrong schema.

**One environment per sport per tier, gated hard.** Every dbt environment sets `DBT_SPORT`, and each
sport's models, sources and tests enable only on their own value, so a run can only ever build its
own sport into its own database. A forgotten `--select` cannot cross-pollinate leagues.

**Prod dbt is event-driven, and observable per query.** A stream on each sport's load ledger fires a
triggered task that drains it and runs `EXECUTE DBT PROJECT`; failed loads never insert, so they
never trigger. Every query the build runs carries a JSON `QUERY_TAG` with the sport, build id and
model, and a harvest task persists each build's query log and query profiles
(`GET_QUERY_OPERATOR_STATS`) into observability tables, giving per-model performance history with no
`ACCOUNT_USAGE` latency. The details, including the several Snowflake sharp edges this tripped over,
are commented in [dlt-pipelines/sql/ops/](dlt-pipelines/sql/ops/) and the per-sport
`05_dbt_trigger.sql` files.

**Three models ship disabled on purpose.** `sv_nfl_player_advanced` is off because the Next Gen source
tracks each player in exactly one discipline: the passing, rushing and receiving endpoints have zero
player overlap. The view would promise cross-discipline comparisons the data cannot answer. Rushing
production is still available from the box score in `sv_nfl_player_offense`.

---

## Known gaps

Stated plainly, because a repo that hides these is harder to trust.

- **`stats?seasons[]=<year>` does not return every game.** Replaying the 2023 regular season returned
  47 of 49 games, and both missing games had data when fetched by `game_id`. Fetching per game the way
  plays are fetched would close it. The reconciliation tests in
  [dbt-pipelines/tests/](dbt-pipelines/tests/) exist to keep the gap visible rather than let it
  propagate silently.
- **No alerting on Task failure.** Failures are visible in the ops dashboard and the observability
  views, but only if someone looks; nothing pushes a notification yet.
- **Two games have no `TEAM_STATS` row, 18 games have no `PLAYS` rows**, and 386 `STATS` rows show
  activity in no phase and therefore land in no phase fact. These are source gaps, encoded as tests.

---

## Provenance and license

Built on two templates by [innovation-igloo](https://github.com/innovation-igloo), each imported at
the commit below and then adapted. Both keep their original Apache 2.0 `LICENSE`.

| Directory | Upstream | Imported at |
|---|---|---|
| `dlt-pipelines/` | [dlt-snowflake-template](https://github.com/innovation-igloo/dlt-snowflake-template) | `3cc4194` |
| `dbt-pipelines/` | [cortex-agents-dbt-project-template](https://github.com/innovation-igloo/cortex-agents-dbt-project-template) | `ae5d195` |

Upstream history is not preserved here. Both templates are public if you want to see what changed.
The CDC subsystem and documentation site that ship with the dlt template were removed rather than
adapted; this project is batch only.

Licensed under Apache 2.0. See [LICENSE](LICENSE).
