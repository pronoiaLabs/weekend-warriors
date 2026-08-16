-- =============================================================================
-- prod/03b_service_user_oidc.sql
-- Purpose : Create a keyless CI/CD service account that authenticates with
--           GitHub Actions OIDC (workload identity federation), and give it a
--           user-level network policy so it can actually reach the account.
--           Recommended over key-pair (prod/03_service_user.sql): no secret is
--           stored anywhere, GitHub mints a short-lived token Snowflake validates.
-- Run as  : USERADMIN for the user, SECURITYADMIN for the network policy.
-- Prerequisites : base/01_roles.sql, base/02_control_plane.sql, prod/01_prod_db.sql,
--                 prod/02_compute.sql. (The deploy privileges CREATE TASK / EXECUTE
--                 TASK / registry DML are already granted to DLT_LOADER_ROLE in
--                 base/02 and base/03.)
--
-- Pairs with .github/workflows/deploy.yml at the REPO ROOT
-- (snowflakedb/snowflake-actions@v3, use-oidc: true).
-- =============================================================================

USE ROLE USERADMIN;

-- ---------------------------------------------------------------------------
-- 1. Keyless service user (workload identity = GitHub OIDC)
-- ---------------------------------------------------------------------------
-- SUBJECT must match the claim GitHub emits for your workflow. Pick the format
-- that matches how the deploy job is triggered:
--
--   repo:<owner>/<repo>:ref:refs/heads/main       -> push to main (no environment)
--   repo:<owner>/<repo>:pull_request              -> any pull_request event
--   repo:<owner>/<repo>:environment:<name>        -> job sets `environment: <name>`
--
-- deploy.yml targets the `deploy` GitHub environment, which is what lets you put
-- required reviewers in front of a production change, so the environment: form is
-- what is used here. Changing the workflow's `environment:` key without changing
-- this SUBJECT breaks authentication, and the error will say the token was
-- rejected rather than that the subject did not match.
CREATE USER IF NOT EXISTS DLT_DEPLOYER
    TYPE              = SERVICE
    DEFAULT_ROLE      = DLT_LOADER_ROLE
    DEFAULT_WAREHOUSE = DLT_WH
    DEFAULT_NAMESPACE = DLT_PROD_DB.RAW
    WORKLOAD_IDENTITY = (
        TYPE    = OIDC
        ISSUER  = 'https://token.actions.githubusercontent.com'
        SUBJECT = 'repo:pronoiaLabs/weekend-warriors:environment:deploy'
    )
    COMMENT = 'Keyless CI/CD deployer for dlt + dbt (GitHub Actions OIDC).';

GRANT ROLE DLT_LOADER_ROLE TO USER DLT_DEPLOYER;

-- ---------------------------------------------------------------------------
-- 1b. Deploy-job roles beyond ingestion
-- ---------------------------------------------------------------------------
-- deploy.yml's dbt/agents jobs run as DBT_RUNNER_ROLE (the prod dbt estate's
-- owner; job-level SNOWFLAKE_ROLE override) and the dashboard job switches to
-- OPS_DASHBOARD_ROLE for its one ALTER SERVICE statement (service ownership).
-- The user needs both granted, and DBT_RUNNER_ROLE needs to be able to
-- CREATE OR REPLACE the sport project objects it will own, plus USAGE on the
-- external access integration the deploy references in DDL.
--
-- Ownership of the sport objects is transferred once here; after that,
-- `make deploy-sport` normalizes ownership back to DBT_RUNNER_ROLE on every
-- deploy (laptop or CI), so the two paths never strand each other.
GRANT ROLE DBT_RUNNER_ROLE    TO USER DLT_DEPLOYER;
GRANT ROLE OPS_DASHBOARD_ROLE TO USER DLT_DEPLOYER;

USE ROLE SYSADMIN;
GRANT CREATE DBT PROJECT ON SCHEMA DLT_DB.DEPLOY TO ROLE DBT_RUNNER_ROLE;
GRANT OWNERSHIP ON DBT PROJECT DLT_DB.DEPLOY.CORTEX_LIFECYCLE_NFL
  TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON DBT PROJECT DLT_DB.DEPLOY.CORTEX_LIFECYCLE_NCAAF
  TO ROLE DBT_RUNNER_ROLE COPY CURRENT GRANTS;
-- (repeat for CORTEX_LIFECYCLE_WNBA when the sport is revived)

-- The integration was created ad-hoc (dbt-pipelines/README.md); verify with
-- SHOW GRANTS ON INTEGRATION DBT_EXT_ACCESS before assuming this is missing.
USE ROLE ACCOUNTADMIN;
GRANT USAGE ON INTEGRATION DBT_EXT_ACCESS TO ROLE DBT_RUNNER_ROLE;

-- ---------------------------------------------------------------------------
-- 2. Network policy: the part that is easy to miss
-- ---------------------------------------------------------------------------
-- WITHOUT THIS THE USER ABOVE AUTHENTICATES CORRECTLY AND STILL CANNOT CONNECT.
--
-- If your account has an account-level network policy with an IP allowlist (check
-- with `SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT`), GitHub-hosted runners
-- are not on it: they come from wide, weekly-rotating Azure ranges. Every deploy
-- fails with `Network policy is required` or an IP rejection. OIDC does not help
-- with this. Workload identity federation removes the stored credential, not the
-- network path, and there is no exemption for TYPE = SERVICE users. Nor is there a
-- network rule type that allowlists a federated identity: CREATE NETWORK RULE takes
-- IPs, VPC endpoint IDs and private link IDs, none of which a GitHub runner can
-- present.
--
-- What makes it work is that NETWORK POLICIES OVERRIDE, THEY DO NOT STACK:
--
--   "Network policies applied to a user override network policies applied to the
--    account, but are overridden by a network policy applied to a security
--    integration."
--   https://docs.snowflake.com/en/user-guide/network-policies
--
-- So attaching a policy to DLT_DEPLOYER REPLACES the account policy for that one
-- user. Every other user keeps the account policy unchanged. This is a scoped
-- exception, not a hole in the account.
--
-- WHY 0.0.0.0/0 RATHER THAN GITHUB'S PUBLISHED RANGES.
-- The `actions` key of https://api.github.com/meta is roughly four thousand CIDRs
-- that GitHub rotates weekly and explicitly tells you not to use as an allowlist.
-- Pinning them means a scheduled job to refresh this policy, and a deploy that
-- breaks without warning whenever that job lags. The IP layer would be theatre.
--
-- The control that replaces it is the SUBJECT claim above: a short-lived token
-- signed by GitHub, bound to this repository AND this environment, which an
-- attacker cannot mint without write access to the repo. Defence in depth comes
-- from DLT_LOADER_ROLE instead, which can reach DLT_DB and the NFL_* databases
-- and nothing else on the account.
--
-- IF YOU WANT THE IP LAYER BACK: run the deploy job on a self-hosted runner with a
-- fixed egress IP and put that single CIDR in ALLOWED_IP_LIST below. That is the
-- tighter posture and costs an always-on box. On a public repo, a self-hosted
-- runner must never accept `pull_request` jobs from forks.
USE ROLE SECURITYADMIN;

CREATE NETWORK POLICY IF NOT EXISTS DLT_DEPLOYER_POLICY
    ALLOWED_IP_LIST = ('0.0.0.0/0')
    COMMENT = 'CI deployer only. Overrides the account policy for this one service
               user; the control is the GitHub OIDC subject claim, not source IP.';

ALTER USER DLT_DEPLOYER SET NETWORK_POLICY = DLT_DEPLOYER_POLICY;

-- ---------------------------------------------------------------------------
-- 3. Verify
-- ---------------------------------------------------------------------------
-- The override is attached (expect DLT_DEPLOYER_POLICY, not the account policy):
--   SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN USER DLT_DEPLOYER;
--
-- After the first workflow run, confirm the login was federated rather than
-- blocked. A network rejection shows here as a failed login with an explicit
-- message, which is how you tell "policy did not take" from "subject mismatch":
--   SELECT event_timestamp, is_success, error_message, first_authentication_factor
--   FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
--   WHERE user_name = 'DLT_DEPLOYER' ORDER BY event_timestamp DESC LIMIT 10;
--
-- Note LOGIN_HISTORY in ACCOUNT_USAGE lags up to ~2 hours. For an immediate read
-- use the INFORMATION_SCHEMA table function instead:
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.LOGIN_HISTORY_BY_USER('DLT_DEPLOYER'));
