# dlt-snowflake-template

Registry-driven [dlt](https://dlthub.com) → Snowflake template. Define every pipeline once in
`pipelines/batch/registries/`; the runner, SPCS task generator, and observability layer all read from
that single source of truth. One file per source, merged into one registry, so pipeline names must be
unique across the whole directory.

**What you get**

- Multiple REST API pipelines sharing one SPCS compute pool (`DLT_POOL`)
  and one Gen2 multi-cluster warehouse (`DLT_WH`).
- Structured logs via `snowflake.telemetry` — every run is visible in your Snowflake event table.
- A run-history table (`<destination database>.OPS._DLT_RUNS`, so `NFL_DEV_DB.OPS` in dev and
  `NFL_PROD_DB.OPS` in prod) for run-level observability without external tooling.
- Vendored dlt reference under `.docs/`.

---

## Quick-start

### 1 — Install

```bash
# dev extra adds duckdb + pytest + ruff for local runs and tests
pip install -e ".[dev]"
```

### 2 — Configure

Copy the secrets example and fill in real values:

```bash
cp .dlt/secrets.toml.example .dlt/secrets.toml
$EDITOR .dlt/secrets.toml
```

Review `pipelines/batch/registries/`. It ships with working REST pipelines in `nfl-registry.yml`
(`nfl_reference`, `nfl_games`), a credential-free generator in `sample-registry.yml`, and one file
per non-REST vendor (`news-registry.yml` for Firecrawl, `weather-registry.yml` for Open-Meteo,
`nflverse-registry.yml` for the nflverse season files read through `nflreadpy`,
`sleeper-registry.yml` for Sleeper's player state, trending and weekly projections).
Add or edit pipeline entries there; do **not** hard-code credentials in the registry (use the
`secret:` prefix to reference a `secrets.toml` path instead).

Non-secret defaults (log level, query tagging, request retries) live in `.dlt/config.toml`.

### 3 — Run locally

List all registered pipelines:

```bash
python -m pipelines.batch.run --list
```

Dry-run against DuckDB (no Snowflake credentials needed):

```bash
make run-local NAME=sample
```

Local runs write to **`duck-db/local.duckdb`**, one file shared by every pipeline. Each keeps its own
dataset, so they land as separate schemas inside it and can be joined locally. The directory is
gitignored and `make clean` removes it.

Run a single pipeline to Snowflake:

```bash
python -m pipelines.batch.run nfl_reference
```

To load to Snowflake from your laptop **without** filling in `.dlt/secrets.toml`, reuse an
existing `snow` CLI connection — its auth (password, key-pair, PAT, or `externalbrowser`)
is mapped to dlt env vars for that run only, so `connections.toml` stays the single source
of truth:

```bash
make run-snowflake NAME=sample                  # -> DLT_DEV_DB.DEV_<user>   (sample declares database: DLT)
make run-snowflake NAME=nfl_reference           # -> NFL_DEV_DB.DEV_<user>   (resolved from the registry)
make run-snowflake NAME=nfl_games CONN=my-conn SF_DATABASE=NFL_PROD_DB DATASET=RAW   # force a target
# inspect what it would export (eval to load into your own shell):
eval "$(make snow-env CONN=my-conn)"
```

Run all pipelines:

```bash
python -m pipelines.batch.run --all
```

Override log level for a single run:

```bash
LOG_LEVEL=DEBUG python -m pipelines.batch.run nfl_reference
```

---

## Deploy to SPCS (7-phase)

### Phase 1-5 — Snowflake infrastructure

The account is split into a shared **control plane** (`DLT_DB`: registry table, image
repo, spec stage, secrets) plus **one data database per source system per environment**:
`NFL_DEV_DB` (ad-hoc, per-developer `DEV_<user>` schemas) and `NFL_PROD_DB` (scheduled
loads into `RAW`, dbt models into `ANALYTICS`). Compute and roles are shared across
sources: `DLT_DEV_POOL`/`DLT_DEV_WH` + `DLT_DEV_ROLE` for dev, `DLT_POOL`/`DLT_WH` +
`DLT_LOADER_ROLE` for prod.

A registry entry names a **stem** (`database: NFL`), not a database, and
`models.resolve_database()` composes `<stem>_<env>_DB`. So one entry covers both
environments, and adding a source means `make new-source NAME=<x>` rather than editing
any shared DDL or spec template. `DLT_DEV_DB` / `DLT_PROD_DB` remain for the sport-less `sample`
pipeline, whose stem is `DLT`.

Crossing source with environment rather than putting environment in the schema is what
makes the boundary structural: `DLT_DEV_ROLE` holds no grant on `NFL_PROD_DB` at all,
so no run-time mistake in dev can reach production data.

**Development is the primary path** — this template exists to get developers building
pipelines in an isolated Snowflake sandbox. Run the shared base once, then set up dev.
Production is a **separate, customer-tailored flow** you stand up later, once you know the
customer's scheduling, sizing, and governance needs.

```bash
# 1. Shared control plane (run once). Add CONFIRM=1 to actually apply.
make setup-base CONFIRM=1     # sql/base/*  -> roles, DLT_DB, registry, spec stage, image repo,
                              #                source EAI + secret (needed by dev too)

# 2. Development (primary): shared dev compute + the DLT_DEV_DB used by `sample`
make setup-dev  CONFIRM=1     # sql/dev/*   -> DLT_DEV_DB, DLT_DEV_POOL, DLT_DEV_WH

# 2b. One per source system. Creates NFL_DEV_DB + NFL_PROD_DB and grants them.
make setup-source SOURCE=nfl CONFIRM=1        # sql/sources/nfl/*
#   then grant the dev role to developers: GRANT ROLE DLT_DEV_ROLE TO USER <login>;

# 3. Production (later, tailor sql/prod/* to the customer first): scheduled Tasks -> DLT_PROD_DB.RAW
make setup-prod CONFIRM=1     # sql/prod/01_prod_db, 02_compute, 03_service_user
#   optional, edit placeholders first: sql/prod/optional/03b_service_user_oidc.sql (keyless CI/CD)
```

Or run the files under `sql/base`, `sql/dev`, `sql/prod` directly in Snowsight in
filename order.

Each script switches to the least-privilege admin role it needs (`USE ROLE`): roles and
users are created as `USERADMIN`, all databases/schemas/warehouses/pools/stages as
`SYSADMIN` (which then grants to the functional roles), and `ACCOUNTADMIN` is used only
for `EXECUTE TASK ON ACCOUNT` (`base/02`). Run setup as an operator who can assume all
three (e.g. connect as `ACCOUNTADMIN`, which inherits them).


### Adding your own source

Everything specific to one upstream API lives in `sql/sources/<name>/` plus one
registry file. Scaffold both, with the five names that must agree already wired up:

```bash
make new-source NAME=weather HOST=api.weather.example
```

That writes the two databases, the external access integration, the API-key secret,
and a one-resource registry stub. Nothing is applied and nothing existing is
overwritten. Then:

```bash
make setup-source SOURCE=weather CONFIRM=1
# set the real key, which no DDL can do for you:
#   ALTER SECRET DLT_DB.OPS.WEATHER_API_KEY SET SECRET_STRING = '<key>';
make run-local NAME=weather_example
```

**`sql/base/` contains nothing source-specific**, so `make setup-base` gives you roles,
the control plane and the registry table and no one else's credentials.

### Phase 6 — Build and push the image

```bash
docker build -f deploy/spcs/Dockerfile -t dlt-pipeline:latest .
docker tag dlt-pipeline:latest \
  <orgname>-<account>.registry.snowflakecomputing.com/DLT_DB/DEPLOY/IMAGES/dlt-pipeline:latest
docker push \
  <orgname>-<account>.registry.snowflakecomputing.com/DLT_DB/DEPLOY/IMAGES/dlt-pipeline:latest
```

### Phase 7 — Generate and activate tasks

```bash
make tasks-sql           # renders build/tasks.sql from registries/; review it
make tasks-apply         # Tasks created SUSPENDED
```

One Task per pipeline that declares a `schedule`. A pipeline without one is skipped with a comment,
which is how `sample` stays runnable by hand without becoming a production Task.

Each Task carries its **full container spec inline**, rendered by `generate_tasks.py`. Staging the
spec and letting Snowflake render it server-side failed for every Task, so there is no prod spec to
upload; `@DLT_DB.DEPLOY.SPECS` now serves the dev templates only.

Resume deliberately, one at a time, cheapest first:

```sql
ALTER TASK DLT_DB.OPS.dlt_task_nfl_reference RESUME;
```

A Task passes no arguments, so a scheduled pipeline must also declare `secret`, `env_var` and
`external_access`, and its season comes from a `{current_season}` token the runner resolves. See
[MAKE-COMMANDS-PROD.md](MAKE-COMMANDS-PROD.md) for the cadence, the calendar behind it, and how to
read a failed Task. APP marts → Snowflake Postgres is a different destination and a child of
`DBT_HARVEST_NFL`, not a cron: [MAKE-COMMANDS-POSTGRES.md](MAKE-COMMANDS-POSTGRES.md).

---

## Develop in Snowflake

Rather than wiring source credentials into a local `.dlt/secrets.toml`, you can develop
entirely in Snowflake: an SPCS job runs the pipeline in a container and loads into your own
isolated `NFL_DEV_DB.DEV_<snowflake_user>` schema (or `DLT_DEV_DB` for `sample`). The bundled `sample` pipeline is an
in-code generator, so it needs **no source secret** — the quickest proof the path works.

```bash
make setup-base CONFIRM=1     # once (shared control plane)
make setup-dev  CONFIRM=1     # once (DLT_DEV_DB + dev compute + DLT_DEV_ROLE)

# One-time prep for the container path:
make image-push               # build + push the image to DLT_DB.DEPLOY.IMAGES
make sync-apply               # sync registry -> DLT_DB.OPS.PIPELINE_REGISTRY (the container reads this)
make dev-spec-upload          # upload the dev spec templates to @DLT_DB.DEPLOY.SPECS
make dev-pool-status          # wait until DLT_DEV_POOL is ACTIVE/IDLE

# Smoke test — no source secret needed:
make run-spcs NAME=sample     # SPCS -> DLT_DEV_DB.DEV_<snowflake_user>  (stem: DLT)

# Real source — bind its credential from a Snowflake SECRET:
make run-spcs NAME=nfl_reference \
  SECRET=DLT_DB.OPS.NFL_API_KEY \
  ENVVAR=SOURCES__NFL__API_KEY \
  EAI=NFL_API_EAI                        # EAI is required for external egress
```

How it chains together: for a real source the dev spec binds the Snowflake SECRET into the
container env var named by `ENVVAR`; `pipelines/batch/run.py` resolves any `secret:<path>` in the
registry through `dlt.secrets`, which reads that env var. `DLT_DATASET` (defaulting to
`DEV_<snowflake_user>` from your connection) sends the load to your isolated schema. Clean
up when done: `DROP SCHEMA IF EXISTS NFL_DEV_DB.DEV_<user>;`.

> The `CREATE SECRET` and External Access Integration DDL live per source in
> `sql/sources/<name>/03_secrets.sql` and `02_external_access.sql`, applied by
> `make setup-source SOURCE=<name>` (the real secret values come from
> `make setup-secrets`). `make run-spcs` prints the exact secret/env-var wiring
> it expects if you get it wrong. The full account bootstrap order is the
> repo-root [SETUP.md](../SETUP.md).


---

## CI/CD (GitHub Actions + OIDC)

Two workflows ship in `.github/workflows/`:

- **`ci.yml`** — offline checks on every push/PR: lint, import/compile, `run --list`, and the DuckDB smoke + unit tests. No Snowflake connection.
- **`deploy.yml`** — the repeatable deploy, on every merge to `main` plus `workflow_dispatch` (a dispatch deploys everything; a push deploys only what its path filters matched). Gated to the `deploy` GitHub environment, it authenticates with a **GitHub OIDC token** (no stored keys) via the SHA-pinned `snowflake-cli` action inside the repo's [`snowflake-setup`](../.github/actions/snowflake-setup/action.yml) composite (install + auth + `snow connection test -x` preflight), then per filter: image rebuild, `registry_sync --emit-sql --prune` → `snow sql -f`, `generate_tasks` suspend/apply/resume with a started-state assertion, dev spec upload, per-sport dbt object deploys (`make -C dbt-pipelines deploy-sport`), agent redeploys, and the ops-dashboard image + service roll.

Because the sync and task generation emit plain SQL, the dlt side of the deploy runs on the OIDC `snow` auth alone — the runner needs **no Python-connector credentials**.

**Setup:**

1. Run `sql/prod/03b_service_user_oidc.sql` to create the keyless `DLT_DEPLOYER` service user and its role grants. Set its `WORKLOAD_IDENTITY` subject to match your repo/environment (e.g. `repo:<owner>/<repo>:environment:deploy`).
2. In repo settings, add secret `SNOWFLAKE_ACCOUNT` and variables `SNOWFLAKE_USER` (`DLT_DEPLOYER`), `SNOWFLAKE_ROLE` (`DLT_LOADER_ROLE`), `SNOWFLAKE_WAREHOUSE` (`DLT_WH`).
3. Create a `deploy` environment (add required reviewers to gate production).

Preview the sync SQL locally without a connection:

```bash
python -m pipelines.batch.registry_sync --emit-sql --prune
```

---

## Project layout

```
.
├── pipelines/
│   ├── common/           # shared helpers
│   │   ├── observability.py   # structured logs + OPS._DLT_RUNS collector
│   │   └── snowflake_session.py  # connect() + in_spcs() (OAuth in SPCS, env vars external)
│   └── batch/            # batch dlt ingestion (scheduled / run-to-completion)
│       ├── registries/        # one YAML per source, merged into one registry
│       │   ├── nfl-registry.yml     # 7 NFL pipelines, database stem: NFL
│       │   └── sample-registry.yml  # credential-free smoke test, stem: DLT
│       ├── run.py             # runner: python -m pipelines.batch.run <name>
│       ├── models.py          # registry loader + validation
│       ├── registry_store.py  # table-backed registry (control plane)
│       ├── registry_sync.py   # sync registries/*.yml -> OPS.PIPELINE_REGISTRY
│       └── sample_source.py   # zero-dependency in-code source
├── sql/                  # bootstrap DDL
│   ├── base/ dev/ prod/  # shared: roles, control plane, compute
│   └── sports/nfl/       # one directory per source system: its two databases
├── deploy/
│   ├── spcs/             # Dockerfile + job spec templates
│   └── tasks/            # generate_tasks.py (one CREATE TASK per pipeline)
├── tests/                # DuckDB smoke test + config unit tests (no Snowflake needed)
├── .docs/                # vendored dlt reference (REST API, Snowflake, dispositions)
├── .dlt/
│   ├── config.toml       # non-secret defaults (committed)
│   └── secrets.toml.example  # template (committed); copy → secrets.toml
├── .github/workflows/       # ci.yml (offline checks) + deploy.yml (OIDC deploy)
├── MAKE-COMMANDS.md      # runbook: laptop runs and backfills
├── MAKE-COMMANDS-SPCS.md # runbook: container runs by hand
├── MAKE-COMMANDS-PROD.md # runbook: scheduled Tasks
├── MAKE-COMMANDS-POSTGRES.md # runbook: APP → Snowflake Postgres copy
├── AGENTS.md             # verified capabilities + template gotchas
└── pyproject.toml
```

---

## Further reading

`.docs/` holds the vendored dlt reference: `rest-api-basic.md` and `rest-api-advanced.md` for
pagination, auth, incremental loading and parent-child resolution; `dlt-snow.md` for the Snowflake
destination; and `dlt-write-dispositions.md` for merge strategies, key requirements, and schema
mapping.

`AGENTS.md` records what has been verified by running it, plus the constraints of this template
that are worth knowing before editing it.
