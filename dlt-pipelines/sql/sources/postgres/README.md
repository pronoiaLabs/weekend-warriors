# Postgres source objects (Snowflake side)

These files grant the copy job egress and a password secret. They do **not**
create `POSTGRES_DEV_DB` / `POSTGRES_PROD_DB` — the destination is the
Snowflake Postgres instance, not a Snowflake database.

| File | What it does | Applied by |
|---|---|---|
| `02_external_access.sql` | Host-only EAI to the Postgres instance `:5432`. No `0.0.0.0/0` | `make setup-source SOURCE=postgres CONFIRM=1` |
| `03_secrets.sql` | `DLT_DB.OPS.POSTGRES_APP_COPY` placeholder + READ/USAGE | same |
| `04_ingress_spcs.sql` | `POSTGRES_INGRESS` rule for Snowflake egress CIDRs (SPCS source IPs) | same |
| `apply_secret.sh` | `ALTER SECRET ... SET SECRET_STRING` from `APP_COPY_WRITER_PASSWORD` | `make setup-postgres-secret CONFIRM=1` |

The ALTER is written to `.generated/03_set_secret.sql` (gitignored). You cannot
read a Snowflake SECRET back; a successful `make run-postgres` is the test.

APP SELECT for the loader is a different file: `sql/sources/nfl/07_app_copy_grants.sql`.
