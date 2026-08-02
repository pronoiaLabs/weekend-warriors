-- =============================================================================
-- base/02_control_plane.sql
-- Purpose : Create the SHARED control-plane database DLT_DB and its schemas,
--           plus the SPCS image repository. DLT_DB holds no pipeline data -- it
--           is the shared control plane for BOTH prod and dev:
--             * OPS     -- PIPELINE_REGISTRY (created in base/03)
--             * DEPLOY  -- image repository + spec-template stage (created in base/03)
--           Pipeline DATA lives in DLT_PROD_DB (prod/) and DLT_DEV_DB (dev/).
-- Run as  : SYSADMIN (owns DLT_DB and all objects/grants below). One small
--           ACCOUNTADMIN block at the end grants the account-level EXECUTE TASK
--           privilege, which SYSADMIN cannot grant itself.
-- Prerequisites : base/01_roles.sql (DLT_LOADER_ROLE + DLT_DEV_ROLE).
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Control-plane database and schemas
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS DLT_DB
    COMMENT = 'Shared control plane for dlt pipelines (registry, image repo, spec stage). No pipeline data.';

-- OPS    : control tables, primarily OPS.PIPELINE_REGISTRY (base/03).
CREATE SCHEMA IF NOT EXISTS DLT_DB.OPS
    COMMENT = 'Control-plane metadata: PIPELINE_REGISTRY.';

-- DEPLOY : SPCS image repository and the job spec-template stage.
CREATE SCHEMA IF NOT EXISTS DLT_DB.DEPLOY
    COMMENT = 'Deployment artefacts: SPCS image repository and spec-template stage.';

-- ---------------------------------------------------------------------------
-- 2. SPCS image repository (shared by prod and dev jobs)
-- ---------------------------------------------------------------------------
CREATE IMAGE REPOSITORY IF NOT EXISTS DLT_DB.DEPLOY.IMAGES
    COMMENT = 'Stores the dlt container image for SPCS job runs (prod + dev).';

-- ---------------------------------------------------------------------------
-- 3. Control-plane grants (shared by both roles)
-- ---------------------------------------------------------------------------
-- Both roles need to see the control-plane DB/schemas, pull the image, and
-- create job services in DEPLOY. Registry SELECT + stage READ are granted in
-- base/03 once those objects exist.

-- Database + schema visibility.
GRANT USAGE ON DATABASE DLT_DB TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON DATABASE DLT_DB TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.OPS    TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.OPS    TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.DEPLOY TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON SCHEMA DLT_DB.DEPLOY TO ROLE DLT_DEV_ROLE;

-- Image repository: both roles pull (READ) the image for their job services;
-- only the deploy role pushes (WRITE) new image versions.
GRANT READ  ON IMAGE REPOSITORY DLT_DB.DEPLOY.IMAGES TO ROLE DLT_LOADER_ROLE;
GRANT READ  ON IMAGE REPOSITORY DLT_DB.DEPLOY.IMAGES TO ROLE DLT_DEV_ROLE;
GRANT WRITE ON IMAGE REPOSITORY DLT_DB.DEPLOY.IMAGES TO ROLE DLT_LOADER_ROLE;

-- EXECUTE JOB SERVICE creates a job-service object in DEPLOY. Both prod Tasks
-- and dev ad-hoc runs create their job services here.
GRANT CREATE SERVICE ON SCHEMA DLT_DB.DEPLOY TO ROLE DLT_LOADER_ROLE;
GRANT CREATE SERVICE ON SCHEMA DLT_DB.DEPLOY TO ROLE DLT_DEV_ROLE;

-- AND ON OPS, WHICH IS NOT A DUPLICATE OF THE LINE ABOVE.
--
-- A scheduled Task creates its job service in whatever schema the session is in, and a
-- Task's session is the schema the Task itself lives in: DLT_DB.OPS. The generated DDL
-- deliberately omits `NAME =` (a completed job service lingers 30 days, so a fixed
-- name collides on the second run), which means it cannot redirect the service to
-- DEPLOY either. So OPS needs the grant.
--
-- Without it the Task fails with "Insufficient privileges to operate on schema 'OPS'",
-- which points at the schema rather than at the missing privilege and reads like the
-- Task itself is unauthorised.
--
-- DEPLOY keeps its grant because the dev path still names its services explicitly:
-- `make run-spcs` creates DLT_DB.DEPLOY.dlt_dev_<pipeline>.
GRANT CREATE SERVICE ON SCHEMA DLT_DB.OPS TO ROLE DLT_LOADER_ROLE;

-- Prod scheduling: the deploy role creates Tasks in OPS (SYSADMIN owns the
-- schema, so it can grant CREATE TASK).
GRANT CREATE TASK ON SCHEMA DLT_DB.OPS TO ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 4. Account-level grant (ACCOUNTADMIN required)
-- ---------------------------------------------------------------------------
-- EXECUTE TASK is an account-level privilege that SYSADMIN cannot grant. This is
-- the only ACCOUNTADMIN step in the control plane.
USE ROLE ACCOUNTADMIN;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE DLT_LOADER_ROLE;
