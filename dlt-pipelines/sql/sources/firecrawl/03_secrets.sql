-- =============================================================================
-- sources/firecrawl/03_secrets.sql
-- Purpose : Snowflake SECRET holding the Firecrawl API key, mounted into SPCS jobs
--           as an environment variable so the key is in neither the image nor git.
-- Run as  : SYSADMIN (owns DLT_DB.OPS). Grant READ + USAGE to the job roles.
-- Prerequisites : base/01_roles.sql (roles), base/02_control_plane.sql (DLT_DB.OPS).
--
-- Applied by: make setup-source SOURCE=firecrawl CONFIRM=1
--
-- This is a DIFFERENT VENDOR from the BallDontLie secrets beside it. One Firecrawl
-- key serves any sport's news pipeline, which is why the secret is named for the
-- vendor rather than for a league, and why there is one of it.
--
-- HOW THE NAME IS CHOSEN. The container binds this secret to an env var, and dlt
-- resolves a `secret:<dotted.path>` value in the registry config from that env var
-- by uppercasing the path and replacing dots with double underscores:
--
--     registry config : api_key: "secret:sources.firecrawl.api_key"
--     env var         : SOURCES__FIRECRAWL__API_KEY
--     dev run         : make run-spcs NAME=nfl_news   (secret/env var/EAI read from
--                       the registry entry's `secret`, `env_var`, `external_access`)
--
-- Local runs do not need this file: dlt reads .dlt/secrets.toml or the shell env.
-- =============================================================================

USE ROLE SYSADMIN;

-- THE CREATE BELOW DOES NOT SET A USABLE KEY, AND CANNOT.
--
-- `IF NOT EXISTS` means this statement is a no-op forever after the first run, so
-- whatever value it writes is pinned until somebody runs the ALTER. Re-running this
-- file does not fix a wrong key; it silently does nothing. The object still has to be
-- created here because the GRANTs at the bottom need it to exist.
--
-- The placeholder is deliberately not key-shaped. A plausible-looking dummy fails at
-- the API with a 401 that reads like an expired credential; this one is obviously
-- unset the moment anyone looks at it.
CREATE SECRET IF NOT EXISTS DLT_DB.OPS.FIRECRAWL_API_KEY
    TYPE          = GENERIC_STRING
    SECRET_STRING = 'UNSET-RUN-THE-ALTER-BELOW'
    COMMENT       = 'API key for the Firecrawl news source (pipelines/batch/firecrawl_source.py). Set via ALTER.';

-- REQUIRED, every time this file is applied to a new account. Not optional, not a
-- follow-up: no pipeline that touches Firecrawl works until this runs.
--
--     ALTER SECRET DLT_DB.OPS.FIRECRAWL_API_KEY SET SECRET_STRING = '<the real key>';
--
-- A secret's value cannot be read back, so there is no query that proves it is right.
-- The only test is a run: `make run-spcs NAME=nfl_news` scrapes with a good key and
-- fails with a 401 from api.firecrawl.dev otherwise.

-- Both roles run SPCS jobs that resolve this secret. READ is the grant that mounts a
-- secret into a container; USAGE alone fails at EXECUTE JOB SERVICE with "does not
-- exist or not authorized". See sources/nfl/03_secrets.sql for the full account.
GRANT READ  ON SECRET DLT_DB.OPS.FIRECRAWL_API_KEY TO ROLE DLT_DEV_ROLE;
GRANT READ  ON SECRET DLT_DB.OPS.FIRECRAWL_API_KEY TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON SECRET DLT_DB.OPS.FIRECRAWL_API_KEY TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON SECRET DLT_DB.OPS.FIRECRAWL_API_KEY TO ROLE DLT_LOADER_ROLE;
