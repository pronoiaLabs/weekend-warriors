# Snowflake Postgres init

Statements live in this directory. Do not invent `psql -c` one-liners.

| File | What it does | Applied by |
|---|---|---|
| `01_create_database.sql` | `CREATE DATABASE app` | `apply.sh` (skipped if `app` exists) |
| `02_app_copy.sql` | schema `app_copy`, roles, watermark table. No copy tables, no `app_state` | `apply.sh` |
| `02b_default_privileges.sql` | writer-created tables are SELECT to `app_api` and `snowflake_admin` | `apply.sh` |
| `04_grant_admin_select.sql` | SELECT on tables that already exist (TablePlus as admin) | `apply.sh` |
| `03_set_writer_password.sql.example` | documents the only statement that cannot be committed with a real password | rendered to `.generated/` |
| `apply.sh` | applies the three in order from repo-root `.env.postgres` | `make setup-postgres CONFIRM=1` |

`.generated/` is gitignored. Full runbook: [MAKE-COMMANDS-POSTGRES.md](../../MAKE-COMMANDS-POSTGRES.md).
