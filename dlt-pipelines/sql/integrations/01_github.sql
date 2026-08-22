-- =============================================================================
-- integrations/01_github.sql
-- Purpose : INTEGRATIONS.GITHUB plus the account-level GitHub API integration
--           Workspaces need to clone / push pronoiaLabs/weekend-warriors.
-- Run as  : SYSADMIN (owns the database), then ACCOUNTADMIN (the integration).
-- Apply   : make setup-integrations CONFIRM=1  (or snow sql -f)
--
-- THE API INTEGRATION IS NOT IN THIS DATABASE. CREATE API INTEGRATION is an
-- account-level object; Snowflake will not let you nest it under a schema.
-- INTEGRATIONS.GITHUB is the home for schema-scoped companions: a PAT secret
-- if you ever drop OAuth, and an optional GIT REPOSITORY clone for
-- EXECUTE IMMEDIATE FROM @repo. Workspaces "From Git repository" still uses
-- this integration by name and does its own OAuth sign-in.
--
-- Auth is the Snowflake GitHub App (snowflakedb), not a PAT and not Anaconda.
-- Do not pick "Public repository" in the Workspace dialog even if the repo is
-- public -- that path cannot push.
--
-- sql/** is not in deploy.yml. This does not run from CI.
-- =============================================================================

USE ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 1. Database and schema
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS INTEGRATIONS
    COMMENT = 'Account-level Git / Workspace credentials and clones. Not pipeline data.';

CREATE SCHEMA IF NOT EXISTS INTEGRATIONS.GITHUB
    COMMENT = 'GitHub secrets and optional GIT REPOSITORY clones. API integration is account-level.';

GRANT USAGE ON DATABASE INTEGRATIONS TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA INTEGRATIONS.GITHUB TO ROLE SYSADMIN;
GRANT CREATE SECRET ON SCHEMA INTEGRATIONS.GITHUB TO ROLE SYSADMIN;
GRANT CREATE GIT REPOSITORY ON SCHEMA INTEGRATIONS.GITHUB TO ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- 2. API integration (ACCOUNTADMIN)
--
-- IF NOT EXISTS on purpose. CREATE OR REPLACE drops USAGE grants and the
-- Workspace dialog then shows an empty integration list until this file is
-- re-applied. Prefix / comment changes are an ALTER, not a replace:
--
--     ALTER API INTEGRATION GITHUB_API_INT SET
--         API_ALLOWED_PREFIXES = ('https://github.com/pronoiaLabs');
--
-- Prefix is the org, not the repo, so a second pronoiaLabs repo can share it.
-- ---------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE API INTEGRATION IF NOT EXISTS GITHUB_API_INT
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/pronoiaLabs')
    API_USER_AUTHENTICATION = (TYPE = SNOWFLAKE_GITHUB_APP)
    ENABLED = TRUE
    COMMENT = 'Workspaces Git via the Snowflake GitHub App. Prefix: pronoiaLabs.';

-- The session role in Snowsight is SYSADMIN. Without this the integration is
-- invisible in the From Git repository dialog.
GRANT USAGE ON INTEGRATION GITHUB_API_INT TO ROLE SYSADMIN;

-- Optional SQL-side clone (not required for Workspaces). Private repos need a
-- PAT secret in INTEGRATIONS.GITHUB and GIT_CREDENTIALS on the clone; the
-- GitHub App OAuth flow does not attach to CREATE GIT REPOSITORY.
--
--     CREATE GIT REPOSITORY IF NOT EXISTS INTEGRATIONS.GITHUB.WEEKEND_WARRIORS
--         ORIGIN = 'https://github.com/pronoiaLabs/weekend-warriors.git'
--         API_INTEGRATION = GITHUB_API_INT
--         COMMENT = 'SQL fetch / EXECUTE IMMEDIATE FROM. Push stays in Workspaces.';
