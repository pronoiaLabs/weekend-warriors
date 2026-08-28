-- =============================================================================
-- base/00_accountadmin_grants.sql
-- Purpose : The account-level privileges SYSADMIN needs before the rest of the
--           setup can run. First in the setup-base glob on purpose: on a fresh
--           account, dev/02 and prod/02 fail at CREATE COMPUTE POOL and
--           apply_instance.sh at CREATE POSTGRES INSTANCE without these.
-- Run as  : ACCOUNTADMIN (grants only; idempotent, safe to re-run).
-- Apply   : make setup-base CONFIRM=1
--
-- These are one-time account-shaping grants rather than object DDL, which is
-- why they get their own file instead of hiding as commented-out lines inside
-- the compute files (where they used to live, and where a fresh account
-- discovered them only by failing).
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Compute pools are account-level objects; dev/02_compute.sql and
-- prod/02_compute.sql create them as SYSADMIN.
GRANT CREATE COMPUTE POOL ON ACCOUNT TO ROLE SYSADMIN;

-- The Snowflake Postgres instance is also account-level, created as SYSADMIN
-- by sql/sources/postgres/apply_instance.sh (make setup-postgres-instance) so
-- it is SYSADMIN-owned like everything else here.
GRANT CREATE POSTGRES INSTANCE ON ACCOUNT TO ROLE SYSADMIN;
