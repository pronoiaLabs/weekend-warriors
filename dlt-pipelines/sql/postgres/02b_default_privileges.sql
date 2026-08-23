-- =============================================================================
-- sql/postgres/02b_default_privileges.sql
-- Purpose : Tables app_copy_writer creates (the dlt replace-loads) are
--           SELECT-able by app_api.
-- Apply   : apply.sh connects AS app_copy_writer (Snowflake Postgres denies
--           SET ROLE to that login from the admin session).
-- =============================================================================

ALTER DEFAULT PRIVILEGES IN SCHEMA app_copy
  GRANT SELECT ON TABLES TO app_api, snowflake_admin;
