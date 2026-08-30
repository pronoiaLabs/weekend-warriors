# Setting up your own Snowflake account

This is the ordered, end-to-end bootstrap for a fresh clone: every object the
stack needs, created from files in this repo, in the order the dependencies
require. Each phase is a `make` target or a named file, so what ran is always
answerable. Deeper dives live next to each subsystem
([dlt-pipelines/README.md](dlt-pipelines/README.md),
[dbt-pipelines/README.md](dbt-pipelines/README.md), the `MAKE-COMMANDS-*.md`
runbooks); this page is the spine that orders them.

What you end up with: dlt ingestion on Snowflake Task schedules (SPCS
containers), dbt building PREP / CORE / ANALYTICS on data-landed triggers,
Cortex Agents on the semantic views, an observability layer with Slack
alerting, a Snowflake Postgres instance serving the dashboards, and optional
keyless CI/CD.

**Cost:** everything auto-suspends except the ops-dashboard pool (always-on XS)
and the Postgres instance, which bills hourly while running
(`ALTER POSTGRES INSTANCE "<name>" SUSPEND;` when idle). Warehouse and pool
sizing notes live in `dlt-pipelines/sql/prod/02_compute.sql`.

## Prerequisites

- A Snowflake account, and a user who can assume `ACCOUNTADMIN`,
  `SECURITYADMIN`, `USERADMIN` and `SYSADMIN`. Every setup file elevates
  itself with `USE ROLE`; the phase table below says which roles each exercises.
  Multi-cluster warehouses need Enterprise edition (Standard works with
  `MAX_CLUSTER_COUNT = 1`, noted in prod/02). Cortex Agents and Snowflake
  Postgres must be available in your region.
- Tooling: `snow` (Snowflake CLI) **>= 3.21**, `uv`, Docker, `psql`
  (`brew install libpq`, keg-only). Check with `make -C dlt-pipelines doctor`.
- In `~/.snowflake/config.toml`, enable the dbt env-var flag the runbooks use:

  ```toml
  [cli.features]
  enable_dbt_project_env_vars = true
  ```

## 1. Connect

Copy the `[weekend-warriors]` block from
[connections.toml.example](connections.toml.example) into
`~/.snowflake/connections.toml` and fill in your account and user. Keep the
connection name `weekend-warriors`: `dbt-pipelines/Makefile` defaults to it and
every documented `snow sql -c weekend-warriors` command assumes it. Verify:

```bash
snow connection test -c weekend-warriors
```

## 2. Env files (repo root, gitignored)

| Copy | To | Fill now | Filled by scripts |
|---|---|---|---|
| `.env.postgres.example` | `.env.postgres` | `PG_CLIENT_CIDRS` (your public IP/32); review the `PG_*` instance sizing | `PGHOST`, `PGPASSWORD`, `APP_COPY_WRITER_PASSWORD`, `APP_API_PASSWORD` |
| `.env.snowflake.example` | `.env.snowflake` | whichever API keys you have, Slack webhook path | nothing |

## 3. Phases, in order

All `make` commands run from `dlt-pipelines/` unless prefixed. Every `setup-*`
target prints what it will create and requires `CONFIRM=1`. Verify with the
query in the right column, not the exit code.

| # | Command | Roles | Creates | Verify |
|---|---|---|---|---|
| 1 | `make setup-base CONFIRM=1` | ACCOUNTADMIN, USERADMIN, SYSADMIN | account grants (compute pool + Postgres instance to SYSADMIN), `DLT_LOADER_ROLE` / `DLT_DEV_ROLE`, `DLT_DB` control plane, registry, `DBT_RUNNER_ROLE` (its warehouse grant comes with `DLT_WH` in step 7), `DBT_EXT_ACCESS` EAI | `SHOW DATABASES LIKE 'DLT_DB'` |
| 2 | `make setup-dev CONFIRM=1` | SYSADMIN | `DLT_DEV_DB`, dev pools, `DLT_DEV_WH`, `DEVELOPMENT_WH` | `SHOW WAREHOUSES LIKE 'DEV%'` |
| 3 | `make setup-source SOURCE=<s> CONFIRM=1` for `nfl`, `ncaaf`, and the extras you want (`firecrawl`, `nflverse`, `openmeteo`, `sleeper`) | SYSADMIN, ACCOUNTADMIN | per-source DEV/PROD databases, EAI, placeholder secret | `SHOW DATABASES LIKE '%_PROD_DB'` |
| 4 | `make setup-secrets CONFIRM=1` | SYSADMIN | real secret values from `.env.snowflake` (empty vars skipped) | a later `run-spcs` succeeds |
| 5 | `make setup-ops CONFIRM=1` | SYSADMIN, ACCOUNTADMIN, DLT_LOADER_ROLE, DBT_RUNNER_ROLE | `DLT_EVENTS` event table + account binding (compute is `DLT_WH`, so run step 7 first), observability tables/procs, cost tags, Slack alerting integration | `SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT` (level ACCOUNT) |
| 6 | `make setup-integrations CONFIRM=1` | SYSADMIN, ACCOUNTADMIN | GitHub API integration for Snowsight Workspaces. Fork note: the allowed prefix is `github.com/pronoiaLabs`; point it at your org with the `ALTER API INTEGRATION` documented in the file | `SHOW API INTEGRATIONS` |
| 7 | `make setup-prod CONFIRM=1` | SYSADMIN, USERADMIN | `DLT_PROD_DB`, `DLT_POOL`, `DLT_WH`, `DLT_LOADER` key-pair service user | `SHOW COMPUTE POOLS` |
| 8 | `make image-push` then `make dev-spec-upload` | (connection role) | dlt container image in `DLT_DB.DEPLOY.IMAGES`, dev job specs staged | `make run-spcs NAME=sample` |
| 9 | **Postgres chain**, below | SYSADMIN, ACCOUNTADMIN, psql | instance, database `app`, roles, EAI/ingress, copy triggers | below |
| 10 | `make deploy` | DLT_LOADER_ROLE | registry sync + the scheduled Task fleet (suspend, apply, resume) | `SHOW TASKS IN SCHEMA DLT_DB.OPS` (all `started`) |
| 11 | **dbt + agents**, below | SYSADMIN | project objects, prod builds, analyst agents, CoWork | below |
| 12 | **Dashboards**, below | SYSADMIN, USERADMIN, ACCOUNTADMIN | ops dashboard service, analytics grants | below |
| 13 | **CI/CD (optional)**, below | USERADMIN, SECURITYADMIN, SYSADMIN, ACCOUNTADMIN | keyless `DLT_DEPLOYER` OIDC user | first green deploy run |

### Phase 9: Snowflake Postgres

The instance itself is SQL now, not a Snowsight click-through. Safe on an
account that already has it: the CREATE is guarded by `SHOW POSTGRES INSTANCES`
and nothing ever drops or recreates the instance.

```bash
make setup-postgres-instance CONFIRM=1   # CREATE POSTGRES INSTANCE from PG_*; polls to READY,
                                         # writes PGHOST + PGPASSWORD into .env.postgres,
                                         # creates/extends the ingress policy from PG_CLIENT_CIDRS
make setup-postgres CONFIRM=1            # psql: database app, schemas, roles, watermarks
make setup-source SOURCE=postgres CONFIRM=1   # placeholder secret + host EAI + SPCS ingress CIDRs
make setup-postgres-secret CONFIRM=1
make setup-postgres-api-password CONFIRM=1
make setup-postgres-observability CONFIRM=1
snow sql -c weekend-warriors -f sql/sources/nfl/07_app_copy_grants.sql
make run-postgres NAME=nfl_app_to_postgres    # prove the copy from the laptop
make setup-app-copy-trigger CONFIRM=1
make setup-obs-copy-trigger CONFIRM=1
```

The one-time detail worth knowing: `CREATE POSTGRES INSTANCE` returns the
`snowflake_admin` password exactly once, and the script writes it straight into
`.env.postgres`. If that capture ever fails it says so and prints the recovery
(`ALTER POSTGRES INSTANCE ... RESET ACCESS FOR 'snowflake_admin'`). The SPCS
ingress CIDRs are discovered live and expire when Snowflake rotates them;
`make setup-postgres-network CONFIRM=1` is the re-run. Full runbook:
[dlt-pipelines/MAKE-COMMANDS-POSTGRES.md](dlt-pipelines/MAKE-COMMANDS-POSTGRES.md).

### Phase 11: dbt and agents

```bash
cd ../dbt-pipelines
make deploy-dev                         # shared dev object
make deploy-sport SPORT=nfl             # per-sport prod objects (repeat: ncaaf)
make build-sport SPORT=nfl              # first prod build (later builds fire on data landing)
make deploy-agent SPORT=nfl             # analyst agent (repeat per sport)
make deploy-snowpark                    # SP_PLAYER_BRIDGE (NFL bridge pre_hook needs it)
make setup-cowork CONFIRM=1             # register the agents in Snowflake CoWork
```

The prod dbt triggers (`sql/sources/<sport>/05_dbt_trigger.sql`) were already
applied by phase 3; they start building as soon as scheduled loads land.

### Phase 12: dashboards

```bash
cd ../ops-dashboard
make image-push                          # note the tag it prints
make spec-upload
make setup CONFIRM=1 TAG=<that tag>      # role + pool + service pinned to the tag
cd ../analytics-dashboard
make setup CONFIRM=1                     # 03_app_grants fails until the first prod dbt
                                         # build creates the APP schemas; re-run it after
```

### Phase 13: CI/CD (optional)

`.github/workflows/deploy.yml` deploys on merge to `main` with keyless GitHub
OIDC. To enable it on your fork: fill the `SUBJECT` placeholders in
[dlt-pipelines/sql/prod/optional/03b_service_user_oidc.sql](dlt-pipelines/sql/prod/optional/03b_service_user_oidc.sql)
with your org/repo numeric ids (the file explains how to find them), review its
ownership-transfer block (those objects exist only after phase 11), apply it by
hand, and create a `deploy` GitHub environment. The task-render job uses the
`PGHOST` fallback baked into `generate_tasks.py` unless you export your own as
a repo Actions variable, so set one or the rendered copy Tasks will point at
the wrong Postgres host.

## Manual steps, the honest list

Everything a human types that no file can carry:

- API keys into `.env.snowflake` (BallDontLie, Firecrawl) and the Slack
  incoming-webhook path (`T…/B…/x…` part only).
- Your public IP(s) into `PG_CLIENT_CIDRS`.
- `~/.snowflake/connections.toml` account + user.
- The GitHub App install for Snowsight Workspaces (phase 6 prints the steps),
  and your org in `GITHUB_API_INT`'s allowed prefix on a fork.
- OIDC subject ids + the `deploy` GitHub environment (phase 13).
- Granting `DLT_DEV_ROLE` to your developers.

## Re-running

Every phase is re-runnable: files use `IF NOT EXISTS` or create-then-`ALTER`,
`OR REPLACE` appears only where grants are re-issued in the same file, and the
Postgres instance CREATE is skipped when the instance exists. The two
deliberate exceptions: secret values never change without
`make setup-secrets` (a placeholder `CREATE IF NOT EXISTS` cannot overwrite
them), and `sql/prod/optional/` is never glob-applied.
