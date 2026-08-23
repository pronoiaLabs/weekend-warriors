# APP marts → Snowflake Postgres

Laptop and first-time-account runbook. Every statement is a file under
`sql/postgres/` or `sql/sources/`. Do not type `CREATE` / `ALTER` / `GRANT` by
hand — the next person will not know what you ran.

Destination: Snowflake Postgres database `app`, schema `app_copy`.
Source: `NFL_PROD_DB.APP` (the 20 tables in
`analytics-dashboard/api/app/sports/profiles/nfl.py`).
Trigger in prod: child of `NFL_PROD_DB.OPS.DBT_HARVEST_NFL`, not a cron.

Out of scope here: `app_state`, RLS, NCAAF/WNBA, FEATURES/ML, `0.0.0.0/0`.

---

## Once per account

Copy [`.env.postgres.example`](../.env.postgres.example) to the repo-root
`.env.postgres` and fill `PGHOST` / `PGPASSWORD` (the instance admin). Leave
`APP_COPY_WRITER_PASSWORD` blank; setup generates it.

```bash
cd dlt-pipelines

# 1. database app, schema app_copy, roles, watermark table, writer password
make setup-postgres CONFIRM=1

# 2. EAI (host:5432 only) + SECRET object (placeholder value)
make setup-source SOURCE=postgres CONFIRM=1

# 3. ALTER SECRET from APP_COPY_WRITER_PASSWORD (gitignored SQL)
make setup-postgres-secret CONFIRM=1

# 4. DLT_LOADER_ROLE SELECT on NFL_PROD_DB.APP + DLT_DB.OPS.DBT_BUILDS
snow sql -c weekend-warriors -f sql/sources/nfl/07_app_copy_grants.sql
```

Step 4 is that one file, not `make setup-source SOURCE=nfl`, so you do not
re-apply the rest of the NFL source tree.

Laptop access is the instance-level `POSTGRES_INGRESS` network policy in
Snowsight, not the EAI. If `psql` fails with a network-policy error, add your
current public IP there. Do not open `0.0.0.0/0`.

---

## Laptop copy (prove it before a Task exists)

```bash
make run-postgres NAME=nfl_app_to_postgres
# one mart:
make run-postgres NAME=nfl_app_to_postgres RESOURCE=app_game_slate
```

That target:

- reuses your `snow` connection to **read** `NFL_PROD_DB.APP` (never writes Snowflake)
- writes Postgres as `app_copy_writer` using `.env.postgres`
- sets `DLT_DESTINATION=postgres` and `DLT_DATASET=app_copy`

`make run-snowflake` forces `DLT_DESTINATION=snowflake` and a `DEV_<user>`
schema. It is the wrong target for this pipeline.

After a green run:

```sql
-- on the Postgres instance, database app
SELECT sport, table_name, source_build_id, row_count, copied_at
FROM app_copy.app_copy_watermark
ORDER BY table_name;
```

A missing watermark row means the UPSERT failed and the job should have
exited non-zero.

---

## Production Task

The registry entry is `pipelines/batch/registries/app-copy-registry.yml`.
`generate_tasks.py` emits `AFTER NFL_PROD_DB.OPS.DBT_HARVEST_NFL` (no cron).

The copy Task joins the harvest graph:

```
_DLT_LOADS → DBT_BUILD_NFL → DBT_HARVEST_NFL → dlt_task_nfl_app_to_postgres
```

`CREATE OR ALTER` fails if that graph's root is started. `make tasks-suspend`
therefore also suspends `DBT_BUILD_NFL` and `DBT_HARVEST_NFL` when any
registry `after:` exists. Resume order is copy, then harvest, then build.

```bash
make sync-apply
make tasks-sql            # read build/tasks.sql: AFTER, not USING CRON
make deploy               # suspend (incl. harvest graph) → apply → resume
```

The container image needs `dlt[postgres]`. That is a dependency change, so it
needs an image rebuild (prefer CI amd64, not an Apple Silicon laptop). **Do not
resume the copy Task until `:latest` is the new image** — a harvest fire against
the old image dies on `No module named 'psycopg2'` / missing postgres dest and
pages Slack (`DLT_ALERTS=1`).

### What the laptop run already proved

| Path | Laptop | Prod Task |
|---|---|---|
| `SELECT` `NFL_PROD_DB.APP` | your `snow` user | `DLT_LOADER_ROLE` (07 grants, already applied) |
| Write `app.app_copy` as `app_copy_writer` | `.env.postgres` | SECRET + EAI (already applied) |
| Watermark UPSERT | same writer | same |
| `dlt[postgres]` installed | local venv | **image rebuild** |
| Spec + AFTER harvest | YAML on disk | `sync-apply` + `tasks-apply` |

### After this branch merges

`deploy.yml` rebuilds the image (`pyproject.toml` / `uv.lock`) and reapplies
Tasks (`app-copy-registry.yml`, `generate_tasks.py`, `dlt_job_postgres.tmpl.yaml`).
That apply suspends `DBT_BUILD_NFL` / `DBT_HARVEST_NFL` for the duration.

Then prove the Task, not only the laptop:

```bash
# spec is AFTER harvest, not cron
rg "AFTER NFL_PROD_DB.OPS.DBT_HARVEST_NFL" dlt-pipelines/build/tasks.sql

# Task exists and is started (after deploy resume)
snow sql -c weekend-warriors --role DLT_LOADER_ROLE -q \
  "SHOW TASKS LIKE 'dlt_task_nfl_app_to_postgres' IN SCHEMA DLT_DB.OPS;"

# First fire without waiting for a dbt build
snow sql -c weekend-warriors --role DLT_LOADER_ROLE -q \
  "EXECUTE TASK DLT_DB.OPS.dlt_task_nfl_app_to_postgres;"
```

A green `TASK_HISTORY` row plus `app_copy.app_copy_watermark` for all 20 tables
is the production proof. The laptop run is not.

---

## Files a new user should read, in order

1. This runbook
2. `sql/postgres/README.md` — init statements
3. `sql/sources/postgres/README.md` — EAI + secret
4. `sql/sources/nfl/07_app_copy_grants.sql` — APP SELECT
5. `pipelines/batch/registries/app-copy-registry.yml` — table list
