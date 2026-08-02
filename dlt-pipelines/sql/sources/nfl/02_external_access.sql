-- =============================================================================
-- sources/nfl/02_external_access.sql
-- Purpose : Allow SPCS jobs to reach an EXTERNAL REST API. A container has no
--           network egress by default, so any rest_api pipeline needs an
--           External Access Integration -- in dev AND in prod.
-- Run as  : ACCOUNTADMIN (network rule + integration), then grant usage.
-- Prerequisites : base/01_roles.sql (roles), base/02_control_plane.sql (DLT_DB.OPS).
--
-- This lives in sources/<name>/ rather than base/ because it is the OPPOSITE of
-- shared: the host list, the integration name and the secret below are specific to
-- one upstream API. They sat in base/ once, which meant `make setup-base` handed
-- every adopter a BallDontLie integration whether they wanted one or not.
--
-- The OBJECTS are still account-level and shared between environments: one EAI
-- serves both DLT_DEV_ROLE and DLT_LOADER_ROLE. It is the definition that belongs
-- to a source, not the scope.
--
-- The port is REQUIRED in VALUE_LIST; a bare hostname is not enough. List every
-- host the source touches, including any auth or CDN host it redirects to.
--
-- Usage:
--   dev  : make run-spcs NAME=<pipeline>   (EAI read from the registry)
--   prod : the generated Task carries an EXTERNAL_ACCESS_INTEGRATIONS clause, emitted
--          by deploy/tasks/generate_tasks.py from the registry's `external_access`
--          field. The clause must sit BEFORE `FROM` in EXECUTE JOB SERVICE; placing
--          it after the template file is a SQL compilation error.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE DLT_DB.OPS.NFL_API_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = ('api.balldontlie.io:443')
    COMMENT  = 'HTTPS egress for the BallDontLie NFL rest_api source.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION NFL_API_EAI
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.NFL_API_EGRESS)
    ENABLED = TRUE
    COMMENT = 'External access for dlt SPCS jobs loading the NFL API.';

-- Both roles create SPCS jobs: DLT_DEV_ROLE via `make run-spcs`, DLT_LOADER_ROLE
-- via the scheduled Tasks.
GRANT USAGE ON INTEGRATION NFL_API_EAI TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON INTEGRATION NFL_API_EAI TO ROLE DLT_LOADER_ROLE;
