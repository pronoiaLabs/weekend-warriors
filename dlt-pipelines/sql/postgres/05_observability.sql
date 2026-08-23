-- =============================================================================
-- sql/postgres/05_observability.sql
-- Purpose : Schema observability on database app. Copies of DLT_DB.OPS
--           materialized tables land here; Snowflake itself is unchanged.
-- Apply   : make setup-postgres-observability CONFIRM=1
--           (also run by apply.sh after the APP schema so a fresh setup-postgres
--           gets both)
--
-- Reuses app_copy_writer / app_api. No new login, no new password.
-- No copy tables here. dlt creates those on the first obs_to_postgres run.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS observability;

GRANT USAGE, CREATE ON SCHEMA observability TO app_copy_writer;
GRANT USAGE         ON SCHEMA observability TO app_api;

-- Watermark is ours, not a dlt table. Do not reuse app_copy.app_copy_watermark
-- or DLT_DB.OPS.DBT_BUILDS: an obs run is not an NFL dbt build. source_ref is
-- a copy-job stamp (ISO timestamp), not a BUILD_ID. Fail the copy job if the
-- UPSERT after load cannot write here.
CREATE TABLE IF NOT EXISTS observability.observability_watermark (
  table_name  TEXT NOT NULL PRIMARY KEY,
  copied_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  row_count   BIGINT,
  source_ref  TEXT
);

GRANT SELECT, INSERT, UPDATE ON TABLE observability.observability_watermark
  TO app_copy_writer;
GRANT SELECT ON TABLE observability.observability_watermark TO app_api;
