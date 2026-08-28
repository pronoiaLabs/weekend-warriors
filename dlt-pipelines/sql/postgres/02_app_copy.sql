-- =============================================================================
-- sql/postgres/02_app_copy.sql
-- Purpose : Shared catalog schema + the role dlt uses to replace-load it.
-- Apply   : make setup-postgres   (connects as snowflake_admin to /app)
--
-- No copy tables here. dlt creates those on the first nfl_app_to_postgres run.
-- No app_state. Identity / RLS is a later pass.
--
-- app_copy_writer is created LOGIN with no password. make setup-postgres then
-- applies 03_set_writer_password.sql (gitignored, generated from
-- APP_COPY_WRITER_PASSWORD in the repo-root .env.postgres).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS app_copy;

DO $$
BEGIN
  CREATE ROLE app_copy_writer;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;

ALTER ROLE app_copy_writer WITH LOGIN;

DO $$
BEGIN
  CREATE ROLE app_api;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;

ALTER ROLE app_api WITH LOGIN;

REVOKE ALL ON DATABASE postgres FROM PUBLIC;
REVOKE ALL ON DATABASE app      FROM PUBLIC;

GRANT CONNECT ON DATABASE app TO snowflake_admin, app_copy_writer, app_api;

GRANT USAGE, CREATE ON SCHEMA app_copy TO app_copy_writer;
GRANT USAGE         ON SCHEMA app_copy TO app_api;

-- Membership is required for 02b (a new session: GRANT is not usable until reconnect).
GRANT app_copy_writer TO CURRENT_USER;

-- Do not ALTER ROLE ... SET search_path. Snowflake Postgres denies it without
-- CREATEROLE + ADMIN on the role. dlt targets schema app_copy via DLT_DATASET;
-- the watermark UPSERT is schema-qualified.

-- Watermark is ours, not a dlt table. dlt replace-loads the APP marts; this
-- row records which dbt build those copies came from. Fail the copy job if
-- the UPSERT after load cannot write here.
CREATE TABLE IF NOT EXISTS app_copy.app_copy_watermark (
  sport            TEXT NOT NULL,
  table_name       TEXT NOT NULL,
  source_build_id  TEXT,
  copied_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  row_count        BIGINT,
  content_hash     TEXT,
  PRIMARY KEY (sport, table_name)
);

-- CREATE TABLE IF NOT EXISTS does not add columns to an existing installation.
ALTER TABLE app_copy.app_copy_watermark
  ADD COLUMN IF NOT EXISTS content_hash TEXT;

GRANT SELECT, INSERT, UPDATE ON TABLE app_copy.app_copy_watermark TO app_copy_writer;
GRANT SELECT                 ON TABLE app_copy.app_copy_watermark TO app_api;
