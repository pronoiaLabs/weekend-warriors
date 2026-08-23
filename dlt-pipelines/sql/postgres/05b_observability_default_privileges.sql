-- =============================================================================
-- sql/postgres/05b_observability_default_privileges.sql
-- Purpose : Tables app_copy_writer creates in observability (the dlt
--           replace-loads) are SELECT-able by app_api and snowflake_admin.
-- Apply   : apply_observability.sh connects AS app_copy_writer (Snowflake
--           Postgres denies SET ROLE to that login from the admin session).
-- =============================================================================

ALTER DEFAULT PRIVILEGES IN SCHEMA observability
  GRANT SELECT ON TABLES TO app_api, snowflake_admin;
