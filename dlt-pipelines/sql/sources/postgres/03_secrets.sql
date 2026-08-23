-- =============================================================================
-- sources/postgres/03_secrets.sql
-- Purpose : Snowflake SECRET for the app_copy_writer password. The SPCS job
--           binds it to DESTINATION__POSTGRES__CREDENTIALS__PASSWORD.
-- Run as  : SYSADMIN
-- Apply   : make setup-source SOURCE=postgres CONFIRM=1
--
-- Then, every time on a new account (this CREATE does not set a usable value):
--
--   ALTER SECRET DLT_DB.OPS.POSTGRES_APP_COPY
--     SET SECRET_STRING = '<APP_COPY_WRITER_PASSWORD from .env.postgres>';
--
-- make setup-postgres-secret applies that ALTER from the env file so you do
-- not have to type it. The ALTER is also written to
-- sql/sources/postgres/.generated/03_set_secret.sql (gitignored).
-- =============================================================================

USE ROLE SYSADMIN;

CREATE SECRET IF NOT EXISTS DLT_DB.OPS.POSTGRES_APP_COPY
    TYPE          = GENERIC_STRING
    SECRET_STRING = 'UNSET-RUN-THE-ALTER-BELOW'
    COMMENT       = 'Password for Postgres role app_copy_writer. Set via ALTER.';

GRANT READ  ON SECRET DLT_DB.OPS.POSTGRES_APP_COPY TO ROLE DLT_DEV_ROLE;
GRANT READ  ON SECRET DLT_DB.OPS.POSTGRES_APP_COPY TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON SECRET DLT_DB.OPS.POSTGRES_APP_COPY TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON SECRET DLT_DB.OPS.POSTGRES_APP_COPY TO ROLE DLT_LOADER_ROLE;
