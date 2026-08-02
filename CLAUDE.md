# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An NFL analytics stack on Snowflake, assembled from two upstream templates and adapted. Data source is the [BallDontLie](https://api.balldontlie.io) NFL API; OpenAPI specs for NFL and NCAAF live in [.docs/openapi-meta/](.docs/openapi-meta/) and `BALL_DONT_LIE_API_KEY` is in `.env`.

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
make run NAME=pg_public           # local run → DuckDB (no Snowflake creds needed)
make run-sf NAME=pg_public        # → Snowflake via your snow connection, into NFL_DEV_DB.DEV_<user>
make test                         # full suite
make test-config                  # config unit tests only (no dlt, no network)
make lint / make fmt              # ruff (line-length 100)
make help                         # all targets, each self-documented
```

Run a single test the usual pytest way: `uv run --extra dev pytest tests/test_registry_config.py::<test_name>`.

`make run-sf` and `make snow-env` map an existing `snow` CLI connection's auth into dlt env vars for one run, so `connections.toml` stays the only place credentials live.

**Batch only.** `pipelines/batch/` holds scheduled, run-to-completion loads, deployed as one Snowflake Task per pipeline and generated by `deploy/tasks/generate_tasks.py` from the registry. The template's second subsystem, `pipelines/cdc/` (continuous Snowpipe Streaming CDC running as a long-lived SPCS service), was removed along with `sql/cdc/` and its Make targets rather than adapted. If you see a reference to a `cdc-*` target anywhere, it is stale.

Deployment is a 7-phase flow (`sql/base` → `sql/dev` → `sql/prod`, then image push, then task generation) documented in [dlt-pipelines/README.md](dlt-pipelines/README.md). The `setup-*` targets are guarded by `CONFIRM=1`.

**The account model is one database per sport, crossed with environment.** A shared control plane (`DLT_DB`: registry table, spec stage, image repo, secrets) plus per-sport storage: `NFL_DEV_DB` (per-developer `DEV_<user>` schemas) and `NFL_PROD_DB` (`RAW` and `RAW_STAGING` for dlt, `PREP` / `CORE` / `ANALYTICS` for dbt). Adding a sport means copying `sql/sources/nfl/` and adding a registry entry; roles, compute pools and warehouses are all shared. `DLT_DEV_DB` / `DLT_PROD_DB` remain only for the sport-less `sample` smoke test.

The registry stores a **stem** (`database: NFL`), not a full name. `models.resolve_database()` composes `<stem>_<env>_DB`, so one entry covers both environments and no caller has to name a database by hand. `make setup-source SOURCE=nfl CONFIRM=1` creates a source's databases, and `make new-source NAME= HOST=` scaffolds one via `tools/new_source.py`.

### Scheduling: what a Task cannot pass

A Snowflake Task passes **no arguments**, and that constraint shapes several things that otherwise look arbitrary:

- **Season.** `/standings` and `/advanced_stats` return HTTP 400 without a `season`; `/games` and `/stats` silently return *every* season. So season-scoped resources declare `season: "{current_season}"` in the registry and `run.py` substitutes the year at run time (`models.current_season()`, rolling over on 1 August). A backfill's `--param` still overrides it.
- **Credentials and egress.** A scheduled pipeline must declare `secret`, `env_var` and `external_access` in its registry entry. `PipelineSpec.validate()` rejects a `schedule` without them, because the alternative is a container failing at 09:00 UTC. `make run-spcs` reads the same fields, so dev and prod share one record of the binding.
- **Clause order.** `EXECUTE JOB SERVICE` requires `EXTERNAL_ACCESS_INTEGRATIONS` *before* `FROM`. Putting it after the template file is a SQL compilation error.

Cadence and the 2026 NFL calendar behind it are in [dlt-pipelines/MAKE-COMMANDS-PROD.md](dlt-pipelines/MAKE-COMMANDS-PROD.md). Three runbooks now: `MAKE-COMMANDS.md` (laptop), `-SPCS.md` (container by hand), `-PROD.md` (scheduled).

## dbt-pipelines — modeling and Cortex Agents

A dbt project whose lifecycle runs **inside Snowflake** via `EXECUTE DBT PROJECT` / `snow dbt execute`, not via local dbt Core.

The environment mechanism is the thing to understand first. `profiles.yml` hardcodes nothing — it reads `DBT_DATABASE` / `DBT_SCHEMA` / `DBT_WAREHOUSE` / `DBT_ROLE` through `env_var()` with **no defaults**, and Snowflake injects those by resolving [env.yml](dbt-pipelines/env.yml) at execution time. A run outside that path fails fast rather than silently targeting the wrong database. In `dev`, `DBT_SCHEMA` resolves to `CURRENT_USER()`, giving each developer an isolated schema.

```bash
# --env must come BEFORE the project name; tokens after it go to dbt Core, which has no --env
snow dbt deploy cortex_lifecycle --source . --default-env dev \
  --external-access-integration dbt_ext_access --force
snow dbt execute --env dev DB.SCHEMA.cortex_lifecycle build
snow dbt execute --env prod DB.SCHEMA.cortex_lifecycle run-operation deploy_example_agent
```

Requires Snowflake CLI **>= 3.21** for the `--env` / `--default-env` flags — satisfied (3.23.0), with the `ENABLE_DBT_PROJECT_ENV_VARS` feature flag enabled as described above. `dbt deps` needs an External Access Integration reaching `hub.getdbt.com` and `codeload.github.com`.

**Model layers** are set per directory in `dbt_project.yml` under `models: cortex_agent_lifecycle: nfl:`. `prep/` builds views into `PREP`, `core/dimensions/` and `core/facts/` build tables into `CORE`, `semantic_views/` and `evaluations/` build into `ANALYTICS`.

**The config keys must mirror the folder nesting.** They are directory names, so `models/nfl/prep/` needs `nfl:` then `prep:`. Flattening them does not error: the models still build, just as views in the default target schema with the `+schema` silently dropped.

**`DBT_COLLAPSE_SCHEMAS` decides whether that fan-out happens.** `env.yml` sets it `true` in dev, where `macros/generate_schema_name.sql` then ignores every `+schema` so a developer gets one schema (`DEV_JSMITH`) rather than three. Prod sets it `false` and the layers separate.

**Three models ship disabled**, and this is deliberate rather than unfinished. `sv_example` and `eval_dataset` are template skeletons pointing at the placeholder source that `models/sources.yml` replaced, kept for their authoring guidance. `sv_nfl_player_advanced` is off because the Next Gen source tracks each player in exactly one discipline: the passing, rushing and receiving endpoints have zero player overlap, so the view would promise cross-discipline comparisons the data cannot answer. Its underlying facts still build.

**Agents are macros, not models.** `macro-paths` includes `agents/`, and each agent is a `deploy_<name>` wrapper macro holding its spec inline — dbt Projects on Snowflake cannot read a file at runtime. Because the spec is raw text dbt does not render, fully-qualified names use `<<DATABASE>>`, `<<SCHEMA>>`, `<<WAREHOUSE>>` tokens that `create_agent` / `alter_agent` substitute with the active target. Deploy with `dbt run-operation deploy_<name>` (add `--args '{alter: true}'` for a zero-downtime update).

Raw sources in `models/sources.yml` are deliberately **not** environment-driven: every developer reads the same `NFL_PROD_DB.RAW` tables. dbt must never write to `RAW` or `RAW_STAGING`, which dlt owns.

[WORKING-SESSION.md](dbt-pipelines/WORKING-SESSION.md) is a phase-driven runbook meant to be executed by an agent ("Follow WORKING-SESSION.md"); it gates on user input between phases. The README's "Writing effective semantic views" and "Writing effective agents" sections encode real constraints — notably that semantic-view DDL clause order is enforced (`TABLES → RELATIONSHIPS → FACTS → DIMENSIONS → METRICS → COMMENT → AI_*`, with `AI_VERIFIED_QUERIES` last), and that SQL-generation rules belong in the semantic view's `AI_SQL_GENERATION` clause rather than in agent instructions.

## CI/CD

Root [.github/workflows/](.github/workflows/). `ci.yml` never touches Snowflake, so it runs on every push and pull request including from forks: lint, tests, registry validation, and a render of the Task DDL to catch an unsubstituted spec placeholder before it can reach a Task. `deploy.yml` always touches Snowflake, so it runs only on `main` and `workflow_dispatch`, gated on the `deploy` GitHub environment.

`deploy.yml` computes path filters once and gates each job on them, so a change deploys only what it affects: image rebuild, registry resync, Task reapply, dev spec upload, dbt build, agent redeploy. `sql/**` is in **no** filter. Those files create roles, pools and grants as `SYSADMIN` / `USERADMIN` / `ACCOUNTADMIN` and stay a deliberate `make setup-*` run by a human.

**`CREATE OR ALTER TASK` resets a Task to suspended.** Reapplying `tasks.sql` over a running schedule silently stops it: the DDL succeeds and the next cron fire never happens. `generate_tasks.py --resume` emits the matching `ALTER TASK ... RESUME` statements, and the deploy job applies them straight after. Anyone running `make tasks-apply` by hand has to resume the Tasks themselves.

### Why CI can reach Snowflake at all

The account-level network policy allows only a short IP list, and GitHub-hosted runners are nowhere near it. Workload identity federation does not change that: OIDC removes the stored credential, not the network path, and there is no exemption for `TYPE = SERVICE` users.

What makes it work is that **network policies override rather than stack**. A policy attached to a user replaces the account policy for that user alone, so `DLT_DEPLOYER` carries its own and the control shifts to the OIDC subject claim, which binds the token to this repository and the `deploy` environment, plus `DLT_LOADER_ROLE`'s limited grants. Every other user keeps the account policy. See `dlt-pipelines/sql/prod/03b_service_user_oidc.sql`, which explains the trade-off and the tighter self-hosted-runner alternative.

## Known gaps

- **Nothing chains dbt behind the ingestion Tasks.** `dbt build` runs on a code push, not when new rows land in `RAW`. A Task graph with dbt as a child of the last dlt Task is the natural shape and is not built.
- **`stats?seasons[]=<year>` is incomplete.** A 2023 replay returned 47 of 49 games; both missing games have data when fetched by `game_id`. Fetching per game the way `plays` does would close it. The dbt reconciliation tests exist to keep this visible.
- **No alerting on Task failure.** Visible only in `TASK_HISTORY` and `_DLT_RUNS`.
- `.docs/README.md` and the `cortex-agents` / `data-modeling` HTML files are 0 bytes.
