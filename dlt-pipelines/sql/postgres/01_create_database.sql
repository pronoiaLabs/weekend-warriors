-- =============================================================================
-- sql/postgres/01_create_database.sql
-- Purpose : Create the app database on the Snowflake Postgres instance.
-- Apply   : make setup-postgres   (connects as snowflake_admin to /postgres)
--
-- Does NOT create schemas or roles. Those are 02_app_copy.sql against /app.
-- Does NOT create app_state. That is a later pass.
-- =============================================================================

CREATE DATABASE app;
