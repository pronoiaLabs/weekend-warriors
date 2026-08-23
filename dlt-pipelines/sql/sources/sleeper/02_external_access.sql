-- Sleeper: egress for the SPCS job containers that run the sleeper source.
--
-- Two hosts. api.sleeper.app/v1 is the documented API (state, players, trending);
-- api.sleeper.com (no /v1) serves the weekly stats and projections the Sleeper app
-- itself reads. No secret: the API is public and unauthenticated, so there is no
-- 03_secrets.sql for this source and the task generator selects the nosecret job
-- template.
--
-- Apply with: make setup-source SOURCE=sleeper CONFIRM=1
-- sql/** is outside deploy.yml on purpose; this runs as ACCOUNTADMIN by a human.

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE DLT_DB.OPS.SLEEPER_API_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = (
        'api.sleeper.app:443',
        'api.sleeper.com:443'
    )
    COMMENT  = 'HTTPS egress for the sleeper source: documented v1 API and the stats/projections host.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION SLEEPER_API_EAI
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.SLEEPER_API_EGRESS)
    ENABLED = TRUE
    COMMENT = 'External access for dlt SPCS jobs running the sleeper source.';

GRANT USAGE ON INTEGRATION SLEEPER_API_EAI TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON INTEGRATION SLEEPER_API_EAI TO ROLE DLT_LOADER_ROLE;
