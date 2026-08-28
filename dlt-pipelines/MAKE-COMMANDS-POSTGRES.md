# APP marts → Snowflake Postgres

Laptop and first-time-account runbook. Every statement is a file under
`sql/postgres/` or `sql/sources/`. Do not type `CREATE` / `ALTER` / `GRANT` by
hand — the next person will not know what you ran.

Destination: Snowflake Postgres database `app`. Two schemas:

- `app_copy` — NFL APP marts (`NFL_PROD_DB.APP`)
- `observability` — materialized `DLT_DB.OPS` tables (Snowflake itself is unchanged)

APP trigger in prod: child of `NFL_PROD_DB.OPS.DBT_HARVEST_NFL`, not a cron.
Obs trigger: `OBS_COPY` after `OBS_REFRESH` and `DBT_OBS_COPY` after
`DBT_RUNS_REFRESH`, both `EXECUTE TASK` the same loader.

Out of scope here: `app_state`, RLS, NCAAF/WNBA, FEATURES/ML, `0.0.0.0/0`,
rewiring `ops-dashboard` to Postgres, `DLT_EVENTS`, per-sport trigger-load
tables.

---

## Once per account

Copy [`.env.postgres.example`](../.env.postgres.example) to the repo-root
`.env.postgres` and fill `PGHOST` / `PGPASSWORD` (the instance admin). Leave
`APP_COPY_WRITER_PASSWORD` blank; setup generates it.

```bash
cd dlt-pipelines

# 1. database app, schemas app_copy + observability, roles, watermarks, writer password
make setup-postgres CONFIRM=1

# 2. EAI (host:5432 only) + SECRET object (placeholder value)
make setup-source SOURCE=postgres CONFIRM=1

# 3. ALTER SECRET from APP_COPY_WRITER_PASSWORD (gitignored SQL)
make setup-postgres-secret CONFIRM=1

# 4. DLT_LOADER_ROLE SELECT on NFL_PROD_DB.APP + DLT_DB.OPS.DBT_BUILDS
snow sql -c weekend-warriors -f sql/sources/nfl/07_app_copy_grants.sql

# 5. standalone copy Task + APP_COPY_NFL AFTER harvest (does not suspend the fleet)
make setup-app-copy-trigger CONFIRM=1
```

Step 4 is that one file, not `make setup-source SOURCE=nfl`, so you do not
re-apply the rest of the NFL source tree. Step 5 creates the loader Task
and the harvest wrapper; it does not run `tasks-apply`.

Laptop access is the instance-level `POSTGRES_INGRESS` policy (IPv4 only),
not the EAI. If `psql` fails with a network-policy error, add your current
public IP there. SPCS jobs need the Snowflake egress CIDRs from
`SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES()` — apply
`sql/sources/postgres/04_ingress_spcs.sql`. Do not open `0.0.0.0/0`. A Task
that times out on `:5432` is this policy, not a missing EAI.

---

## Laptop copy (prove it before a Task exists)

```bash
make run-postgres NAME=nfl_app_to_postgres
# one mart:
make run-postgres NAME=nfl_app_to_postgres RESOURCE=app_game_slate
# observability (writes app.observability from the spec's dataset_name):
make run-postgres NAME=obs_to_postgres
```

That target:

- reuses your `snow` connection to **read** Snowflake (never writes it)
- writes Postgres as `app_copy_writer` using `.env.postgres`
- sets `DLT_DESTINATION=postgres` and `DLT_DATASET` from the spec (`app_copy` or `observability`)

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
`generate_tasks.py` emits a **standalone** Task in `DLT_DB.OPS` (no cron, no
`AFTER`). Snowflake rejects `AFTER` when the predecessor is in another schema
(`091413`) and a graph must share one owner, so the DAG edge is
`sql/sources/nfl/08_app_copy_task.sql`:

```
_DLT_LOADS → DBT_BUILD_NFL → DBT_HARVEST_NFL → APP_COPY_NFL
                                              └─ EXECUTE TASK dlt_task_nfl_app_to_postgres
```

`make tasks-suspend` / `tasks-apply` / `tasks-resume` do **not** touch the
harvest graph. Do not hang `AFTER harvest` on the loader Task again.

```bash
make setup-app-copy-trigger CONFIRM=1
```

The container image needs `dlt[postgres]`. That is a dependency change, so it
needs an image rebuild (prefer CI amd64, not an Apple Silicon laptop). **Do not
fire the copy Task until `:latest` is the new image** — a harvest fire against
the old image dies on `No module named 'psycopg2'` / missing postgres dest and
pages Slack (`DLT_ALERTS=1`).

### What the laptop run already proved

| Path | Laptop | Prod Task |
|---|---|---|
| `SELECT` `NFL_PROD_DB.APP` | your `snow` user | `DLT_LOADER_ROLE` (07 grants, already applied) |
| Write `app.app_copy` as `app_copy_writer` | `.env.postgres` | SECRET + EAI (already applied) |
| Watermark UPSERT | same writer | same |
| `dlt[postgres]` installed | local venv | **image rebuild** |
| Spec + harvest wrapper | YAML + 08 on disk | `make setup-app-copy-trigger` |

### After the image is `:latest`

Then prove the Task, not only the laptop:

```bash
# loader Task is standalone (no AFTER, no cron)
rg "dlt_task_nfl_app_to_postgres" dlt-pipelines/build/tasks.sql

# Wrapper is the DAG edge
rg "AFTER NFL_PROD_DB.OPS.DBT_HARVEST_NFL" dlt-pipelines/sql/sources/nfl/08_app_copy_task.sql

snow sql -c weekend-warriors -q \
  "SHOW TASKS LIKE 'dlt_task_nfl_app_to_postgres' IN SCHEMA DLT_DB.OPS;"
snow sql -c weekend-warriors -q \
  "SHOW TASKS LIKE 'APP_COPY_NFL' IN SCHEMA NFL_PROD_DB.OPS;"

# First fire without waiting for a dbt build. Leave the loader SUSPENDED —
# RESUME without SCHEDULE/AFTER is 091453. EXECUTE TASK works anyway.
snow sql -c weekend-warriors --role DLT_LOADER_ROLE -q \
  "EXECUTE TASK DLT_DB.OPS.dlt_task_nfl_app_to_postgres;"
```

A green `TASK_HISTORY` row plus `app_copy.app_copy_watermark` for all 20 tables
is the production proof. The laptop run is not.

---

## Observability copy (`DLT_DB.OPS` → `app.observability`)

Snowflake stays `DLT_DB.OPS`. This job copies the materialized OPS tables
into the existing Postgres instance (same EAI, secret, `app_copy_writer`).
Since 2026-08 the copy is **incremental per table**: a registry table entry
may be a mapping (`name` / `mode: append|merge` / `cursor` / `primary_key`)
instead of a bare name, and the cursor is pushed into the Snowflake `WHERE`
so neither side re-reads history. Bare names stay full replace. Full
replaces of the 90-day history tables every fire are what OOMed the shared
Postgres instance (`psycopg2.errors.OutOfMemory`, 2026-08-24). Incremental
never deletes, so the scheduled `obs_to_postgres_resync` (Sunday 03:00 UTC,
spec-level `write_disposition: replace` as the blunt override) re-bounds
Postgres to Snowflake retention weekly and heals event-timestamp skew.

If `setup-postgres` already ran before observability existed:

```bash
make setup-postgres-observability CONFIRM=1
```

Laptop prove (uses the spec's `dataset_name`, so this writes `observability`
not `app_copy`):

```bash
make run-postgres NAME=obs_to_postgres
```

```sql
-- on the Postgres instance, database app
SELECT table_name, row_count, source_ref, copied_at
FROM observability.observability_watermark
ORDER BY table_name;
```

Do not reuse `app_copy.app_copy_watermark` or `DBT_BUILDS`. An obs run
must not fail looking up an NFL build id.

```bash
# syncs PIPELINE_REGISTRY (the container reads the table, not YAML),
# then the standalone loader Task + OBS_COPY / DBT_OBS_COPY wrappers
# (does not suspend the fleet, does not run tasks-apply)
make setup-obs-copy-trigger CONFIRM=1
```

```
OBS_REFRESH      → OBS_COPY      → EXECUTE TASK dlt_task_obs_to_postgres
                                   (DLT_LOADER_ROLE; same owner as the root)
DBT_RUNS_REFRESH → DBT_OBS_COPY  → EXECUTE TASK dlt_task_obs_to_postgres
                                   (DBT_RUNNER_ROLE; same owner as that root)
```

Same schema is not enough: Snowflake also requires one owner per graph
(`091405`). `DBT_RUNS_REFRESH` is `DBT_RUNNER_ROLE`, so its wrapper cannot
be created as `DLT_LOADER_ROLE`.

The copy job writes SPCS events, which re-fire `OBS_REFRESH`. Both
wrappers share `DLT_DB.OPS.OBS_COPY_LATCH` and no-op for **50 minutes**
after a fire (raised from 10 on 2026-08-24: with both refresh roots at a
3600s trigger interval this bounds the copy to about once an hour) so that
is not an infinite loop. `SP_OBS_COPY_FIRE(TRUE)` -- the dashboard's
refresh button -- skips the latch but never the two in-flight guards. `DBT_RUNS` / query-log tables are
owned by `DBT_RUNNER_ROLE`; 11 grants `SELECT` to `DLT_LOADER_ROLE`
(laptop SYSADMIN hid this). The observability watermark branch lives in
this repo; the container uses it after the next image roll.

`HEADLINES_DAILY` is often suspended; headlines update in Postgres on the
next obs/dbt copy (full table replace).

```bash
# loader stays SUSPENDED — RESUME without SCHEDULE/AFTER is 091453
snow sql -c weekend-warriors --role DLT_LOADER_ROLE -q \
  "EXECUTE TASK DLT_DB.OPS.dlt_task_obs_to_postgres;"
```

Copied (base tables, not views): `PIPELINE_RUNS`, `TASK_RUNS`, `LOG_LINES`,
`METRIC_SAMPLES`, `PIPELINE_REGISTRY`, `DBT_BUILDS`, `DBT_RUNS`,
`DBT_RUNS_REFRESH_LOG`, `DBT_QUERY_LOG`, `DBT_QUERY_OPERATOR_STATS`,
`HEADLINES`, `ALERT_STATE`. Out: `DLT_EVENTS`, per-sport `_DLT_RUNS` /
`DBT_TRIGGER_LOADS`.

---

## Dashboard reader (`app_api`)

Both dashboards SELECT as `app_api` (`app.app_copy` for analytics,
`app.observability` for ops). That role has LOGIN from `setup-postgres`
but no password until:

```bash
make setup-postgres-api-password CONFIRM=1
```

That target generates `APP_API_PASSWORD` into repo-root `.env.postgres` if
blank, `ALTER ROLE app_api`, and proves `SELECT` on `app_copy.app_copy_watermark`.
It does not recreate the database and does not touch the writer password.

`make -C analytics-dashboard serve` / `dev` / `test-live` (and the same
targets under `ops-dashboard`) source the same `.env.postgres` for `PGHOST`
/ `PGPORT` / `APP_API_PASSWORD`. The APIs hard-code user `app_api` and
database `app`; they will not use the admin `PGUSER` / `PGPASSWORD` pair.

```bash
# after the password exists
make -C ../analytics-dashboard test-live
make -C ../ops-dashboard test-live
```

Rollback (warehouse SQL):
`ANALYTICS_DASHBOARD_BACKEND=snowflake make -C ../analytics-dashboard test-live`.

---

## Files a new user should read, in order

1. This runbook
2. `sql/postgres/README.md` — init statements
3. `sql/sources/postgres/README.md` — EAI + secret
4. `sql/sources/nfl/07_app_copy_grants.sql` — APP SELECT
5. `sql/sources/nfl/08_app_copy_task.sql` — harvest wrapper
6. `pipelines/batch/registries/app-copy-registry.yml` — APP table list
7. `pipelines/batch/registries/observability-copy-registry.yml` — OPS table list
8. `sql/ops/11_obs_copy_task.sql` — obs refresh wrappers
