-- =============================================================================
-- prod/03_service_user.sql
-- Purpose : Create the DLT_LOADER service account and configure key-pair
--           authentication for connector / external (non-SPCS) use.
-- Run as  : USERADMIN (least-privilege admin for users; owns DLT_LOADER_ROLE so
--           it can grant it to the user).
-- Prerequisites : base/01_roles.sql, prod/01_prod_db.sql, prod/02_compute.sql
--                 (role + database + warehouse references must already exist).
-- =============================================================================

USE ROLE USERADMIN;

-- ---------------------------------------------------------------------------
-- 1. Service user
-- ---------------------------------------------------------------------------
CREATE USER IF NOT EXISTS DLT_LOADER
    DEFAULT_ROLE      = DLT_LOADER_ROLE
    DEFAULT_WAREHOUSE = DLT_WH
    DEFAULT_NAMESPACE = DLT_PROD_DB.RAW
    COMMENT           = 'Service account for production dlt pipeline runs.';

GRANT ROLE DLT_LOADER_ROLE TO USER DLT_LOADER;

-- ---------------------------------------------------------------------------
-- 2. Key-pair authentication  (for connector / external runs)
-- ---------------------------------------------------------------------------
-- Generate a 2048-bit RSA key pair locally:
--
--   openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out rsa_key.p8
--   openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
--
-- Then strip the PEM header/footer from rsa_key.pub and paste the base64 body
-- (no line breaks) into the statement below.
--
-- Store rsa_key.p8 securely and reference it via PRIVATE_KEY_PATH / PRIVATE_KEY
-- in your dlt profile.
--
-- ALTER USER DLT_LOADER SET RSA_PUBLIC_KEY = '<paste base64 key body here>';

-- ---------------------------------------------------------------------------
-- 3. In-SPCS runs -- no key needed
-- ---------------------------------------------------------------------------
-- Inside an SPCS job Snowflake injects an OAuth session token automatically.
-- The runner sets AUTHENTICATOR=oauth in that mode; no RSA key pair is required.
