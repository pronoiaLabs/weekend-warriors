-- =============================================================================
-- ops/03_metrics.sql
-- Purpose : SPCS platform metric samples, one row per sample, decoded.
-- Run as  : DLT_LOADER_ROLE, which owns it.
-- Prerequisites : ops/01_event_table.sql.
-- Apply   : make setup-ops CONFIRM=1
--
-- WHY THIS IS A SEPARATE VIEW FROM ops/02 AND NOT A UNION WITH IT
--   Logs and metrics share an event table and nothing else. A log row has a message,
--   a severity and a logger; a metric row has a name and a number and no message at
--   all. Putting them in one view gives every row half a table of NULLs, and MESSAGE
--   means nothing for `container.cpu.usage = 0.127`.
--
--   The run-summary layer in ops/04 rolls these up to one row per run. This view
--   keeps the individual samples, because a rollup cannot answer "was memory climbing
--   through the run" and because the whole reason all five metric groups are enabled
--   is to collect now and decide later.
--
-- READ THE DENSITY WARNING BEFORE BUILDING ANYTHING ON THIS
--   The scrape interval is about 30 seconds and pipeline runs are 53 to 130 seconds,
--   so a run yields 1 to 4 samples of each varying metric. Measured on a 92 second
--   production run: container.cpu.usage once, container.memory.usage twice.
--
--   So MAX() over a run is a sampled reading, not a peak, and a memory spike that
--   kills a container will usually fall between scrapes and never appear. These are
--   useful as a trend across many runs and misleading as a per-run maximum. ops/04
--   carries a sample count beside every aggregate for exactly this reason.
--
-- WHAT IS ACTUALLY EMITTED, MEASURED RATHER THAN READ OFF THE DOCUMENTATION
--   16 distinct metrics across four groups. `storage` has produced ZERO rows in three
--   measured runs, including a production one, because these containers mount no
--   volumes. It stays enabled because collecting is cheap and re-applying seventeen
--   Tasks to add a group back is not, but do not join to it hopefully.
--
--   There is no container exit code. `container.state.last.finished.exitcode` appears
--   in the documentation and not in the output. Failure reason still comes from
--   TASK_HISTORY.ERROR_MESSAGE.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

CREATE OR REPLACE VIEW DLT_DB.OPS.V_METRICS
    COMMENT = 'One row per SPCS platform metric sample. Source: DLT_DB.OPS.DLT_EVENTS.'
AS
SELECT
    -- ---------------------------------------------------------------------
    -- Identity: which run this sample belongs to.
    --
    -- QUERY_ID is the join key to task history and to ops/02, and it is the only
    -- reliable one. SERVICE_NAME is JOB_<uuid> for a scheduled Task and a readable
    -- DLT_DEV_<name> for an ad-hoc `make run-spcs`, so it is useful for reading but
    -- useless for joining.
    -- ---------------------------------------------------------------------
    e.TIMESTAMP                                                  AS EVENT_TS,
    e.RESOURCE_ATTRIBUTES:"snow.query.id"::string                AS QUERY_ID,
    e.RESOURCE_ATTRIBUTES:"snow.service.name"::string            AS SERVICE_NAME,

    -- ---------------------------------------------------------------------
    -- Where it ran. Not present on log rows, so this is the only place the pool
    -- and node size are recorded.
    --
    -- COMPUTE_POOL separates production (DLT_POOL) from ad-hoc development
    -- (DLT_DEV_POOL), which matters because dev runs land in the same event table
    -- and would otherwise pollute any fleet-level average.
    --
    -- NODE_INSTANCE_FAMILY is the denominator for sizing questions: a cpu.limit of 3
    -- means nothing until you know it came from a CPU_X64_S.
    -- ---------------------------------------------------------------------
    e.RESOURCE_ATTRIBUTES:"snow.compute_pool.name"::string       AS COMPUTE_POOL,
    e.RESOURCE_ATTRIBUTES:"snow.compute_pool.node.instance_family"::string
                                                                 AS NODE_INSTANCE_FAMILY,
    e.RESOURCE_ATTRIBUTES:"snow.compute_pool.node.id"::string    AS NODE_ID,

    -- ---------------------------------------------------------------------
    -- The measurement itself.
    --
    -- UNIT and DESCRIPTION come free in the payload and are worth surfacing: `byte`
    -- against `packet` against `core` is the difference between a chart that reads
    -- correctly and one that does not, and nothing else in the account documents
    -- what these metrics mean.
    -- ---------------------------------------------------------------------
    e.RECORD:metric.name::string                                 AS METRIC_NAME,
    e.VALUE::float                                               AS METRIC_VALUE,
    e.RECORD:metric.unit::string                                 AS METRIC_UNIT,
    e.RECORD:metric_type::string                                 AS METRIC_TYPE,
    e.RECORD:metric.description::string                          AS METRIC_DESCRIPTION,

    -- ---------------------------------------------------------------------
    -- Which spec group asked for this metric.
    --
    -- Derived from the name rather than carried in the payload, because the payload
    -- does not say. It matters because the groups are set per Task spec: deciding to
    -- drop `network` later means knowing what `network` actually cost, and that
    -- question is unanswerable without this column.
    --
    -- Ordering is significant. `container.memory.limit` must match system_limits and
    -- not system, so the limit and requested suffixes are tested BEFORE the generic
    -- cpu/memory prefixes.
    -- ---------------------------------------------------------------------
    CASE
        WHEN e.RECORD:metric.name::string LIKE 'network.%'          THEN 'network'
        WHEN e.RECORD:metric.name::string LIKE 'volume.%'           THEN 'storage'
        WHEN e.RECORD:metric.name::string LIKE '%.limit'
          OR e.RECORD:metric.name::string LIKE '%.requested'
          OR e.RECORD:metric.name::string LIKE '%.capacity'         THEN 'system_limits'
        WHEN e.RECORD:metric.name::string LIKE 'container.state.%'
          OR e.RECORD:metric.name::string = 'container.restarts'    THEN 'status'
        WHEN e.RECORD:metric.name::string LIKE 'container.%'        THEN 'system'
        ELSE 'other'
    END                                                          AS METRIC_GROUP

FROM DLT_DB.OPS.DLT_EVENTS e
WHERE e.RECORD_TYPE = 'METRIC'
  -- Same guard as ops/02. Keeps the view to pipeline job containers, and keeps it
  -- from ever consuming metrics emitted by something else that lands in this table.
  AND e.RESOURCE_ATTRIBUTES:"snow.service.type"::string = 'Job';

GRANT SELECT ON VIEW DLT_DB.OPS.V_METRICS TO ROLE DLT_DEV_ROLE;
