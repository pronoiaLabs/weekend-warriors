-- =============================================================================
-- sources/nfl/03_secrets.sql
-- Purpose : Snowflake SECRET objects that an SPCS job mounts as environment
--           variables, keeping API tokens out of the image and out of git.
-- Run as  : SYSADMIN (owns DLT_DB.OPS). Grant USAGE to the job roles.
-- Prerequisites : base/01_roles.sql (roles), base/02_control_plane.sql (DLT_DB.OPS).
--
-- Applied by: make setup-source SOURCE=nfl CONFIRM=1
--
-- The secret OBJECT lives in the DLT_DB control plane, shared across environments,
-- but its definition belongs to one source. Keeping it here means adopting this repo
-- for a different API is a new directory rather than an edit to shared DDL.
--
-- HOW THE NAME IS CHOSEN. The container binds this secret to an env var, and dlt
-- resolves a `secret:<dotted.path>` value in the registry config from that env var
-- by uppercasing the path and replacing dots with double underscores:
--
--     registry config : api_key: "secret:sources.nfl.api_key"
--     env var         : SOURCES__NFL__API_KEY
--     dev run         : make run-spcs NAME=nfl_reference \
--                         SECRET=DLT_DB.OPS.NFL_API_KEY \
--                         ENVVAR=SOURCES__NFL__API_KEY \
--                         EAI=NFL_API_EAI
--
-- Both job templates bind this secret. In dev the binding comes from `make run-spcs`,
-- which now reads the `secret` and `env_var` fields off the registry entry rather than
-- making you type them; in prod it comes from the same fields via
-- deploy/tasks/generate_tasks.py. One record of the fact, two consumers.
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
CREATE SECRET IF NOT EXISTS DLT_DB.OPS.NFL_API_KEY
    TYPE          = GENERIC_STRING
    SECRET_STRING = 'UNSET-RUN-THE-ALTER-BELOW'
    COMMENT       = 'API key for the BallDontLie NFL rest_api source. Set via ALTER.';

-- REQUIRED, every time this file is applied to a new account. Not optional, not a
-- follow-up: no pipeline that touches the API works until this runs.
--
--     ALTER SECRET DLT_DB.OPS.NFL_API_KEY SET SECRET_STRING = '<the real key>';
--
-- A secret's value cannot be read back, so there is no query that proves it is right.
-- The only test is a run: `make run-spcs NAME=nfl_reference` returns 32 teams with a
-- good key and fails with a 401 otherwise.

-- Both roles run SPCS jobs that resolve this secret.
--
-- READ IS THE ONE THAT MATTERS, AND USAGE IS NOT A SUBSTITUTE FOR IT.
--   Mounting a secret into a container (the `secrets:` block in the job spec, with
--   snowflakeSecret / secretKeyRef / envVarName) reads the secret value, and that
--   needs READ. USAGE only permits *referencing* the secret, as an external access
--   integration or a UDF does, without seeing its contents.
--
--   Granting USAGE alone fails at EXECUTE JOB SERVICE time, before the container
--   starts, with:
--       SECRET '<name>' does not exist or not authorized. Your primary role <role>
--       must have READ granted on SECRET <name>.
--
--   Note "does not exist or not authorized": a missing grant and a missing secret
--   produce the same message, so do not go looking for a typo in the name first.
--   SHOW GRANTS ON SECRET <name> answers it directly.
--
--   Both are granted below. USAGE is not required by the container path, but it is
--   what an EAI with ALLOWED_AUTHENTICATION_SECRETS would need, and keeping it costs
--   nothing.
GRANT READ  ON SECRET DLT_DB.OPS.NFL_API_KEY TO ROLE DLT_DEV_ROLE;
GRANT READ  ON SECRET DLT_DB.OPS.NFL_API_KEY TO ROLE DLT_LOADER_ROLE;
GRANT USAGE ON SECRET DLT_DB.OPS.NFL_API_KEY TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON SECRET DLT_DB.OPS.NFL_API_KEY TO ROLE DLT_LOADER_ROLE;
