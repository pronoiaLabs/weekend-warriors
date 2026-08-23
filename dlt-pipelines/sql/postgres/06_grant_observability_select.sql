-- =============================================================================
-- sql/postgres/06_grant_observability_select.sql
-- Purpose : SELECT on tables that already exist in observability (TablePlus
--           as admin; app_api). Default privileges in 05b only cover tables
--           created after they were recorded.
-- Apply   : apply_observability.sh as app_copy_writer (writer owns the copies)
-- =============================================================================

GRANT SELECT ON ALL TABLES IN SCHEMA observability TO snowflake_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA observability TO app_api;
