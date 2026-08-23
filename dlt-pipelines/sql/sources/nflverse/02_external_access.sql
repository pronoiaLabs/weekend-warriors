-- nflverse: egress for the SPCS job containers that run the nflverse source.
--
-- nflreadpy downloads each dataset from a GitHub release
-- (github.com/nflverse/nflverse-data/releases/download/...), which answers with a
-- 302 to release-assets.githubusercontent.com (older assets: objects.githubusercontent.com).
-- All three hosts must be in the rule or the redirect is the failure. No secret: the
-- files are public, so there is no 03_secrets.sql for this source and the task
-- generator selects the nosecret job template.
--
-- Apply with: make setup-source SOURCE=nflverse CONFIRM=1
-- sql/** is outside deploy.yml on purpose; this runs as ACCOUNTADMIN by a human.

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE DLT_DB.OPS.NFLVERSE_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = (
        'github.com:443',
        'release-assets.githubusercontent.com:443',
        'objects.githubusercontent.com:443'
    )
    COMMENT  = 'HTTPS egress for the nflverse source: GitHub release assets via nflreadpy.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION NFLVERSE_EAI
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.NFLVERSE_EGRESS)
    ENABLED = TRUE
    COMMENT = 'External access for dlt SPCS jobs running the nflverse source.';

GRANT USAGE ON INTEGRATION NFLVERSE_EAI TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON INTEGRATION NFLVERSE_EAI TO ROLE DLT_LOADER_ROLE;
