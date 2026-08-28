# Postgres source objects (Snowflake side)

These files provision the Snowflake Postgres instance, the copy job's egress,
and a password secret. They do **not** create `POSTGRES_DEV_DB` /
`POSTGRES_PROD_DB`; the destination is the Snowflake Postgres instance, not a
Snowflake database.

Only `03_secrets.sql` is committed SQL. Everything account-specific (the
instance itself, the host EAI, the ingress CIDRs) is rendered from the
repo-root `.env.postgres` into `.generated/` (gitignored) by the two scripts,
so the glob that `make setup-source SOURCE=postgres` runs can never apply an
instance CREATE or someone else's hostname.

| File | What it does | Applied by |
|---|---|---|
| `apply_instance.sh` | `CREATE POSTGRES INSTANCE` from the `PG_*` env (guarded by `SHOW`; never drops/recreates), polls to READY, writes `PGHOST`/`PGPASSWORD` back to `.env.postgres`, creates/extends the instance ingress policy from `PG_CLIENT_CIDRS` | `make setup-postgres-instance CONFIRM=1` |
| `03_secrets.sql` | `DLT_DB.OPS.POSTGRES_APP_COPY` placeholder + READ/USAGE | `make setup-source SOURCE=postgres CONFIRM=1` |
| `apply_network.sh` | Renders + applies the host-only EAI (`$PGHOST:5432`, no `0.0.0.0/0`) and the SPCS ingress rule from `SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES()` | same, and re-runnable alone via `make setup-postgres-network CONFIRM=1` when the CIDRs rotate |
| `apply_secret.sh` | `ALTER SECRET ... SET SECRET_STRING` from `APP_COPY_WRITER_PASSWORD` | `make setup-postgres-secret CONFIRM=1` |

The rendered SQL lands in `.generated/*.sql` (gitignored). You cannot read a
Snowflake SECRET back; a successful `make run-postgres` is the test.

APP SELECT for the loader is a different file: `sql/sources/nfl/07_app_copy_grants.sql`.
