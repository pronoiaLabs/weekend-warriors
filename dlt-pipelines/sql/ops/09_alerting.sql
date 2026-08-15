-- =============================================================================
-- ops/09_alerting.sql
-- =============================================================================
-- Purpose       : Slack delivery for in-process failure alerts: one webhook
--                 NOTIFICATION INTEGRATION, the SECRET behind it, and the
--                 shared ALERT_STATE table that turns raw failures into
--                 transition pings (healthy->failing once, recovery once).
-- Run as        : SYSADMIN (secret), then ACCOUNTADMIN (integration + USAGE
--                 grants), then DLT_LOADER_ROLE (state table + DML grants).
-- Prerequisites : base/01_roles.sql, base/02_control_plane.sql,
--                 base/04_dbt_runner.sql. Nothing here depends on ops/01..08.
-- Apply         : make setup-ops CONFIRM=1  (or snow sql -f directly)
--
-- WHO SENDS, AND FROM WHERE. Alerting is IN-PROCESS, not a sweep: the thing
-- that fails is the thing that pings.
--   * pipelines/common/alerts.py -- called by pipelines/batch/run.py around
--     every pipeline run (and around registry resolution, the early-death
--     class _DLT_RUNS never sees). Runs as DLT_LOADER_ROLE in the prod
--     containers; gated on the DLT_ALERTS env var, which only the prod job
--     template sets.
--   * SP_DBT_BUILD's EXCEPTION handler (sql/sources/<sport>/05_dbt_trigger
--     .sql). Runs as DBT_RUNNER_ROLE from the triggered tasks.
-- Both send with SYSTEM$SEND_SNOWFLAKE_NOTIFICATION over their existing
-- Snowflake session, so no container gets Slack egress or the webhook secret.
-- Accepted v1 gaps, knowingly: a container that never starts, and a schedule
-- that is dead without failing. Nothing in-process can see either.
--
-- THE SECRET HOLDS THE PATH, NOT THE URL. Snowflake allowlists webhook hosts
-- per provider; for Slack the URL must literally start with
-- https://hooks.slack.com/services/ and the SNOWFLAKE_WEBHOOK_SECRET
-- placeholder substitutes the bound secret into it at send time. So the
-- secret's value is ONLY the part after /services/ (T.../B.../x...), never
-- the full URL. The placeholder value below is deliberately unusable; set the
-- real one out-of-band (never in a file that reaches git):
--
--   ALTER SECRET DLT_DB.OPS.SLACK_ALERTS_WEBHOOK
--     SET SECRET_STRING = '<Txxx/Bxxx/xxxx from the real webhook URL>';
--
-- TASK SESSIONS RUN THE OWNER'S PRIMARY ROLE ALONE (the lesson ops/01 paid
-- for), so the USAGE grants below are load-bearing: proving a send works as
-- an interactive SYSADMIN says nothing about whether DBT_RUNNER_ROLE can do
-- it from a task. Smoke-test the send as each worker role before shipping
-- code that depends on it:
--
--   USE ROLE DLT_LOADER_ROLE;  -- then again as DBT_RUNNER_ROLE
--   CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
--     SNOWFLAKE.NOTIFICATION.TEXT_PLAIN(
--       SNOWFLAKE.NOTIFICATION.SANITIZE_WEBHOOK_CONTENT(
--         'smoke: weekend-warriors alerting path')),
--     SNOWFLAKE.NOTIFICATION.INTEGRATION('SLACK_ALERTS_INT'));
--
-- Delivery is ASYNC: the CALL returning 'Enqueued notifications' proves
-- nothing reached Slack. Verify in the channel, and/or:
--
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.NOTIFICATION_HISTORY(
--     RESULT_LIMIT => 20)) ORDER BY CREATED DESC;   -- 14-day lookback max
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: the webhook secret (SYSADMIN, like the per-sport API keys in
-- sql/sources/<sport>/03_secrets.sql)
-- -----------------------------------------------------------------------------

USE ROLE SYSADMIN;

-- IF NOT EXISTS so a re-apply never clobbers the real value back to the
-- placeholder (03_secrets.sql precedent). The placeholder MUST be shaped like
-- a real Slack path (T.../B.../x...): CREATE NOTIFICATION INTEGRATION below
-- validates the URL WITH the secret substituted, and a free-text placeholder
-- fails it with "WEBHOOK_URL ... is invalid. Verify whether secret
-- replacement makes it invalid" (found live, 2026-08-15 -- this is why the
-- Snowflake docs' example secret uses exactly this dummy shape).
CREATE SECRET IF NOT EXISTS DLT_DB.OPS.SLACK_ALERTS_WEBHOOK
  TYPE = GENERIC_STRING
  SECRET_STRING = 'T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX'
  COMMENT = 'Slack incoming-webhook path (the part after /services/), substituted into SLACK_ALERTS_INT via SNOWFLAKE_WEBHOOK_SECRET. Value set out-of-band by ALTER SECRET.';

-- READ is what SYSTEM$SEND_SNOWFLAKE_NOTIFICATION needs on the bound secret;
-- USAGE rides along per the 03_secrets.sql precedent (both grants, so the
-- secret can also be referenced by name where object references require it).
GRANT READ, USAGE ON SECRET DLT_DB.OPS.SLACK_ALERTS_WEBHOOK TO ROLE DLT_LOADER_ROLE;
GRANT READ, USAGE ON SECRET DLT_DB.OPS.SLACK_ALERTS_WEBHOOK TO ROLE DBT_RUNNER_ROLE;

-- -----------------------------------------------------------------------------
-- Section 2: the notification integration (ACCOUNTADMIN: CREATE INTEGRATION
-- is account-level, same split as sql/sources/<sport>/02_external_access.sql)
-- -----------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

-- OR REPLACE, unlike the secret: the integration carries no out-of-band
-- state, so re-applying this file is how its shape (template, headers) is
-- updated. The secret it points at survives untouched.
CREATE OR REPLACE NOTIFICATION INTEGRATION SLACK_ALERTS_INT
  TYPE = WEBHOOK
  ENABLED = TRUE
  WEBHOOK_URL = 'https://hooks.slack.com/services/SNOWFLAKE_WEBHOOK_SECRET'
  WEBHOOK_SECRET = DLT_DB.OPS.SLACK_ALERTS_WEBHOOK
  WEBHOOK_BODY_TEMPLATE = '{"text": "SNOWFLAKE_WEBHOOK_MESSAGE"}'
  WEBHOOK_HEADERS = ('Content-Type' = 'application/json')
  COMMENT = 'Failure/recovery pings from the dlt runner and the SP_DBT_BUILD procs. Senders: DLT_LOADER_ROLE, DBT_RUNNER_ROLE.';

GRANT USAGE ON INTEGRATION SLACK_ALERTS_INT TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON INTEGRATION SLACK_ALERTS_INT TO ROLE DBT_RUNNER_ROLE;

-- -----------------------------------------------------------------------------
-- Section 3: transition state (DLT_LOADER_ROLE owns it, like the other ops
-- tables; DBT_RUNNER_ROLE gets the DML a MERGE needs)
-- -----------------------------------------------------------------------------

USE ROLE DLT_LOADER_ROLE;

-- One row per alert scope, latest state only -- this is a dedup latch, not a
-- history (TASK_HISTORY and _DLT_RUNS already hold the history). A scope is
-- a pipeline name ('nfl_stats'), 'dbt_build_<sport>', or 'runner' (deaths
-- before a pipeline is even resolved). The ping rule both senders implement:
-- failure pings only when STATUS was not already 'failing'; success pings
-- only when it was. Everything else just updates the row.
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.ALERT_STATE (
  SCOPE           VARCHAR NOT NULL,
  STATUS          VARCHAR NOT NULL,          -- 'ok' | 'failing'
  UPDATED_AT      TIMESTAMP_TZ,
  LAST_ALERTED_AT TIMESTAMP_TZ,              -- last time a ping was actually sent
  LAST_ERROR      VARCHAR,                   -- truncated; full text is in TASK_HISTORY
  CONSTRAINT PK_ALERT_STATE PRIMARY KEY (SCOPE)
)
COMMENT = 'Latch for transition-based Slack alerts: ping on healthy->failing and on recovery, silence in between. Written by alerts.py (DLT_LOADER_ROLE) and SP_DBT_BUILD (DBT_RUNNER_ROLE).';

GRANT SELECT, INSERT, UPDATE ON TABLE DLT_DB.OPS.ALERT_STATE TO ROLE DBT_RUNNER_ROLE;
