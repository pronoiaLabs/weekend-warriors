# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An NFL analytics stack on Snowflake, assembled from two upstream templates and adapted. Data source is the [BallDontLie](https://api.balldontlie.io) NFL API, documented at [docs.balldontlie.io](https://docs.balldontlie.io); `BALL_DONT_LIE_API_KEY` is in `.env`.

Note `/.docs/` at the repo root is gitignored: it holds the provider's OpenAPI specs and local working notes, which are not ours to redistribute. `dlt-pipelines/.docs/` is a different directory and **is** tracked, holding vendored dlt reference material that `dlt-pipelines/README.md` links to.

The shape is: dlt loads `NFL_PROD_DB.RAW` from SPCS on a Snowflake Task schedule, dbt builds `PREP` / `CORE` / `ANALYTICS` on top of it via `EXECUTE DBT PROJECT`, and a Cortex Agent sits on the semantic views. Nothing runs outside the Snowflake account.

## Repository layout: one repo

A monorepo. [dlt-pipelines/](dlt-pipelines/) and [dbt-pipelines/](dbt-pipelines/) are plain directories with no `.git` of their own; they were clones of the two innovation-igloo templates and were absorbed at commits `3cc4194` and `ae5d195` respectively (recorded in [README.md](README.md)). Upstream history is not preserved and `git pull upstream` is not available. Both keep their original Apache 2.0 `LICENSE`.

Two things that follow from this and are easy to get wrong:

- **GitHub Actions only reads `.github/workflows/` at the repository root.** Any workflow file inside `dlt-pipelines/` or `dbt-pipelines/` is inert. Both subprojects' workflows were merged into the root [.github/workflows/](.github/workflows/), which distinguishes them by path filter.
- `.env` holds a live Snowflake PAT and API key. The root `.gitignore` covers it, along with `.snowflake/` (Cortex Code session plans), `logs.txt` and the closed-out `*-PLAN.md` session records.

## Snowflake connection

The default `snow` CLI connection is named `weekend-warriors`, running as `SYSADMIN` on warehouse `DEVELOPMENT_WH` with PAT auth. No database or schema is set on it. Account identifier, username and token live in `~/.snowflake/connections.toml` and are deliberately not recorded here: this file is public.

Two environment specifics:

- **`~/.snowflake/connections.toml` is the authoritative file.** When it exists it fully overrides the `[connections]` section of `config.toml`. `config.toml` only supplies `default_connection_name`. Edits to `config.toml`'s connection blocks alone have no effect.
- The CLI (v3.23.0, Homebrew, `/opt/homebrew/bin/snow`) takes `-c` **on the subcommand**, not before it: `snow sql -c weekend-warriors -q "..."`, not `snow -c weekend-warriors sql ...`. An older 3.14 app-bundle install still exists at `~/Applications/SnowflakeCLI.app`, but `PATH` puts Homebrew first.
- **`--environment` is an alias for `--connection`**, so a misplaced env flag is read as a connection name rather than rejected.

### dbt env.yml flags are behind a feature flag

The `snow dbt` env.yml options (`--env`, `--env-vars`, `--use-shell-env-vars`, `--default-env`, `--unset-default-env`, `--env-file-dir`) exist in 3.23 but are **hidden from `--help` unless `ENABLE_DBT_PROJECT_ENV_VARS` is on** (`hidden=not FeatureFlag...is_enabled()` in the dbt plugin). It is enabled persistently in `~/.snowflake/config.toml`:

```toml
[cli.features]
enable_dbt_project_env_vars = true
```

Per-command equivalent: `SNOWFLAKE_CLI_FEATURES_ENABLE_DBT_PROJECT_ENV_VARS=true`. If the flags ever appear "missing" again, check this before concluding the CLI dropped support. A related flag, `enable_dbt_project_profiles_file_precedence`, is left off.

**Account access is gated by an account-level network policy** allowing a small set of IPs. Any connection from outside it fails with `Network policy is required`, regardless of authentication method, so anything running off-laptop has to be accounted for. SPCS is unaffected because the container never connects inbound from the internet. CI is handled by a user-scoped override, described under CI/CD below. Run `SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT` to see the current binding rather than trusting a name written down here.

## dlt-pipelines — ingestion

Registry-driven dlt → Snowflake. **[pipelines/batch/registries/](dlt-pipelines/pipelines/batch/registries/) is the single source of truth**, one YAML per source merged into one registry: the runner, the SPCS task generator, and the observability layer all read it. Adding a pipeline means appending an entry there, not writing a new script. Credentials are never inlined — a `secret:<path>` prefix resolves through `dlt.secrets` into `.dlt/secrets.toml` or a bound Snowflake SECRET.

Dependencies are managed with `uv`; every Python target runs through `uv run`, so `make install` is the only setup step (there is no `.venv` yet).

```bash
cd dlt-pipelines
make setup                        # doctor + uv install + bootstrap .dlt/secrets.toml
make list                         # pipelines declared in registry.yml
make run-local NAME=nfl_games     # local run → DuckDB (no Snowflake creds needed)
make run-snowflake NAME=nfl_games # → Snowflake via your snow connection, into NFL_DEV_DB.DEV_<user>
make test                         # full suite
make test-config                  # config unit tests only (no dlt, no network)
make lint / make fmt              # ruff (line-length 100)
make help                         # all targets, each self-documented
```

Run a single test the usual pytest way: `uv run --extra dev pytest tests/test_registry_config.py::<test_name>`.

`make run-snowflake` and `make snow-env` map an existing `snow` CLI connection's auth into dlt env vars for one run, so `connections.toml` stays the only place credentials live.

**Batch only.** `pipelines/batch/` holds scheduled, run-to-completion loads, deployed as one Snowflake Task per pipeline and generated by `deploy/tasks/generate_tasks.py` from the registry. The template's second subsystem, `pipelines/cdc/` (continuous Snowpipe Streaming CDC running as a long-lived SPCS service), was removed along with `sql/cdc/` and its Make targets rather than adapted. If you see a reference to a `cdc-*` target anywhere, it is stale.

Deployment is a 7-phase flow (`sql/base` → `sql/dev` → `sql/prod`, then image push, then task generation) documented in [dlt-pipelines/README.md](dlt-pipelines/README.md). The `setup-*` targets are guarded by `CONFIRM=1`.

**The account model is one database per sport, crossed with environment.** A shared control plane (`DLT_DB`: registry table, spec stage, image repo, secrets) plus per-sport storage: `<SPORT>_DEV_DB` (per-developer `DEV_<user>` schemas) and `<SPORT>_PROD_DB` (`RAW` and `RAW_STAGING` for dlt, `PREP` / `CORE` / `ANALYTICS` for dbt). Three sports today: NFL, WNBA, and NCAAF, each with the full stack (ingestion, dbt tree, triggered prod builds, agent). Adding a sport means `make new-source` and authoring the registry entry; roles, compute pools and warehouses are all shared, and observability needs nothing per sport (runs flow into `DLT_DB.OPS.PIPELINE_RUNS` registry-driven). `DLT_DEV_DB` / `DLT_PROD_DB` remain only for the sport-less `sample` smoke test.

The registry stores a **stem** (`database: NFL`), not a full name. `models.resolve_database()` composes `<stem>_<env>_DB`, so one entry covers both environments and no caller has to name a database by hand. `make setup-source SOURCE=nfl CONFIRM=1` creates a source's databases, and `make new-source NAME= HOST=` scaffolds one via `tools/new_source.py`.

**nflverse lands beside BallDontLie, vendor-prefixed.** `pipelines/batch/nflverse_source.py` (source type `nflverse`, registry `nflverse-registry.yml`) reads nflverse's per-season parquet releases through the `nflreadpy` package into `NFL_PROD_DB.RAW.NFLVERSE_*` (play by play, 150-column player weeks, snap counts, three Next Gen tables, official injury reports, depth charts, plus the all-history players id crosswalk, officials, combine and trades). Depth charts are two tables because the file changed shape with the 2025 season: `NFLVERSE_DEPTH_CHARTS_WEEKLY` (the league's weekly chart through 2024, merged on a row hash since the file has no clean key) and `NFLVERSE_DEPTH_CHARTS` (daily snapshots from 2025, cursor on `dt`); the source refuses a season outside each shape's window by name. Tables carry the vendor because BDL already owns `PLAYERS`, `PLAYER_INJURIES` and `STATS` in that schema; `GSIS_ID` is the join key across everything nflverse (players, stats, injuries, depth charts, Next Gen). To BDL there is no shared id: name + team matches 2,271 of 2,907 current nflverse players (78%, measured 2026-08-23), the rest need jersey/college tie-breakers. To Sleeper, ids are sparse (`ESPN_ID` on 769 and `GSIS_ID` on 577 of 3,183 rostered active players), so name + team (79%) is the workhorse there too and the ids confirm the subset they cover. Two facts that bite: nflreadpy keeps its own season clock (game data rolls the Thursday after Labor Day, depth charts on 15 March) and rejects a year past it, so the entries say `seasons: current` and never the registry's `{current_season}` token; and `--param` only reaches rest_api endpoint params, so a backfill is an unscheduled entry with an explicit season list (`nfl_nflverse_backfill`, 2023 onward, the BDL floor) run with `make run-prod`. The source drops the files' few NULL-key placeholder rows and logs the count. No secret; egress via `NFLVERSE_EAI` (`sql/sources/nflverse/`).

**Sleeper is the live twin** (`pipelines/batch/sleeper_source.py`, source type `sleeper`, registry `sleeper-registry.yml`, tables `RAW.SLEEPER_*`): the daily player dump (12k rows incl. 32 `DEF` team rows, with `GSIS_ID`, `ESPN_ID`, `KALSHI_ID`, injury status, practice participation, depth-chart order, `SEARCH_RANK`), the 24h trending adds/drops, and weekly projections and stats with fantasy points. Every run starts with `/v1/state/nfl` and reads season, week and season_type from it, so no season token; a backfill pins `seasons` x `season_types` in config. Projections and trending are **appended as dated snapshots** (`FETCHED_AT` plus the run's `STATE_*` columns; their movement is the point), stats merge on player x week, players is replaced once a day because Sleeper's docs ask for at most one pull a day. The weekly stats and projections live on `api.sleeper.com` (unofficial, the app's own host), the rest on the documented `api.sleeper.app/v1`; both are in `SLEEPER_API_EAI` (`sql/sources/sleeper/`). Nothing models either vendor yet; see `BACKLOG.md`.

### Scheduling: what a Task cannot pass

A Snowflake Task passes **no arguments**, and that constraint shapes several things that otherwise look arbitrary:

- **Season.** `/standings` and `/advanced_stats` return HTTP 400 without a `season`; `/games` and `/stats` silently return *every* season. So season-scoped resources declare `season: "{current_season}"` in the registry and `run.py` substitutes the year at run time (`models.current_season()`, rolling over on 1 August). A backfill's `--param` still overrides it.
- **Credentials and egress.** A scheduled pipeline must declare `secret`, `env_var` and `external_access` in its registry entry. `PipelineSpec.validate()` rejects a `schedule` without them, because the alternative is a container failing at 09:00 UTC. `make run-spcs` reads the same fields, so dev and prod share one record of the binding.
- **Clause order.** `EXECUTE JOB SERVICE` requires `EXTERNAL_ACCESS_INTEGRATIONS` *before* `FROM`. Putting it after the template file is a SQL compilation error.

Cadence and the 2026 NFL calendar behind it are in [dlt-pipelines/MAKE-COMMANDS-PROD.md](dlt-pipelines/MAKE-COMMANDS-PROD.md). Three runbooks now: `MAKE-COMMANDS.md` (laptop), `-SPCS.md` (container by hand), `-PROD.md` (scheduled).

## dbt-pipelines — modeling and Cortex Agents

A dbt project whose lifecycle runs **inside Snowflake** via `EXECUTE DBT PROJECT` / `snow dbt execute`, not via local dbt Core.

The environment mechanism is the thing to understand first. `profiles.yml` hardcodes nothing — it reads `DBT_DATABASE` / `DBT_SCHEMA` / `DBT_WAREHOUSE` / `DBT_ROLE` through `env_var()` with **no defaults**, and Snowflake injects those by resolving [env.yml](dbt-pipelines/env.yml) at execution time. A run outside that path fails fast rather than silently targeting the wrong database. In `dev`, `DBT_SCHEMA` resolves to `CURRENT_USER()`, giving each developer an isolated schema.

**One project, one environment per sport per tier.** env.yml defines `dev` / `prod` (NFL, grandfathered names), `wnba_dev` / `wnba_prod`, and `ncaaf_dev` / `ncaaf_prod`, each also setting `DBT_SPORT`. Every sport tree in `dbt_project.yml` (and every source) gates `+enabled` on it, so a run can only build its own sport into its own database; a forgotten `--select` cannot cross-pollinate. Adding a sport means: two env.yml entries (including `DBT_QUERY_TAG_BASE`, a required key), FOUR gated blocks in `dbt_project.yml` (models, tests, seeds, sources), a `<sport>_raw` source block, a `macros/<sport>/` helpers file, the model tree, a `tests/<sport>/` directory, an `agents/<sport>_analyst.sql` macro, a `deploy-all` line, and the CoWork `ADD AGENT` line in `sql/01_cowork.sql`.

The single deployed project object is **`DLT_DB.DEPLOY.CORTEX_LIFECYCLE`** (sport-neutral, in the control-plane schema). An older `NFL_PROD_DB.ANALYTICS.NFL_ANALYTICS` object may still exist pending cleanup; deploy.yml's `DBT_PROJECT_FQN` var still points at it.

```bash
# --env must come BEFORE the project name; tokens after it go to dbt Core, which has no --env
snow dbt deploy DLT_DB.DEPLOY.CORTEX_LIFECYCLE --source . --default-env dev \
  --external-access-integration dbt_ext_access --force
snow dbt execute --env wnba_dev DLT_DB.DEPLOY.CORTEX_LIFECYCLE build
snow dbt execute --env wnba_prod DLT_DB.DEPLOY.CORTEX_LIFECYCLE run-operation deploy_wnba_analyst
```

Requires Snowflake CLI **>= 3.21** for the `--env` / `--default-env` flags — satisfied (3.23.0), with the `ENABLE_DBT_PROJECT_ENV_VARS` feature flag enabled as described above. `dbt deps` needs an External Access Integration reaching `hub.getdbt.com` and `codeload.github.com`.

**Model layers** are set per directory in `dbt_project.yml` under `models: cortex_agent_lifecycle: nfl:` and `wnba:`. `prep/` builds views into `PREP`, `core/dimensions/` and `core/facts/` build tables into `CORE`, `semantic_views/` and `evaluations/` build into `ANALYTICS`, `features/` builds ML marts into `FEATURES`, and `app/` builds page-shaped marts for the analytics dashboard into `APP` (`+copy_grants` so `ANALYTICS_DASHBOARD_ROLE` keeps SELECT across rebuilds). `FEATURES` and `APP` are not Cortex tools: no semantic view sits on them. An `app_*` mart is long format with its parameters (season, week, season_type, vendor) as columns, so the dashboard's API filters rather than dbt precomputing per choice; see `analytics-dashboard/README.md` for why pages read `APP` rather than the semantic views. The NFL set, by page: game day (`app_game_slate`, `app_game_prop_board`), teams (`app_team_standings` with home/away splits, `app_team_weeks` team × game × vendor, `app_team_ats`, `app_team_allowed`, the single definition of what a defense allows by position and stat, which the prop board also reads), players (`app_player_weeks`, its long twin `app_player_week_stats` carrying the player's own prior-season same-week and average columns, `app_player_leaders` with ranks within position, `app_player_defense_weeks`), news (`app_news_mentions` with the team's next game), line movement (`app_line_history`, `app_prop_line_history` over the two pregame snapshot facts `fact_game_betting_odds_snapshot` and `fact_player_prop_snapshot`, which collapse consecutive identical observations so a row means the line moved), and the Explorer's sheets (`app_explore_*`: flat, one table per grain, curated column lists with a `row_id`, built as tables from the page marts so the sheet's columns are their own contract). The folder is grouped by page (`app/game_day/`, `teams/`, `players/`, `news/`, `markets/`, `explore/`), each with its own models yml. Game × vendor marts keep one vendor-NULL row when no line exists, so every game appears at least once and the API picks the chosen book's row or blanks the line.

**dbt model names are project-global**, so only one sport gets the generic names: NFL owns `dim_team` / `fact_team_game_offense` style names (first mover); WNBA and NCAAF core models are sport-qualified (`dim_wnba_team`, `fact_ncaaf_team_game`), matching the `sv_<sport>_*` semantic-view convention. Prep is prefixed per sport everywhere (`stg_nfl__*`, `stg_wnba__*`, `stg_ncaaf__*`).

**Fact tables hold completed games only; the slate lives on the game dimension.** Scheduled games have no fact rows by construction (`fact_team_game_offense` and `fact_wnba_team_game` filter on completedness), `dim_game` / `dim_wnba_game` carry `is_completed`, and each sport's `sv_<sport>_schedule` -- the agents' only future-games tool -- anchors on that dimension with role-playing home/away team joins and deliberately exposes no scores.

**The NFL team-game box score is split by side.** `fact_team_game_offense` is the team's own box score plus the game result (every stat on it is offensive; `sacks_allowed` is sacks its QB took), and `fact_team_game_defense` is its 1:1 twin on `team_game_key`: the opponent's box score re-read as `opp_*` "allowed" columns via a self-join, plus `fact_player_game_defense` rolled up to the team (tackles, TFL, `sacks_recorded`, QB hits, passes defended). Two traps encoded there: `takeaways` is the opponent's `turnovers`, never a sum of `fumbles_recovered` (which counts own-fumble recoveries, 841 mismatches), and the provider's team-box `defensive_touchdowns` disagrees with the player rollup on 155 rows, so both are exposed under explicit names. Rates are not materialized on either fact; compute them as sum over sum.

**The config keys must mirror the folder nesting.** They are directory names, so `models/nfl/prep/` needs `nfl:` then `prep:`. Flattening them does not error: the models still build, just as views in the default target schema with the `+schema` silently dropped.

**`DBT_COLLAPSE_SCHEMAS` decides whether that fan-out happens.** `env.yml` sets it `true` in dev, where `macros/generate_schema_name.sql` then ignores every `+schema` so a developer gets one schema (`DEV_JSMITH`) rather than three. Prod sets it `false` and the layers separate.

**Three models ship disabled**, and this is deliberate rather than unfinished. `sv_example` and `eval_dataset` are template skeletons pointing at the placeholder source that `models/sources.yml` replaced, kept for their authoring guidance. `sv_nfl_player_advanced` is off because the Next Gen source tracks each player in exactly one discipline: the passing, rushing and receiving endpoints have zero player overlap, so the view would promise cross-discipline comparisons the data cannot answer. Its underlying facts still build.

**Agents are macros, not models.** `macro-paths` includes `agents/`, and each agent is a `deploy_<name>` wrapper macro holding its spec inline — dbt Projects on Snowflake cannot read a file at runtime. Because the spec is raw text dbt does not render, fully-qualified names use `<<DATABASE>>`, `<<SCHEMA>>`, `<<WAREHOUSE>>` tokens that `create_agent` / `alter_agent` substitute with the active target. Deploy with `dbt run-operation deploy_<name>` (add `--args '{alter: true}'` for a zero-downtime update). Through `snow dbt execute` the args value must carry EMBEDDED quotes -- `--args "'{alter: true}'"` -- because the CLI reassembles the dbt command line without re-quoting and the space inside the YAML splits the token server-side (`String '{alter:' is not valid YAML`).

Raw sources in `models/sources.yml` are deliberately **not** environment-driven: every developer reads the same `<SPORT>_PROD_DB.RAW` tables. dbt must never write to `RAW` or `RAW_STAGING`, which dlt owns.

### Event-driven dbt builds (prod)

**Prod models rebuild automatically when data lands, not on code pushes.** Per sport, five objects in `<SPORT>_PROD_DB.OPS`, owned by `DBT_RUNNER_ROLE` and applied by `sql/sources/<sport>/05_dbt_trigger.sql`: an APPEND_ONLY stream on `RAW._DLT_LOADS` (dlt inserts there only on successful load, so failures never trigger), an audit table `DBT_TRIGGER_LOADS`, a caller's-rights proc `SP_DBT_BUILD()`, a triggered task `DBT_BUILD_<SPORT>` (no schedule, `WHEN SYSTEM$STREAM_HAS_DATA`, warehouse `DBT_WH`, 900s trigger interval that coalesces bursts), and a harvest child task `DBT_HARVEST_<SPORT>` (`AFTER` the build task, so it runs only on build success). All three sports run `ARGS='build'` (models + tests; NFL flipped from `'run'` once its test suite went green). The proc **drains the stream via DML first** — an unconsumed stream keeps the task re-firing every 30s forever — then mints a `build_id` (UUID) and runs `EXECUTE DBT PROJECT` with an explicit `ENVIRONMENT` (the objects default to dev; omitting it silently builds the wrong target) via `EXECUTE IMMEDIATE`, because the `ENV_VARS` clause rejects Scripting binds at CREATE PROCEDURE time. On success it records the build in `DLT_DB.OPS.DBT_BUILDS` and stamps `SYSTEM$SET_RETURN_VALUE` (a proc's RETURN string never reaches `TASK_HISTORY.RETURN_VALUE`; only that function does, and `V_DBT_RUNS` parses the build_id out of it).

Three prod facts that follow:

- **Deploying a sport's project object IS the prod release step.** The triggers run whatever `DLT_DB.DEPLOY.CORTEX_LIFECYCLE_<SPORT>` holds; `make -C dbt-pipelines deploy-sport SPORT=<sport>` after merging model changes ships them. The sport-neutral `CORTEX_LIFECYCLE` object serves interactive/dev only. One object per sport because concurrent `EXECUTE DBT PROJECT` against a single object is unsupported. **`snow dbt deploy --force` is a CREATE OR REPLACE and drops the object's grants**, so `deploy-sport` re-grants USAGE to `DBT_RUNNER_ROLE` after every deploy — a bare `snow dbt deploy` outside the Make target silently breaks the triggered builds until the task auto-suspends (measured: two days, Aug 2026).
- **Kill switch:** `ALTER TASK <SPORT>_PROD_DB.OPS.DBT_BUILD_<SPORT> SUSPEND;` — ingestion untouched, the stream accumulates and drains on resume (staleness grace ~14 days; recreate the stream after longer suspensions or if dlt ever recreates `_DLT_LOADS`).
- **These tasks are invisible to `V_TASK_RUNS` by design** (its `DLT_TASK_%` filter): read `DLT_DB.OPS.V_DBT_RUNS` instead — since 2026-08 a thin view over the materialized `DBT_RUNS` table, refreshed event-driven by `DBT_RUNS_REFRESH` (streams on `DBT_BUILDS` + `DBT_QUERY_LOG`; `DBT_RUNS_SWEEP` every 4h covers FAILED builds, which write no stream event). Note `INFORMATION_SCHEMA.TASK_HISTORY()` is ACCOUNT-WIDE — the database qualifier only resolves the function, a fact that cost one mislabeled bootstrap. They are also not managed by `generate_tasks.py` or the tasks-suspend/apply/resume flow; each 05 file handles its own suspend-before-alter, and altering the graph requires suspending BOTH tasks (children resume before the root).

`DBT_RUNNER_ROLE` (created in `sql/base/04_dbt_runner.sql`) owns the PREP/CORE/ANALYTICS schemas and contents (ownership transferred with grants preserved, because dbt's `CREATE OR REPLACE` requires owning the existing object). env.yml's prod environments name it as `DBT_ROLE` on warehouse `DBT_WH`; a task cannot run unless its owner role also has USAGE on the task's schema, and the privilege that lets a role invoke a dbt project object is USAGE on that object.

[WORKING-SESSION.md](dbt-pipelines/WORKING-SESSION.md) is a phase-driven runbook meant to be executed by an agent ("Follow WORKING-SESSION.md"); it gates on user input between phases. The README's "Writing effective semantic views" and "Writing effective agents" sections encode real constraints — notably that semantic-view DDL clause order is enforced (`TABLES → RELATIONSHIPS → FACTS → DIMENSIONS → METRICS → COMMENT → AI_*`, with `AI_VERIFIED_QUERIES` last), and that SQL-generation rules belong in the semantic view's `AI_SQL_GENERATION` clause rather than in agent instructions.

## CI/CD

Root [.github/workflows/](.github/workflows/). `ci.yml` never touches Snowflake, so it runs on every push and pull request including from forks: lint, tests, registry validation, and a render of the Task DDL to catch an unsubstituted spec placeholder before it can reach a Task. `deploy.yml` always touches Snowflake, so it runs only on `main` and `workflow_dispatch`, gated on the `deploy` GitHub environment.

`deploy.yml` computes path filters once and gates each job on them, so a change deploys only what it affects: image rebuild, registry resync, Task reapply, dev spec upload, per-sport dbt object deploy, agent redeploy, ops-dashboard image + service roll. `sql/**` is in **no** filter. Those files create roles, pools and grants as `SYSADMIN` / `USERADMIN` / `ACCOUNTADMIN` and stay a deliberate `make setup-*` run by a human.

CLI install + OIDC auth + a `snow connection test -x` preflight live in one composite action, [.github/actions/snowflake-setup](.github/actions/snowflake-setup/action.yml), SHA-pinned to the GA `snowflake-cli` leaf of `snowflakedb/snowflake-actions` (it holds `id-token: write`; their README says pin). Every authenticating job must keep `environment: deploy` — the OIDC subject claim is environment-scoped. The dbt and agents jobs are per-sport matrices calling `make -C dbt-pipelines deploy-sport` / `deploy-agent` with `CONN_ARGS=-x`, so the deploy + re-grant + ownership sequence has one home; they run as `DBT_RUNNER_ROLE` on `DBT_WH` (job-level env overrides) and DEPLOY ONLY — the triggered tasks build when data lands. Post-deploy assertions: `SHOW GRANTS ON DBT PROJECT` must show `DBT_RUNNER_ROLE`, and after the Task resume every generator-emitted task must be `started` (the expected set comes from `generate_tasks --resume` output, so a paused sport is simply absent).

**`CREATE OR ALTER TASK` refuses to touch a started Task, and leaves it suspended once it can.** Both halves matter and they bite at different moments.

Applying `tasks.sql` to a running fleet fails with `091421 (22000): Unable to update graph with root task <name> since that root task is not suspended`, and changes nothing. Because `snow sql -f` stops at the first error, a fleet whose first Task is running aborts before the rest are attempted: some Tasks carry the new spec, some the old, and nothing in the output says which. Then, once the DDL does apply, every Task is left suspended, so the schedule is stopped until something resumes it.

So a Task reapply is always three steps, `make deploy` chains them, and `deploy.yml` mirrors it: `make tasks-suspend` → `make tasks-apply` → `make tasks-resume`. `generate_tasks.py` emits each with `--suspend` and `--resume`. Suspend uses `ALTER TASK IF EXISTS` so a first or partial deploy is safe; resume deliberately does not, because a missing Task there means the apply failed partway and the error is the only signal. Verify with `SHOW TASKS`, not with the target's exit code: suspended looks exactly like success.

### Why CI can reach Snowflake at all

The account-level network policy allows only a short IP list, and GitHub-hosted runners are nowhere near it. Workload identity federation does not change that: OIDC removes the stored credential, not the network path, and there is no exemption for `TYPE = SERVICE` users.

What makes it work is that **network policies override rather than stack**. A policy attached to a user replaces the account policy for that user alone, so `DLT_DEPLOYER` carries its own and the control shifts to the OIDC subject claim, which binds the token to this repository and the `deploy` environment, plus `DLT_LOADER_ROLE`'s limited grants. Every other user keeps the account policy. See `dlt-pipelines/sql/prod/03b_service_user_oidc.sql`, which explains the trade-off and the tighter self-hosted-runner alternative.

## Known gaps

- (closed 2026-08-09) ~~Nothing chains dbt behind the ingestion Tasks~~ — prod dbt builds are now event-driven; see "Event-driven dbt builds" under dbt-pipelines.
- **`stats?seasons[]=<year>` is incomplete.** A 2023 replay returned 47 of 49 games; both missing games have data when fetched by `game_id`. Fetching per game the way `plays` does would close it. The dbt reconciliation tests exist to keep this visible.
- (closed 2026-08-15) ~~No alerting on Task failure~~ — in-process Slack alerting now pings failure transitions; see "Alerting" under Telemetry. Two accepted residual gaps, by design: a container that never starts and a schedule that is dead without failing produce no alert (no code runs in either); a future sweep could close them.
- **`_DLT_RUNS` under-reports failures, systematically.** `record_run` is called from inside `run_pipeline`, so a spec rejected by `validate()` dies several frames earlier and is never recorded. Measured over one week: 22 Task failures, 17 `_DLT_RUNS` rows. The gap correlates with severity, since the worse the failure the earlier it happens, so anything built on `_DLT_RUNS` alone reads rosier than reality. Use `TASK_HISTORY` as the spine and join `_DLT_RUNS` on.

## Telemetry

SPCS job containers write logs and platform metrics to **`DLT_DB.OPS.DLT_EVENTS`**, a dedicated event table created by `make setup-ops CONFIRM=1` from [sql/ops/](dlt-pipelines/sql/ops/). It exists rather than using the shared `SNOWFLAKE.TELEMETRY.EVENTS` because change tracking cannot be set on objects in the `SNOWFLAKE` database, and the observability layer hangs streams off it.

**The observability layer is materialized, event-driven** (2026-08). Two APPEND_ONLY streams on `DLT_EVENTS` fire the triggered task `DLT_DB.OPS.OBS_REFRESH` (min 60s between fires), whose proc `SP_OBS_REFRESH` drains them through the regex parse into `LOG_LINES` / `METRIC_SAMPLES`, MERGEs task history into `TASK_RUNS` (live `TASK_HISTORY()` every fire; ACCOUNT_USAGE only at bootstrap or after a >6-day gap, self-healing), then loops sports from `PIPELINE_REGISTRY` and MERGEs into **one `DLT_DB.OPS.PIPELINE_RUNS` table** (`SPORT` = uppercase registry stem). The dashboard API reads that table directly; the per-sport `V_PIPELINE_RUNS` views are gone, and `V_LOG_LINES` / `V_METRICS` / `V_TASK_RUNS` are thin passthroughs. **A new sport needs zero observability objects.** A run appears in the table with its logs while still EXECUTING (~1 min after container start); `OBS_REFRESH_SWEEP` (every 4h) bounds the two zero-event cases (container never started; final verdict after the last event flush). Retention decoupled in ops/05: raw 30d, parsed 90d, run tables 365d. Full rebuild: suspend `OBS_REFRESH`, `CALL SP_OBS_REFRESH(TRUE)` (recreates streams with `SHOW_INITIAL_ROWS`), resume; required if the streams ever go stale (>14d suspension). Baseline before materializing: 4.6-6.0s per uncached dashboard query; now ~110ms.

Hard-won facts about the plumbing, each costing a failed verification:

- **SPCS reads the ACCOUNT-level `EVENT_TABLE` parameter and ignores a database-level one**, contrary to the general event-table documentation but consistent with the SPCS monitoring page. A database binding reads back as `level=DATABASE` while doing nothing.
- **A compute pool node resolves its event table when the node starts.** Changing the parameter does not affect a pool with live nodes; `ALTER COMPUTE POOL ... SUSPEND` and let it auto-resume. Recreating the service is not sufficient.
- **A task session runs the owner's PRIMARY role alone**, so interactive testing (which carries secondary roles) cannot prove a task-context privilege; `DLT_LOADER_ROLE` needed an explicit `GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE`.
- **`EXECUTE TASK` does not bypass a triggered task's WHEN clause** (manual fires land SKIPPED on empty streams), which is why the sweep calls the proc directly behind an in-flight check.

### Alerting

**Failure alerting is in-process, not a sweep** (2026-08): the run that fails is the thing that pings Slack, chosen because the auto-suspend cascade is preceded by ~10 individual failures, so a failure-level ping surfaces a problem at failure #1. Two senders, one policy: `pipelines/common/alerts.py` (hooked into `run.py` around every pipeline outcome AND around registry resolution, the early-death class `_DLT_RUNS` never records) and an outer `EXCEPTION` handler in each sport's `SP_DBT_BUILD` (pings, then `RAISE`s so `TASK_HISTORY` and auto-suspend counting are untouched). Both call `SYSTEM$SEND_SNOWFLAKE_NOTIFICATION` over their existing Snowflake session through the account-level `SLACK_ALERTS_INT` webhook integration ([sql/ops/09_alerting.sql](dlt-pipelines/sql/ops/09_alerting.sql)) — no container has Slack egress or the webhook secret. **Noise policy is transitions + recovery** via the `DLT_DB.OPS.ALERT_STATE` latch: healthy→failing pings once, the first success after pings RECOVERED, everything between is silent. The Python side is gated on `DLT_ALERTS=1`, set ONLY in the prod job template, so dev containers and laptops cannot page the channel. Alerting is best-effort everywhere: every failure of the alert path itself is swallowed (logged in Python, nested swallow-all in SQL) so it can never mask the error it reports. Two traps encoded in ops/09: `CREATE NOTIFICATION INTEGRATION` validates the URL **with the secret substituted**, so the secret placeholder must be Slack-shaped (`T…/B…/x…`) or the create fails; and delivery is async — `Enqueued notifications` proves nothing, check `NOTIFICATION_HISTORY()` (14-day lookback). Kill switch: `ALTER NOTIFICATION INTEGRATION SLACK_ALERTS_INT SET ENABLED = FALSE` (senders keep working silently, best-effort catches the error).

### dbt observability

Every dbt query carries a JSON `QUERY_TAG` (`{"app":"dbt","sport":...,"env":...,"build_id":...,"node":...}`): the base rides in from env.yml's `DBT_QUERY_TAG_BASE` through profiles.yml `query_tag` (a REQUIRED key for any new environment; no default, fail-fast), and `dbt-pipelines/macros/query_tags.sql` overrides `snowflake__set_query_tag` to add the per-node fields. The build_id passes through `EXECUTE DBT PROJECT ... ENV_VARS`. Two tag spellings exist (the literal base has no spaces, tojson output does): always `TRY_PARSE_JSON` the tag, never string-match it.

After each prod build, `DBT_HARVEST_<SPORT>` calls `DLT_DB.OPS.SP_DBT_HARVEST()` ([sql/ops/06_dbt_harvest.sql](dlt-pipelines/sql/ops/06_dbt_harvest.sql)): it MERGEs new tagged queries from `INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE` into `DBT_QUERY_LOG`, then captures `GET_QUERY_OPERATOR_STATS` per query into `DBT_QUERY_OPERATOR_STATS`, 8-wide via Scripting ASYNC child jobs, 200 per run heaviest-first, claim-first deduped, restricted to plan-bearing statement types (an `EXECUTION_TIME > 0` filter admits USE/ALTER SESSION noise; measured). Four hard-won facts encoded there: the QUERY_HISTORY table functions are blocked in owner's-rights procs only (caller's rights works, even from a task); `GET_QUERY_OPERATOR_STATS` accepts only a literal or a `:bind` argument (no lateral joins, no cursor fields) and runs 0.5s to 50s+ per call; unawaited ASYNC children are cancelled when the proc returns; `AWAIT` is fail-fast so each chunk needs its own exception handler. Retention: weekly task in the same file (90d query log and operator stats, 365d build and trigger audit rows). Cost attribution: `DLT_DB.OPS.COST_CENTER` object tag on the warehouses, SPCS pools, `DLT_EVENTS`, and every scheduled task ([sql/ops/08_cost_tags.sql](dlt-pipelines/sql/ops/08_cost_tags.sql)); the ingestion-task tags are emitted by `generate_tasks.py` into tasks.sql, not listed in 08; sport-level dbt cost comes from the query tags, not object tags. The ops dashboard reads `V_DBT_RUNS` and these tables on its `/dbt` page.

All three job spec templates declare `platformMonitor` with all five metric groups. Metrics are sampled roughly every 30 seconds against runs of 53 to 130 seconds, so expect 1 to 4 samples per run: useful as a trend across runs, not as a per-run peak. `storage` has never emitted a row, and there is no container exit code anywhere, so failure reason still comes from `TASK_HISTORY.ERROR_MESSAGE`.
