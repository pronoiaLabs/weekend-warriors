-- =============================================================================
-- sql/postgres/04_grant_admin_select.sql
-- Purpose : Let snowflake_admin (TablePlus / psql as the instance owner) see
--           tables app_copy_writer created. Default privileges in 02b only
--           granted SELECT to app_api, so the sidebar hid every mart.
-- Apply   : apply.sh as app_copy_writer (writer owns the marts)
-- =============================================================================

GRANT SELECT ON ALL TABLES IN SCHEMA app_copy TO snowflake_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA app_copy TO app_api;
