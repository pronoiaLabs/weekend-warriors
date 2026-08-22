-- =============================================================================
-- sources/firecrawl/02_external_access.sql
-- Purpose : Allow SPCS jobs running the `firecrawl` source to reach the Firecrawl
--           API AND every news feed the registry polls. A container has no network
--           egress by default, so both halves of the pipeline need this integration
--           in dev AND in prod.
-- Run as  : ACCOUNTADMIN (network rule + integration), then grant usage.
-- Prerequisites : base/01_roles.sql (roles), base/02_control_plane.sql (DLT_DB.OPS).
--
-- Applied by: make setup-source SOURCE=firecrawl CONFIRM=1
--
-- There is no 01_databases.sql in this directory on purpose. The source is named for
-- the VENDOR (firecrawl), but its pipelines are named for the CONTENT (nfl_news) and
-- land in NFL_PROD_DB.RAW, which sources/nfl/01_databases.sql already creates. The
-- `make setup-source` banner will still print "Creates FIRECRAWL_DEV_DB"; it derives
-- that from $(SOURCE) and is wrong here. Nothing below creates a database.
--
-- TWO KINDS OF HOST IN ONE RULE. Firecrawl scrapes pages server-side, so the container
-- never contacts an outlet for an article; api.firecrawl.dev is the only host the
-- scrape path touches. The FEEDS are different: the container fetches every RSS/Atom
-- URL in news-registry.yml directly, so each feed host must be listed here too. Adding
-- a feed to the registry without adding its host below fails inside the container with
-- a connection error that the source logs as "feed <name> skipped" and keeps going, so
-- the symptom is a feed that silently never contributes, not a failed run.
--
-- The port is REQUIRED in VALUE_LIST; a bare hostname is not enough. The feed URLs are
-- all https and none of them redirect off-host as of 2026-08-22 (the old
-- profootballtalk.nbcsports.com address is not used; the registry points at the
-- www.nbcsports.com URL it 301s to).
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE NETWORK RULE DLT_DB.OPS.FIRECRAWL_API_EGRESS
    MODE     = EGRESS
    TYPE     = HOST_PORT
    VALUE_LIST = (
        -- Firecrawl API (search, scrape, batch scrape, credit usage)
        'api.firecrawl.dev:443',
        -- Short-post wires
        'www.nbcsports.com:443',
        'www.profootballrumors.com:443',
        -- Article feeds
        'www.cbssports.com:443',
        'www.espn.com:443',
        -- Club sites (https://www.<domain>/rss/news). dallascowboys.com and
        -- commanders.com are absent because their feeds are dead (see registry).
        'www.buffalobills.com:443',
        'www.miamidolphins.com:443',
        'www.patriots.com:443',
        'www.newyorkjets.com:443',
        'www.baltimoreravens.com:443',
        'www.bengals.com:443',
        'www.clevelandbrowns.com:443',
        'www.steelers.com:443',
        'www.houstontexans.com:443',
        'www.colts.com:443',
        'www.jaguars.com:443',
        'www.tennesseetitans.com:443',
        'www.denverbroncos.com:443',
        'www.chiefs.com:443',
        'www.raiders.com:443',
        'www.chargers.com:443',
        'www.giants.com:443',
        'www.philadelphiaeagles.com:443',
        'www.chicagobears.com:443',
        'www.detroitlions.com:443',
        'www.packers.com:443',
        'www.vikings.com:443',
        'www.atlantafalcons.com:443',
        'www.panthers.com:443',
        'www.neworleanssaints.com:443',
        'www.buccaneers.com:443',
        'www.azcardinals.com:443',
        'www.therams.com:443',
        'www.49ers.com:443',
        'www.seahawks.com:443'
    )
    COMMENT  = 'HTTPS egress for the firecrawl source: the Firecrawl API plus every feed host in news-registry.yml.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION FIRECRAWL_API_EAI
    ALLOWED_NETWORK_RULES = (DLT_DB.OPS.FIRECRAWL_API_EGRESS)
    ENABLED = TRUE
    COMMENT = 'External access for dlt SPCS jobs running the firecrawl news source.';

-- Both roles create SPCS jobs: DLT_DEV_ROLE via `make run-spcs`, DLT_LOADER_ROLE
-- via the scheduled Tasks.
GRANT USAGE ON INTEGRATION FIRECRAWL_API_EAI TO ROLE DLT_DEV_ROLE;
GRANT USAGE ON INTEGRATION FIRECRAWL_API_EAI TO ROLE DLT_LOADER_ROLE;
