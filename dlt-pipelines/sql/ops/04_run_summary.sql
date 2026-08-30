-- =============================================================================
-- ops/04_run_summary.sql
-- Purpose : The materialised run-summary layer: TASK_RUNS (one row per scheduled
--           Task run) and PIPELINE_RUNS (one row per pipeline run, ALL sports,
--           SPORT column), plus the procedure and triggered task that keep them
--           fresh. Replaces the per-sport V_PIPELINE_RUNS views entirely.
-- Run as  : DLT_LOADER_ROLE, which owns it.
-- Prerequisites : ops/01 (grants), ops/02 and ops/03 (tables + streams).
-- Apply   : make setup-ops CONFIRM=1
--
-- WHY TABLES, AND WHAT THE REFRESH MODEL IS
--   The view stack cost 4.6-6.0s per uncached dashboard query, compile exceeding
--   execute, result cache disqualified throughout. Now the parse and rollup work
--   runs ONCE per data arrival: SPCS flushes container events -> the ops/02+03
--   streams have data -> OBS_REFRESH fires itself (min 60s between fires) ->
--   SP_OBS_REFRESH drains the streams and re-merges the run tables. Reads are
--   plain table scans. The normal path is purely event-driven; no schedule is
--   involved in keeping it fresh.
--
--   Two situations produce NO event and therefore no trigger, and they are why
--   OBS_REFRESH_SWEEP exists (every 4 hours): a container that dies before
--   producing a single line (the failure class most worth seeing), and a run
--   whose final SUCCEEDED/FAILED verdict lands in task-history metadata after
--   its last event flush. Both self-heal on the next fire from ANY run; the
--   sweep merely bounds how long that can take. Accepted trade, decided
--   deliberately: state is as-of the last refresh instead of as-of the query.
--
-- ONE PIPELINE_RUNS TABLE, NOT THREE PER-SPORT VIEWS
--   The refresh loops sports from DLT_DB.OPS.PIPELINE_REGISTRY at run time and
--   composes <STEM>_PROD_DB.OPS._DLT_RUNS per iteration, so adding a sport needs
--   ZERO new observability objects: rows appear the moment its first pipeline
--   completes. The per-sport sql/sources/<name>/04_run_summary.sql files are
--   reduced to dropping the superseded views.
--
-- TWO TASK-HISTORY SOURCES, STILL, BECAUSE NEITHER IS SUFFICIENT ALONE
--   INFORMATION_SCHEMA.TASK_HISTORY: 7 days, no lag -- the routine source, every
--   refresh. RESULT_LIMIT => 10000 IS NOT OPTIONAL: the 100-row default silently
--   truncates. ACCOUNT_USAGE.TASK_HISTORY: 365 days, up to ~47 minutes of lag
--   (measured) -- merged only at bootstrap or when the watermark has gone stale
--   (OBS tasks suspended >6 days while pipelines kept running), so a gap
--   self-heals without anyone noticing it existed. Live wins overlap because its
--   MERGE runs second and updates every mutable column.
--
-- THE STREAMS GO STALE AT 14 DAYS (MAX_DATA_EXTENSION_TIME default; the event
--   table's own Time Travel is 1 day and the streams are what extend it). If
--   OBS_REFRESH is ever suspended longer: suspend both tasks, then
--   CALL SP_OBS_REFRESH(TRUE) to recreate the streams and rebuild, then resume.
--
-- THE PARSE, DOCUMENTED HERE BECAUSE THE PARSE SQL LIVES HERE
--   FOUR WIRE FORMATS, NOT ONE (counts from live data when this was written):
--     dlt          855  ts|[LEVEL]|pid|tid|logger|file|func:line|msg
--     stdlib       102  ts LEVEL logger msg           (may carry [pipeline=X])
--     continuation  12  raw traceback frames, no prefix at all
--     structured     8  bare msg; severity in RECORD, logger in SCOPE
--   `structured` is snowflake-telemetry-python output for the `dlt_pipeline`
--   logger: its VALUE has NO prefix because the formatter moved timestamp, level
--   and logger into structured columns. The parse handles it by falling through
--   every regex to raw VALUE. LOG_FORMAT is the parser's own coverage report: a
--   rise in 'continuation' means a format changed underneath this file.
--
--   SNOWFLAKE REGEX IS POSIX ERE: `(?:...)` is rejected. Bracket classes stand
--   in for escapes throughout: [|] for a pipe, [[] and []] for brackets.
--
--   EXPECT DUPLICATE LOG MESSAGES AND DO NOT DEDUPLICATE THEM HERE: run.py
--   attaches two handlers, so every `dlt_pipeline` message arrives once
--   structured and once as stdlib text. This layer reports what the container
--   actually wrote. A consumer wanting one copy filters on LOG_FORMAT.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

-- ---------------------------------------------------------------------------
-- 1. TASK_RUNS: one row per scheduled Task run, rollups baked in. Column set is
-- the old V_TASK_RUNS output plus REFRESHED_AT. IF NOT EXISTS, never OR REPLACE.
--
-- Timestamps stay TIMESTAMP_LTZ exactly as TASK_HISTORY returns them: the
-- dashboard API's UTC-session ISO formatting depends on the type.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.TASK_RUNS (
    PIPELINE                VARCHAR,
    TASK_NAME               VARCHAR,
    QUERY_ID                VARCHAR,        -- the key
    SERVICE_NAME            VARCHAR,
    COMPUTE_POOL            VARCHAR,
    NODE_INSTANCE_FAMILY    VARCHAR,
    HISTORY_SOURCE          VARCHAR,        -- 'live' or 'account_usage'
    STATE                   VARCHAR,
    TASK_ERROR_MESSAGE      VARCHAR,
    EXIT_STATUS             VARCHAR,
    SCHEDULED_TIME          TIMESTAMP_LTZ,
    RUN_STARTED_AT          TIMESTAMP_LTZ,
    RUN_ENDED_AT            TIMESTAMP_LTZ,
    DURATION_S              NUMBER,
    CONTAINER_SPAN_S        NUMBER,
    STARTUP_OVERHEAD_S      NUMBER,
    LOG_LINES               NUMBER,
    ERROR_LINES             NUMBER,
    WARNING_LINES           NUMBER,
    UNPARSED_LINES          NUMBER,
    PIPELINE_FROM_LOG       VARCHAR,
    METRIC_SAMPLES          NUMBER,
    CPU_CORES_MAX           FLOAT,
    CPU_SAMPLES             NUMBER,
    CPU_CORES_LIMIT         FLOAT,
    CPU_CORES_REQUESTED     FLOAT,
    MEM_BYTES_MAX           FLOAT,
    MEM_SAMPLES             NUMBER,
    MEM_BYTES_LIMIT         FLOAT,
    MEM_BYTES_REQUESTED     FLOAT,
    RESTARTS                FLOAT,
    NET_RX_BYTES            FLOAT,
    NET_TX_BYTES            FLOAT,
    TELEMETRY_AVAILABLE     BOOLEAN,
    CONTAINER_NEVER_STARTED BOOLEAN,
    REFRESHED_AT            TIMESTAMP_LTZ
)
COMMENT = 'One row per scheduled dlt Task run, rollups baked in. Maintained by SP_OBS_REFRESH; retention 365d (ops/05).';

-- ---------------------------------------------------------------------------
-- 2. PIPELINE_RUNS: one row per pipeline run, every sport, SPORT column holding
-- the uppercase registry stem ('NFL'), which is what the dashboard's registry
-- already speaks. Column set is the old per-sport V_PIPELINE_RUNS output plus
-- SPORT and REFRESHED_AT.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.PIPELINE_RUNS (
    SPORT                   VARCHAR,        -- uppercase registry stem, e.g. 'NFL'
    PIPELINE                VARCHAR,
    TASK_NAME               VARCHAR,
    QUERY_ID                VARCHAR,        -- the key
    SERVICE_NAME            VARCHAR,
    COMPUTE_POOL            VARCHAR,
    RUN_STARTED_AT          TIMESTAMP_LTZ,
    RUN_ENDED_AT            TIMESTAMP_LTZ,
    DURATION_S              NUMBER,
    CONTAINER_SPAN_S        NUMBER,
    STARTUP_OVERHEAD_S      NUMBER,
    TASK_STATE              VARCHAR,
    DLT_STATUS              VARCHAR,
    OUTCOME_DISAGREES       BOOLEAN,
    DLT_RECORD_MISSING      BOOLEAN,
    ROWS_LOADED             NUMBER,
    ROW_COUNTS              VARIANT,
    LOAD_ID                 VARCHAR,
    RESOURCES               VARIANT,
    ERROR_TEXT              VARCHAR,
    EXIT_STATUS             VARCHAR,
    LOG_LINES               NUMBER,
    ERROR_LINES             NUMBER,
    WARNING_LINES           NUMBER,
    UNPARSED_LINES          NUMBER,
    METRIC_SAMPLES          NUMBER,
    CPU_CORES_MAX           FLOAT,
    CPU_SAMPLES             NUMBER,
    CPU_CORES_LIMIT         FLOAT,
    MEM_BYTES_MAX           FLOAT,
    MEM_SAMPLES             NUMBER,
    MEM_BYTES_REQUESTED     FLOAT,
    RESTARTS                FLOAT,
    TELEMETRY_AVAILABLE     BOOLEAN,
    CONTAINER_NEVER_STARTED BOOLEAN,
    REFRESHED_AT            TIMESTAMP_LTZ
)
COMMENT = 'One row per pipeline run, all sports (SPORT = uppercase registry stem). Maintained by SP_OBS_REFRESH; the dashboard API reads this directly. Retention 365d (ops/05).';

-- ---------------------------------------------------------------------------
-- 3. The refresh procedure. Caller's rights (the QUERY_HISTORY-style restriction
-- on metadata table functions applies to owner's-rights procs only; SP_DBT_HARVEST
-- proved a caller's-rights proc works fine even when invoked by a task).
--
-- Steps, in strict order:
--   1. Drain each stream through its parse into LOG_LINES / METRIC_SAMPLES.
--      One stream per target: any DML reading a stream advances the WHOLE
--      offset, WHERE clause notwithstanding.
--   2. MERGE TASK_RUNS from task history. ACCOUNT_USAGE first when needed
--      (bootstrap / stale watermark), live second so live wins overlap. Rollups
--      recompute wholesale for every run in the merge window: ~175 rows joined
--      to the parsed tables is trivial, and it makes late-arriving log lines
--      and EXECUTING->final transitions self-correcting.
--   3. Loop sports from PIPELINE_REGISTRY and MERGE PIPELINE_RUNS per sport.
--      Each iteration has its own exception handler: a brand-new sport whose
--      _DLT_RUNS does not exist yet must not fail the refresh for everyone.
--
-- EMPTY STREAMS ARE NOT A NO-OP. Unlike SP_DBT_BUILD, the proc continues to the
-- merges regardless: the sweep exists precisely to record runs that produced no
-- events, and the merge IS the work in that case.
--
-- FULL_REBUILD => TRUE: truncates the parsed tables and recreates both streams
-- with SHOW_INITIAL_ROWS = TRUE, so the drain that follows re-parses the entire
-- event table. Bootstrap and disaster recovery share this one path. SUSPEND
-- OBS_REFRESH BEFORE CALLING IT MANUALLY: a triggered fire racing the rebuild
-- between truncate and drain would double-parse the initial rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_OBS_REFRESH(FULL_REBUILD BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Drain the ops/02+03 streams into the parsed tables, then re-merge TASK_RUNS and PIPELINE_RUNS. FULL_REBUILD=TRUE re-parses the whole event table (suspend OBS_REFRESH first).'
EXECUTE AS CALLER
AS
$$
DECLARE
  logs_n     INTEGER DEFAULT 0;
  metrics_n  INTEGER DEFAULT 0;
  runs_n     INTEGER DEFAULT 0;
  sports_ok  INTEGER DEFAULT 0;
  sports_err INTEGER DEFAULT 0;
  err_note   VARCHAR DEFAULT '';
  use_hist   BOOLEAN;
  win_days   INTEGER;
  wm         TIMESTAMP_LTZ;
  merge_sql  VARCHAR;
  sports CURSOR FOR
    SELECT TARGET_DATABASE AS STEM
    FROM DLT_DB.OPS.PIPELINE_REGISTRY
    WHERE ENABLED AND TARGET_DATABASE <> 'DLT'
    GROUP BY TARGET_DATABASE;
BEGIN

  IF (FULL_REBUILD) THEN
    -- Derived data only; the raw event table is never touched. OR REPLACE on the
    -- streams deliberately re-arms SHOW_INITIAL_ROWS: the next drain below IS the
    -- full re-parse.
    TRUNCATE TABLE DLT_DB.OPS.LOG_LINES;
    TRUNCATE TABLE DLT_DB.OPS.METRIC_SAMPLES;
    CREATE OR REPLACE STREAM DLT_DB.OPS.STREAM_OBS_LOGS
      ON EVENT TABLE DLT_DB.OPS.DLT_EVENTS APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE
      COMMENT = 'Feeds the log-line parse in SP_OBS_REFRESH. One stream per consumer; ops/03 has its own. Never OR REPLACE casually: SHOW_INITIAL_ROWS re-arms.';
    CREATE OR REPLACE STREAM DLT_DB.OPS.STREAM_OBS_METRICS
      ON EVENT TABLE DLT_DB.OPS.DLT_EVENTS APPEND_ONLY = TRUE SHOW_INITIAL_ROWS = TRUE
      COMMENT = 'Feeds the metric decode in SP_OBS_REFRESH. One stream per consumer; ops/02 has its own. Never OR REPLACE casually: SHOW_INITIAL_ROWS re-arms.';
  END IF;

  -- -------------------------------------------------------------------------
  -- Step 1a: log lines. This INSERT is the stream consumption for
  -- STREAM_OBS_LOGS; the WHERE discards non-Job and non-LOG rows FOREVER (they
  -- remain readable in the raw table for its 30 days). Deliberate parity with
  -- the old view's filters.
  -- -------------------------------------------------------------------------
  INSERT INTO DLT_DB.OPS.LOG_LINES
    (EVENT_TS, QUERY_ID, SERVICE_NAME, CONTAINER_NAME, LOG_FORMAT,
     SEVERITY, LOGGER_NAME, PIPELINE, MESSAGE, RAW_LINE)
  SELECT
    e.TIMESTAMP,
    e.RESOURCE_ATTRIBUTES:"snow.query.id"::string,
    e.RESOURCE_ATTRIBUTES:"snow.service.name"::string,
    e.RESOURCE_ATTRIBUTES:"snow.service.container.name"::string,

    -- Which of the four shapes this line arrived in (see file header).
    CASE
        WHEN e.RECORD:severity_text IS NOT NULL                                THEN 'structured'
        WHEN e.VALUE::string RLIKE '^[0-9-]{10} [0-9:]{8},[0-9]{3}[|].*'       THEN 'dlt'
        WHEN e.VALUE::string RLIKE '^[0-9-]{10} [0-9:]{8},[0-9]{3} [A-Z]+ .*'  THEN 'stdlib'
        ELSE 'continuation'
    END,

    -- Structured value first: authoritative when present. The regexes carry the
    -- other 97%, so they are the primary path and not a fallback.
    COALESCE(
        e.RECORD:severity_text::string,
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3}[|][[]([A-Z]+)[]]', 1, 1, 'e', 1),
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3} ([A-Z]+) ',        1, 1, 'e', 1)
    ),

    COALESCE(
        e.SCOPE:name::string,
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3}[|][[][A-Z]+[]][|][0-9]+[|][0-9]+[|]([A-Za-z0-9_.]+)[|]',
            1, 1, 'e', 1),
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3} [A-Z]+ ([A-Za-z0-9_.]+) ',
            1, 1, 'e', 1)
    ),

    -- Sparse by nature: only our own adapter emits the pipeline field; NULLIF
    -- strips the '-' placeholder. Cross-check, not the key; QUERY_ID is the key.
    NULLIF(
        COALESCE(
            e.RECORD_ATTRIBUTES:"pipeline"::string,
            REGEXP_SUBSTR(e.VALUE::string, '[[]pipeline=([A-Za-z0-9_]+)[]]', 1, 1, 'e', 1)
        ), '-'),

    -- Message with its prefix removed: dlt form split on the seventh pipe, 'es'
    -- flags so wrapped lines are not truncated. Final COALESCE arm returns VALUE
    -- unchanged, correct for structured (already bare) and continuation (raw
    -- traceback frame) rows alike.
    REGEXP_REPLACE(
        COALESCE(
            REGEXP_SUBSTR(e.VALUE::string,
                '^[^|]*[|][^|]*[|][^|]*[|][^|]*[|][^|]*[|][^|]*[|][^|]*[|](.*)$',
                1, 1, 'es', 1),
            REGEXP_SUBSTR(e.VALUE::string,
                '^[0-9-]{10} [0-9:]{8},[0-9]{3} [A-Z]+ [A-Za-z0-9_.]+ (.*)$',
                1, 1, 'es', 1),
            e.VALUE::string
        ),
        '^[[]pipeline=[A-Za-z0-9_]+[]] ', ''
    ),

    e.VALUE::string
  FROM DLT_DB.OPS.STREAM_OBS_LOGS e
  WHERE e.RECORD_TYPE = 'LOG'
    AND e.RESOURCE_ATTRIBUTES:"snow.service.type"::string = 'Job';
  logs_n := SQLROWCOUNT;

  -- -------------------------------------------------------------------------
  -- Step 1b: metric samples. Consumes STREAM_OBS_METRICS. METRIC_GROUP ordering
  -- is significant: limit/requested suffixes must match system_limits BEFORE the
  -- generic container.% prefix.
  -- -------------------------------------------------------------------------
  INSERT INTO DLT_DB.OPS.METRIC_SAMPLES
    (EVENT_TS, QUERY_ID, SERVICE_NAME, COMPUTE_POOL, NODE_INSTANCE_FAMILY, NODE_ID,
     METRIC_NAME, METRIC_VALUE, METRIC_UNIT, METRIC_TYPE, METRIC_DESCRIPTION, METRIC_GROUP)
  SELECT
    e.TIMESTAMP,
    e.RESOURCE_ATTRIBUTES:"snow.query.id"::string,
    e.RESOURCE_ATTRIBUTES:"snow.service.name"::string,
    e.RESOURCE_ATTRIBUTES:"snow.compute_pool.name"::string,
    e.RESOURCE_ATTRIBUTES:"snow.compute_pool.node.instance_family"::string,
    e.RESOURCE_ATTRIBUTES:"snow.compute_pool.node.id"::string,
    e.RECORD:metric.name::string,
    -- A histogram metric carries an object here ({bucket_counts, explicit_bounds,
    -- count, max ...}); the first one arrived 2026-08-22 and a bare ::float cast
    -- failed every refresh until the task auto-suspended. Keep the row, with the
    -- name, type and unit queryable, and a NULL value for anything non-scalar.
    IFF(TYPEOF(e.VALUE) IN ('INTEGER', 'DECIMAL', 'DOUBLE'), e.VALUE::float, NULL),
    e.RECORD:metric.unit::string,
    e.RECORD:metric_type::string,
    e.RECORD:metric.description::string,
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
    END
  FROM DLT_DB.OPS.STREAM_OBS_METRICS e
  WHERE e.RECORD_TYPE = 'METRIC'
    AND e.RESOURCE_ATTRIBUTES:"snow.service.type"::string = 'Job';
  metrics_n := SQLROWCOUNT;

  -- -------------------------------------------------------------------------
  -- Step 2: TASK_RUNS. The watermark decides whether ACCOUNT_USAGE is needed:
  -- NULL (bootstrap) or >6 days old (OBS tasks were suspended while pipelines
  -- kept running; runs would otherwise age past the live function's 7-day
  -- window and vanish unrecorded).
  -- -------------------------------------------------------------------------
  wm := (SELECT MAX(RUN_STARTED_AT) FROM DLT_DB.OPS.TASK_RUNS);
  use_hist := (FULL_REBUILD OR wm IS NULL OR wm < DATEADD('day', -6, CURRENT_TIMESTAMP()));
  win_days := IFF(use_hist, 400, 7);

  IF (use_hist) THEN
    -- ACCOUNT_USAGE arm, bootstrap/gap only. Same shape as the live merge below
    -- (duplicated deliberately: one readable statement each beats a shared
    -- string assembled at run time). Runs FIRST so the live merge wins overlap.
    MERGE INTO DLT_DB.OPS.TASK_RUNS tr
    USING (
      WITH th AS (
        SELECT 'account_usage' AS HISTORY_SOURCE,
               NAME, QUERY_ID, STATE, SCHEDULED_TIME,
               QUERY_START_TIME, COMPLETED_TIME, ERROR_MESSAGE
        FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
        WHERE DATABASE_NAME = 'DLT_DB'
          AND NAME ILIKE 'DLT\_TASK\_%' ESCAPE '\\'
          AND QUERY_START_TIME IS NOT NULL
          AND QUERY_START_TIME >= DATEADD('day', -400, CURRENT_TIMESTAMP())
        QUALIFY ROW_NUMBER() OVER (PARTITION BY QUERY_ID ORDER BY SCHEDULED_TIME DESC) = 1
      ),
      w AS (
        SELECT LEAST(
          COALESCE((SELECT MIN(EVENT_TS) FROM DLT_DB.OPS.LOG_LINES),      '9999-01-01'::TIMESTAMP_NTZ),
          COALESCE((SELECT MIN(EVENT_TS) FROM DLT_DB.OPS.METRIC_SAMPLES), '9999-01-01'::TIMESTAMP_NTZ)
        ) AS TELEMETRY_FROM
      ),
      logs AS (
        SELECT QUERY_ID,
               MIN(EVENT_TS) AS FIRST_LOG_AT, MAX(EVENT_TS) AS LAST_LOG_AT,
               COUNT(*) AS LOG_LINES,
               COUNT_IF(SEVERITY = 'ERROR') AS ERROR_LINES,
               COUNT_IF(SEVERITY IN ('WARNING', 'WARN')) AS WARNING_LINES,
               COUNT_IF(LOG_FORMAT = 'continuation') AS UNPARSED_LINES,
               MAX(PIPELINE) AS PIPELINE_FROM_LOG,
               MAX(SERVICE_NAME) AS SERVICE_NAME
        FROM DLT_DB.OPS.LOG_LINES
        WHERE QUERY_ID IN (SELECT QUERY_ID FROM th)
        GROUP BY QUERY_ID
      ),
      m AS (
        SELECT QUERY_ID,
               MAX(COMPUTE_POOL) AS COMPUTE_POOL,
               MAX(NODE_INSTANCE_FAMILY) AS NODE_INSTANCE_FAMILY,
               COUNT(*) AS METRIC_SAMPLES,
               MAX(IFF(METRIC_NAME = 'container.cpu.usage',        METRIC_VALUE, NULL)) AS CPU_CORES_MAX,
               COUNT_IF(METRIC_NAME = 'container.cpu.usage')                            AS CPU_SAMPLES,
               MAX(IFF(METRIC_NAME = 'container.cpu.limit',        METRIC_VALUE, NULL)) AS CPU_CORES_LIMIT,
               MAX(IFF(METRIC_NAME = 'container.cpu.requested',    METRIC_VALUE, NULL)) AS CPU_CORES_REQUESTED,
               MAX(IFF(METRIC_NAME = 'container.memory.usage',     METRIC_VALUE, NULL)) AS MEM_BYTES_MAX,
               COUNT_IF(METRIC_NAME = 'container.memory.usage')                         AS MEM_SAMPLES,
               MAX(IFF(METRIC_NAME = 'container.memory.limit',     METRIC_VALUE, NULL)) AS MEM_BYTES_LIMIT,
               MAX(IFF(METRIC_NAME = 'container.memory.requested', METRIC_VALUE, NULL)) AS MEM_BYTES_REQUESTED,
               MAX(IFF(METRIC_NAME = 'container.restarts',         METRIC_VALUE, NULL)) AS RESTARTS,
               SUM(IFF(METRIC_NAME = 'network.egress.received.bytes',    METRIC_VALUE, 0)) AS NET_RX_BYTES,
               SUM(IFF(METRIC_NAME = 'network.egress.transmitted.bytes', METRIC_VALUE, 0)) AS NET_TX_BYTES
        FROM DLT_DB.OPS.METRIC_SAMPLES
        WHERE QUERY_ID IN (SELECT QUERY_ID FROM th)
        GROUP BY QUERY_ID
      )
      SELECT
        LOWER(REGEXP_SUBSTR(th.NAME, '^DLT_TASK_(.*)$', 1, 1, 'e', 1)) AS PIPELINE,
        th.NAME AS TASK_NAME, th.QUERY_ID, logs.SERVICE_NAME,
        m.COMPUTE_POOL, m.NODE_INSTANCE_FAMILY, th.HISTORY_SOURCE,
        th.STATE, th.ERROR_MESSAGE AS TASK_ERROR_MESSAGE,
        REGEXP_SUBSTR(th.ERROR_MESSAGE, 'Exited with status: ([A-Z]+)', 1, 1, 'e', 1) AS EXIT_STATUS,
        th.SCHEDULED_TIME, th.QUERY_START_TIME AS RUN_STARTED_AT, th.COMPLETED_TIME AS RUN_ENDED_AT,
        DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME) AS DURATION_S,
        DATEDIFF('second', logs.FIRST_LOG_AT, logs.LAST_LOG_AT)    AS CONTAINER_SPAN_S,
        DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME)
          - DATEDIFF('second', logs.FIRST_LOG_AT, logs.LAST_LOG_AT) AS STARTUP_OVERHEAD_S,
        logs.LOG_LINES, logs.ERROR_LINES, logs.WARNING_LINES, logs.UNPARSED_LINES, logs.PIPELINE_FROM_LOG,
        m.METRIC_SAMPLES, m.CPU_CORES_MAX, m.CPU_SAMPLES, m.CPU_CORES_LIMIT, m.CPU_CORES_REQUESTED,
        m.MEM_BYTES_MAX, m.MEM_SAMPLES, m.MEM_BYTES_LIMIT, m.MEM_BYTES_REQUESTED,
        m.RESTARTS, m.NET_RX_BYTES, m.NET_TX_BYTES,
        -- THE CONVERT_TIMEZONE IS LOAD BEARING AND ITS ABSENCE FAILS QUIETLY.
        -- EVENT_TS is TIMESTAMP_NTZ holding UTC; QUERY_START_TIME is LTZ.
        -- Compared directly, the NTZ boundary is read in the session timezone
        -- and lands hours off; every run then reports TELEMETRY_AVAILABLE =
        -- FALSE, including ones sitting on hundreds of log lines. Nothing errors.
        (CONVERT_TIMEZONE('UTC', th.QUERY_START_TIME)::TIMESTAMP_NTZ >= w.TELEMETRY_FROM)
          AS TELEMETRY_AVAILABLE,
        -- Gated on COMPLETED_TIME: an EXECUTING run has no logs YET, which is
        -- not the same finding as a container that never came up. The old view
        -- flashed TRUE for one cycle here; the table version should not store it.
        (CONVERT_TIMEZONE('UTC', th.QUERY_START_TIME)::TIMESTAMP_NTZ >= w.TELEMETRY_FROM
          AND logs.QUERY_ID IS NULL AND th.COMPLETED_TIME IS NOT NULL)
          AS CONTAINER_NEVER_STARTED
      FROM th
      CROSS JOIN w
      LEFT JOIN logs ON logs.QUERY_ID = th.QUERY_ID
      LEFT JOIN m    ON m.QUERY_ID    = th.QUERY_ID
    ) s
    ON tr.QUERY_ID = s.QUERY_ID
    WHEN MATCHED THEN UPDATE SET
      PIPELINE = s.PIPELINE, TASK_NAME = s.TASK_NAME, SERVICE_NAME = s.SERVICE_NAME,
      COMPUTE_POOL = s.COMPUTE_POOL, NODE_INSTANCE_FAMILY = s.NODE_INSTANCE_FAMILY,
      HISTORY_SOURCE = s.HISTORY_SOURCE, STATE = s.STATE,
      TASK_ERROR_MESSAGE = s.TASK_ERROR_MESSAGE, EXIT_STATUS = s.EXIT_STATUS,
      SCHEDULED_TIME = s.SCHEDULED_TIME, RUN_STARTED_AT = s.RUN_STARTED_AT,
      RUN_ENDED_AT = s.RUN_ENDED_AT, DURATION_S = s.DURATION_S,
      CONTAINER_SPAN_S = s.CONTAINER_SPAN_S, STARTUP_OVERHEAD_S = s.STARTUP_OVERHEAD_S,
      LOG_LINES = s.LOG_LINES, ERROR_LINES = s.ERROR_LINES,
      WARNING_LINES = s.WARNING_LINES, UNPARSED_LINES = s.UNPARSED_LINES,
      PIPELINE_FROM_LOG = s.PIPELINE_FROM_LOG, METRIC_SAMPLES = s.METRIC_SAMPLES,
      CPU_CORES_MAX = s.CPU_CORES_MAX, CPU_SAMPLES = s.CPU_SAMPLES,
      CPU_CORES_LIMIT = s.CPU_CORES_LIMIT, CPU_CORES_REQUESTED = s.CPU_CORES_REQUESTED,
      MEM_BYTES_MAX = s.MEM_BYTES_MAX, MEM_SAMPLES = s.MEM_SAMPLES,
      MEM_BYTES_LIMIT = s.MEM_BYTES_LIMIT, MEM_BYTES_REQUESTED = s.MEM_BYTES_REQUESTED,
      RESTARTS = s.RESTARTS, NET_RX_BYTES = s.NET_RX_BYTES, NET_TX_BYTES = s.NET_TX_BYTES,
      TELEMETRY_AVAILABLE = s.TELEMETRY_AVAILABLE,
      CONTAINER_NEVER_STARTED = s.CONTAINER_NEVER_STARTED,
      REFRESHED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
      (PIPELINE, TASK_NAME, QUERY_ID, SERVICE_NAME, COMPUTE_POOL, NODE_INSTANCE_FAMILY,
       HISTORY_SOURCE, STATE, TASK_ERROR_MESSAGE, EXIT_STATUS, SCHEDULED_TIME,
       RUN_STARTED_AT, RUN_ENDED_AT, DURATION_S, CONTAINER_SPAN_S, STARTUP_OVERHEAD_S,
       LOG_LINES, ERROR_LINES, WARNING_LINES, UNPARSED_LINES, PIPELINE_FROM_LOG,
       METRIC_SAMPLES, CPU_CORES_MAX, CPU_SAMPLES, CPU_CORES_LIMIT, CPU_CORES_REQUESTED,
       MEM_BYTES_MAX, MEM_SAMPLES, MEM_BYTES_LIMIT, MEM_BYTES_REQUESTED,
       RESTARTS, NET_RX_BYTES, NET_TX_BYTES, TELEMETRY_AVAILABLE, CONTAINER_NEVER_STARTED,
       REFRESHED_AT)
    VALUES
      (s.PIPELINE, s.TASK_NAME, s.QUERY_ID, s.SERVICE_NAME, s.COMPUTE_POOL, s.NODE_INSTANCE_FAMILY,
       s.HISTORY_SOURCE, s.STATE, s.TASK_ERROR_MESSAGE, s.EXIT_STATUS, s.SCHEDULED_TIME,
       s.RUN_STARTED_AT, s.RUN_ENDED_AT, s.DURATION_S, s.CONTAINER_SPAN_S, s.STARTUP_OVERHEAD_S,
       s.LOG_LINES, s.ERROR_LINES, s.WARNING_LINES, s.UNPARSED_LINES, s.PIPELINE_FROM_LOG,
       s.METRIC_SAMPLES, s.CPU_CORES_MAX, s.CPU_SAMPLES, s.CPU_CORES_LIMIT, s.CPU_CORES_REQUESTED,
       s.MEM_BYTES_MAX, s.MEM_SAMPLES, s.MEM_BYTES_LIMIT, s.MEM_BYTES_REQUESTED,
       s.RESTARTS, s.NET_RX_BYTES, s.NET_TX_BYTES, s.TELEMETRY_AVAILABLE, s.CONTAINER_NEVER_STARTED,
       CURRENT_TIMESTAMP());
  END IF;

  -- Live arm, every refresh. RESULT_LIMIT default of 100 silently truncates;
  -- 10000 is the maximum the function accepts. Identical shape to the arm above.
  MERGE INTO DLT_DB.OPS.TASK_RUNS tr
  USING (
    WITH th AS (
      SELECT 'live' AS HISTORY_SOURCE,
             NAME, QUERY_ID, STATE, SCHEDULED_TIME,
             QUERY_START_TIME, COMPLETED_TIME, ERROR_MESSAGE
      FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(RESULT_LIMIT => 10000))
      WHERE NAME ILIKE 'DLT\_TASK\_%' ESCAPE '\\'
        AND QUERY_START_TIME IS NOT NULL
      QUALIFY ROW_NUMBER() OVER (PARTITION BY QUERY_ID ORDER BY SCHEDULED_TIME DESC) = 1
    ),
    w AS (
      SELECT LEAST(
        COALESCE((SELECT MIN(EVENT_TS) FROM DLT_DB.OPS.LOG_LINES),      '9999-01-01'::TIMESTAMP_NTZ),
        COALESCE((SELECT MIN(EVENT_TS) FROM DLT_DB.OPS.METRIC_SAMPLES), '9999-01-01'::TIMESTAMP_NTZ)
      ) AS TELEMETRY_FROM
    ),
    logs AS (
      SELECT QUERY_ID,
             MIN(EVENT_TS) AS FIRST_LOG_AT, MAX(EVENT_TS) AS LAST_LOG_AT,
             COUNT(*) AS LOG_LINES,
             COUNT_IF(SEVERITY = 'ERROR') AS ERROR_LINES,
             COUNT_IF(SEVERITY IN ('WARNING', 'WARN')) AS WARNING_LINES,
             COUNT_IF(LOG_FORMAT = 'continuation') AS UNPARSED_LINES,
             MAX(PIPELINE) AS PIPELINE_FROM_LOG,
             MAX(SERVICE_NAME) AS SERVICE_NAME
      FROM DLT_DB.OPS.LOG_LINES
      WHERE QUERY_ID IN (SELECT QUERY_ID FROM th)
      GROUP BY QUERY_ID
    ),
    m AS (
      SELECT QUERY_ID,
             MAX(COMPUTE_POOL) AS COMPUTE_POOL,
             MAX(NODE_INSTANCE_FAMILY) AS NODE_INSTANCE_FAMILY,
             COUNT(*) AS METRIC_SAMPLES,
             MAX(IFF(METRIC_NAME = 'container.cpu.usage',        METRIC_VALUE, NULL)) AS CPU_CORES_MAX,
             COUNT_IF(METRIC_NAME = 'container.cpu.usage')                            AS CPU_SAMPLES,
             MAX(IFF(METRIC_NAME = 'container.cpu.limit',        METRIC_VALUE, NULL)) AS CPU_CORES_LIMIT,
             MAX(IFF(METRIC_NAME = 'container.cpu.requested',    METRIC_VALUE, NULL)) AS CPU_CORES_REQUESTED,
             MAX(IFF(METRIC_NAME = 'container.memory.usage',     METRIC_VALUE, NULL)) AS MEM_BYTES_MAX,
             COUNT_IF(METRIC_NAME = 'container.memory.usage')                         AS MEM_SAMPLES,
             MAX(IFF(METRIC_NAME = 'container.memory.limit',     METRIC_VALUE, NULL)) AS MEM_BYTES_LIMIT,
             MAX(IFF(METRIC_NAME = 'container.memory.requested', METRIC_VALUE, NULL)) AS MEM_BYTES_REQUESTED,
             MAX(IFF(METRIC_NAME = 'container.restarts',         METRIC_VALUE, NULL)) AS RESTARTS,
             SUM(IFF(METRIC_NAME = 'network.egress.received.bytes',    METRIC_VALUE, 0)) AS NET_RX_BYTES,
             SUM(IFF(METRIC_NAME = 'network.egress.transmitted.bytes', METRIC_VALUE, 0)) AS NET_TX_BYTES
      FROM DLT_DB.OPS.METRIC_SAMPLES
      WHERE QUERY_ID IN (SELECT QUERY_ID FROM th)
      GROUP BY QUERY_ID
    )
    SELECT
      LOWER(REGEXP_SUBSTR(th.NAME, '^DLT_TASK_(.*)$', 1, 1, 'e', 1)) AS PIPELINE,
      th.NAME AS TASK_NAME, th.QUERY_ID, logs.SERVICE_NAME,
      m.COMPUTE_POOL, m.NODE_INSTANCE_FAMILY, th.HISTORY_SOURCE,
      th.STATE, th.ERROR_MESSAGE AS TASK_ERROR_MESSAGE,
      REGEXP_SUBSTR(th.ERROR_MESSAGE, 'Exited with status: ([A-Z]+)', 1, 1, 'e', 1) AS EXIT_STATUS,
      th.SCHEDULED_TIME, th.QUERY_START_TIME AS RUN_STARTED_AT, th.COMPLETED_TIME AS RUN_ENDED_AT,
      DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME) AS DURATION_S,
      DATEDIFF('second', logs.FIRST_LOG_AT, logs.LAST_LOG_AT)    AS CONTAINER_SPAN_S,
      DATEDIFF('second', th.QUERY_START_TIME, th.COMPLETED_TIME)
        - DATEDIFF('second', logs.FIRST_LOG_AT, logs.LAST_LOG_AT) AS STARTUP_OVERHEAD_S,
      logs.LOG_LINES, logs.ERROR_LINES, logs.WARNING_LINES, logs.UNPARSED_LINES, logs.PIPELINE_FROM_LOG,
      m.METRIC_SAMPLES, m.CPU_CORES_MAX, m.CPU_SAMPLES, m.CPU_CORES_LIMIT, m.CPU_CORES_REQUESTED,
      m.MEM_BYTES_MAX, m.MEM_SAMPLES, m.MEM_BYTES_LIMIT, m.MEM_BYTES_REQUESTED,
      m.RESTARTS, m.NET_RX_BYTES, m.NET_TX_BYTES,
      -- Same load-bearing CONVERT_TIMEZONE as the arm above; see comment there.
      (CONVERT_TIMEZONE('UTC', th.QUERY_START_TIME)::TIMESTAMP_NTZ >= w.TELEMETRY_FROM)
        AS TELEMETRY_AVAILABLE,
      (CONVERT_TIMEZONE('UTC', th.QUERY_START_TIME)::TIMESTAMP_NTZ >= w.TELEMETRY_FROM
        AND logs.QUERY_ID IS NULL AND th.COMPLETED_TIME IS NOT NULL)
        AS CONTAINER_NEVER_STARTED
    FROM th
    CROSS JOIN w
    LEFT JOIN logs ON logs.QUERY_ID = th.QUERY_ID
    LEFT JOIN m    ON m.QUERY_ID    = th.QUERY_ID
  ) s
  ON tr.QUERY_ID = s.QUERY_ID
  WHEN MATCHED THEN UPDATE SET
    PIPELINE = s.PIPELINE, TASK_NAME = s.TASK_NAME, SERVICE_NAME = s.SERVICE_NAME,
    COMPUTE_POOL = s.COMPUTE_POOL, NODE_INSTANCE_FAMILY = s.NODE_INSTANCE_FAMILY,
    HISTORY_SOURCE = s.HISTORY_SOURCE, STATE = s.STATE,
    TASK_ERROR_MESSAGE = s.TASK_ERROR_MESSAGE, EXIT_STATUS = s.EXIT_STATUS,
    SCHEDULED_TIME = s.SCHEDULED_TIME, RUN_STARTED_AT = s.RUN_STARTED_AT,
    RUN_ENDED_AT = s.RUN_ENDED_AT, DURATION_S = s.DURATION_S,
    CONTAINER_SPAN_S = s.CONTAINER_SPAN_S, STARTUP_OVERHEAD_S = s.STARTUP_OVERHEAD_S,
    LOG_LINES = s.LOG_LINES, ERROR_LINES = s.ERROR_LINES,
    WARNING_LINES = s.WARNING_LINES, UNPARSED_LINES = s.UNPARSED_LINES,
    PIPELINE_FROM_LOG = s.PIPELINE_FROM_LOG, METRIC_SAMPLES = s.METRIC_SAMPLES,
    CPU_CORES_MAX = s.CPU_CORES_MAX, CPU_SAMPLES = s.CPU_SAMPLES,
    CPU_CORES_LIMIT = s.CPU_CORES_LIMIT, CPU_CORES_REQUESTED = s.CPU_CORES_REQUESTED,
    MEM_BYTES_MAX = s.MEM_BYTES_MAX, MEM_SAMPLES = s.MEM_SAMPLES,
    MEM_BYTES_LIMIT = s.MEM_BYTES_LIMIT, MEM_BYTES_REQUESTED = s.MEM_BYTES_REQUESTED,
    RESTARTS = s.RESTARTS, NET_RX_BYTES = s.NET_RX_BYTES, NET_TX_BYTES = s.NET_TX_BYTES,
    TELEMETRY_AVAILABLE = s.TELEMETRY_AVAILABLE,
    CONTAINER_NEVER_STARTED = s.CONTAINER_NEVER_STARTED,
    REFRESHED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT
    (PIPELINE, TASK_NAME, QUERY_ID, SERVICE_NAME, COMPUTE_POOL, NODE_INSTANCE_FAMILY,
     HISTORY_SOURCE, STATE, TASK_ERROR_MESSAGE, EXIT_STATUS, SCHEDULED_TIME,
     RUN_STARTED_AT, RUN_ENDED_AT, DURATION_S, CONTAINER_SPAN_S, STARTUP_OVERHEAD_S,
     LOG_LINES, ERROR_LINES, WARNING_LINES, UNPARSED_LINES, PIPELINE_FROM_LOG,
     METRIC_SAMPLES, CPU_CORES_MAX, CPU_SAMPLES, CPU_CORES_LIMIT, CPU_CORES_REQUESTED,
     MEM_BYTES_MAX, MEM_SAMPLES, MEM_BYTES_LIMIT, MEM_BYTES_REQUESTED,
     RESTARTS, NET_RX_BYTES, NET_TX_BYTES, TELEMETRY_AVAILABLE, CONTAINER_NEVER_STARTED,
     REFRESHED_AT)
  VALUES
    (s.PIPELINE, s.TASK_NAME, s.QUERY_ID, s.SERVICE_NAME, s.COMPUTE_POOL, s.NODE_INSTANCE_FAMILY,
     s.HISTORY_SOURCE, s.STATE, s.TASK_ERROR_MESSAGE, s.EXIT_STATUS, s.SCHEDULED_TIME,
     s.RUN_STARTED_AT, s.RUN_ENDED_AT, s.DURATION_S, s.CONTAINER_SPAN_S, s.STARTUP_OVERHEAD_S,
     s.LOG_LINES, s.ERROR_LINES, s.WARNING_LINES, s.UNPARSED_LINES, s.PIPELINE_FROM_LOG,
     s.METRIC_SAMPLES, s.CPU_CORES_MAX, s.CPU_SAMPLES, s.CPU_CORES_LIMIT, s.CPU_CORES_REQUESTED,
     s.MEM_BYTES_MAX, s.MEM_SAMPLES, s.MEM_BYTES_LIMIT, s.MEM_BYTES_REQUESTED,
     s.RESTARTS, s.NET_RX_BYTES, s.NET_TX_BYTES, s.TELEMETRY_AVAILABLE, s.CONTAINER_NEVER_STARTED,
     CURRENT_TIMESTAMP());
  runs_n := SQLROWCOUNT;

  -- -------------------------------------------------------------------------
  -- Step 3: PIPELINE_RUNS, one MERGE per sport, sports discovered at run time.
  -- EXECUTE IMMEDIATE because the database name is composed per iteration
  -- (the SP_DBT_BUILD precedent). STARTSWITH instead of LIKE-with-ESCAPE keeps
  -- the dynamic string free of backslash escaping.
  --
  -- THE JOIN IS A TIME WINDOW, still the weakest link: _DLT_RUNS carries no
  -- query id, so a row matches by pipeline name + finished-inside-the-window.
  -- The QUALIFY is NOT optional here: the old view tolerated a double-match as
  -- an extra row; a MERGE source with two rows per QUERY_ID throws "Duplicate
  -- row detected" and fails the whole refresh.
  --
  -- Two different history boundaries, still: DLT_RECORD_MISSING guards on THIS
  -- database's MIN(FINISHED_AT), never on the telemetry boundary (they are a
  -- week apart and using the wrong one silently blanks the column).
  -- -------------------------------------------------------------------------
  FOR sp IN sports DO
    BEGIN
      merge_sql :=
        'MERGE INTO DLT_DB.OPS.PIPELINE_RUNS p USING ('
     || ' WITH dlt_runs AS ('
     || '   SELECT r._DLT_ID, r.PIPELINE, r.STATUS, r.LOAD_ID, r.FINISHED_AT, r.ERROR, r.RESOURCES,'
     || '          ANY_VALUE(r.ROW_COUNTS) AS ROW_COUNTS,'
     || '          SUM(CASE WHEN f.key = ''_dlt_pipeline_state'' THEN 0 ELSE f.value::number END) AS ROWS_LOADED'
     || '   FROM ' || sp.STEM || '_PROD_DB.OPS._DLT_RUNS r,'
     || '        LATERAL FLATTEN(input => r.ROW_COUNTS, outer => TRUE) f'
     || '   GROUP BY r._DLT_ID, r.PIPELINE, r.STATUS, r.LOAD_ID, r.FINISHED_AT, r.ERROR, r.RESOURCES'
     || ' ),'
     || ' dw AS (SELECT MIN(FINISHED_AT) AS DLT_RUNS_FROM FROM ' || sp.STEM || '_PROD_DB.OPS._DLT_RUNS)'
     || ' SELECT ''' || sp.STEM || ''' AS SPORT,'
     || '   t.PIPELINE, t.TASK_NAME, t.QUERY_ID, t.SERVICE_NAME, t.COMPUTE_POOL,'
     || '   t.RUN_STARTED_AT, t.RUN_ENDED_AT, t.DURATION_S, t.CONTAINER_SPAN_S, t.STARTUP_OVERHEAD_S,'
     || '   t.STATE AS TASK_STATE, d.STATUS AS DLT_STATUS,'
     || '   (t.STATE = ''SUCCEEDED'' AND d.STATUS IS DISTINCT FROM ''ok'') AS OUTCOME_DISAGREES,'
     || '   (d._DLT_ID IS NULL AND t.RUN_STARTED_AT >= dw.DLT_RUNS_FROM) AS DLT_RECORD_MISSING,'
     -- _DLT_RUNS.RESOURCES is a VARCHAR holding JSON (found live: a bare
     -- d.RESOURCES fails the INSERT arm with "expecting VARIANT but got
     -- VARCHAR"). ROW_COUNTS by contrast IS a VARIANT. The COALESCE keeps a
     -- hypothetical non-JSON string rather than dropping it to NULL.
     || '   d.ROWS_LOADED, d.ROW_COUNTS, d.LOAD_ID,'
     || '   COALESCE(TRY_PARSE_JSON(d.RESOURCES), TO_VARIANT(d.RESOURCES)) AS RESOURCES,'
     || '   COALESCE(d.ERROR, t.TASK_ERROR_MESSAGE) AS ERROR_TEXT, t.EXIT_STATUS,'
     || '   t.LOG_LINES, t.ERROR_LINES, t.WARNING_LINES, t.UNPARSED_LINES,'
     || '   t.METRIC_SAMPLES, t.CPU_CORES_MAX, t.CPU_SAMPLES, t.CPU_CORES_LIMIT,'
     || '   t.MEM_BYTES_MAX, t.MEM_SAMPLES, t.MEM_BYTES_REQUESTED, t.RESTARTS,'
     || '   t.TELEMETRY_AVAILABLE, t.CONTAINER_NEVER_STARTED'
     || ' FROM DLT_DB.OPS.TASK_RUNS t'
     || ' CROSS JOIN dw'
     || ' LEFT JOIN dlt_runs d'
     || '        ON d.PIPELINE = t.PIPELINE'
     || '       AND d.FINISHED_AT BETWEEN t.RUN_STARTED_AT AND t.RUN_ENDED_AT'
     || ' WHERE STARTSWITH(t.PIPELINE, ''' || LOWER(sp.STEM) || '_'')'
     || '   AND t.RUN_STARTED_AT >= DATEADD(''day'', -' || win_days || ', CURRENT_TIMESTAMP())'
     || ' QUALIFY ROW_NUMBER() OVER (PARTITION BY t.QUERY_ID ORDER BY d.FINISHED_AT DESC NULLS LAST) = 1'
     || ' ) s ON p.QUERY_ID = s.QUERY_ID'
     || ' WHEN MATCHED THEN UPDATE SET'
     || '   SPORT = s.SPORT, PIPELINE = s.PIPELINE, TASK_NAME = s.TASK_NAME,'
     || '   SERVICE_NAME = s.SERVICE_NAME, COMPUTE_POOL = s.COMPUTE_POOL,'
     || '   RUN_STARTED_AT = s.RUN_STARTED_AT, RUN_ENDED_AT = s.RUN_ENDED_AT,'
     || '   DURATION_S = s.DURATION_S, CONTAINER_SPAN_S = s.CONTAINER_SPAN_S,'
     || '   STARTUP_OVERHEAD_S = s.STARTUP_OVERHEAD_S, TASK_STATE = s.TASK_STATE,'
     || '   DLT_STATUS = s.DLT_STATUS, OUTCOME_DISAGREES = s.OUTCOME_DISAGREES,'
     || '   DLT_RECORD_MISSING = s.DLT_RECORD_MISSING, ROWS_LOADED = s.ROWS_LOADED,'
     || '   ROW_COUNTS = s.ROW_COUNTS, LOAD_ID = s.LOAD_ID, RESOURCES = s.RESOURCES,'
     || '   ERROR_TEXT = s.ERROR_TEXT, EXIT_STATUS = s.EXIT_STATUS,'
     || '   LOG_LINES = s.LOG_LINES, ERROR_LINES = s.ERROR_LINES,'
     || '   WARNING_LINES = s.WARNING_LINES, UNPARSED_LINES = s.UNPARSED_LINES,'
     || '   METRIC_SAMPLES = s.METRIC_SAMPLES, CPU_CORES_MAX = s.CPU_CORES_MAX,'
     || '   CPU_SAMPLES = s.CPU_SAMPLES, CPU_CORES_LIMIT = s.CPU_CORES_LIMIT,'
     || '   MEM_BYTES_MAX = s.MEM_BYTES_MAX, MEM_SAMPLES = s.MEM_SAMPLES,'
     || '   MEM_BYTES_REQUESTED = s.MEM_BYTES_REQUESTED, RESTARTS = s.RESTARTS,'
     || '   TELEMETRY_AVAILABLE = s.TELEMETRY_AVAILABLE,'
     || '   CONTAINER_NEVER_STARTED = s.CONTAINER_NEVER_STARTED,'
     || '   REFRESHED_AT = CURRENT_TIMESTAMP()'
     || ' WHEN NOT MATCHED THEN INSERT'
     || '   (SPORT, PIPELINE, TASK_NAME, QUERY_ID, SERVICE_NAME, COMPUTE_POOL,'
     || '    RUN_STARTED_AT, RUN_ENDED_AT, DURATION_S, CONTAINER_SPAN_S, STARTUP_OVERHEAD_S,'
     || '    TASK_STATE, DLT_STATUS, OUTCOME_DISAGREES, DLT_RECORD_MISSING, ROWS_LOADED,'
     || '    ROW_COUNTS, LOAD_ID, RESOURCES, ERROR_TEXT, EXIT_STATUS,'
     || '    LOG_LINES, ERROR_LINES, WARNING_LINES, UNPARSED_LINES,'
     || '    METRIC_SAMPLES, CPU_CORES_MAX, CPU_SAMPLES, CPU_CORES_LIMIT,'
     || '    MEM_BYTES_MAX, MEM_SAMPLES, MEM_BYTES_REQUESTED, RESTARTS,'
     || '    TELEMETRY_AVAILABLE, CONTAINER_NEVER_STARTED, REFRESHED_AT)'
     || ' VALUES'
     || '   (s.SPORT, s.PIPELINE, s.TASK_NAME, s.QUERY_ID, s.SERVICE_NAME, s.COMPUTE_POOL,'
     || '    s.RUN_STARTED_AT, s.RUN_ENDED_AT, s.DURATION_S, s.CONTAINER_SPAN_S, s.STARTUP_OVERHEAD_S,'
     || '    s.TASK_STATE, s.DLT_STATUS, s.OUTCOME_DISAGREES, s.DLT_RECORD_MISSING, s.ROWS_LOADED,'
     || '    s.ROW_COUNTS, s.LOAD_ID, s.RESOURCES, s.ERROR_TEXT, s.EXIT_STATUS,'
     || '    s.LOG_LINES, s.ERROR_LINES, s.WARNING_LINES, s.UNPARSED_LINES,'
     || '    s.METRIC_SAMPLES, s.CPU_CORES_MAX, s.CPU_SAMPLES, s.CPU_CORES_LIMIT,'
     || '    s.MEM_BYTES_MAX, s.MEM_SAMPLES, s.MEM_BYTES_REQUESTED, s.RESTARTS,'
     || '    s.TELEMETRY_AVAILABLE, s.CONTAINER_NEVER_STARTED, CURRENT_TIMESTAMP())';
      EXECUTE IMMEDIATE :merge_sql;
      sports_ok := sports_ok + 1;
    EXCEPTION
      WHEN OTHER THEN
        -- A sport with no _DLT_RUNS yet (dlt creates it on first run, no DDL
        -- declares it) must not fail the refresh for every other sport.
        sports_err := sports_err + 1;
        err_note := ' last_sport_error(' || sp.STEM || '): ' || SQLERRM;
    END;
  END FOR;

  -- TASK_HISTORY.RETURN_VALUE comes ONLY from SYSTEM$SET_RETURN_VALUE (a proc's
  -- RETURN never reaches it), the function demands a constant (hence EXECUTE
  -- IMMEDIATE assembling a literal), and it errors outside a task (hence the
  -- guard). All three verified on SP_DBT_BUILD.
  BEGIN
    EXECUTE IMMEDIATE 'SELECT SYSTEM$SET_RETURN_VALUE(''logs +' || logs_n
      || ', metrics +' || metrics_n || ', runs ' || runs_n
      || ', sports ' || sports_ok || ' ok/' || sports_err || ' err'')';
  EXCEPTION
    WHEN OTHER THEN
      NULL;
  END;

  RETURN 'logs +' || logs_n || ', metrics +' || metrics_n
      || ', task_runs merged ' || runs_n
      || ', sports ' || sports_ok || ' ok / ' || sports_err || ' err'
      || IFF(use_hist, ' (account_usage backfill ran)', '')
      || err_note;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. The sweep helper. THE OBVIOUS DESIGN DOES NOT WORK AND WAS TRIED:
-- `EXECUTE TASK OBS_REFRESH` does NOT bypass a triggered task's WHEN clause.
-- With drained streams the manual fire lands in task history as SKIPPED
-- ("Conditional expression for task evaluated to false") -- which is exactly
-- the zero-event case the sweep exists for. Found live, 2026-08-09.
--
-- So the sweep calls SP_OBS_REFRESH directly, and the single-writer guarantee
-- is replaced by an in-flight check: skip if OBS_REFRESH is EXECUTING or has a
-- pending SCHEDULED fire (verified: no SCHEDULED row lingers at rest for a
-- triggered task with empty streams). The residual race -- stream data arriving
-- in the instant between check and call -- needs the sweep's 4-hour tick to
-- coincide with an event flush to the second; accepted.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_OBS_SWEEP()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Timed backstop for runs that write no events (container never started; final verdict after the last flush): runs SP_OBS_REFRESH unless a triggered fire is already in flight.'
EXECUTE AS CALLER
AS
$$
DECLARE
  inflight INTEGER;
BEGIN
  inflight := (SELECT COUNT(*)
               FROM TABLE(DLT_DB.INFORMATION_SCHEMA.TASK_HISTORY(
                 TASK_NAME => 'OBS_REFRESH', RESULT_LIMIT => 10))
               WHERE STATE IN ('EXECUTING', 'SCHEDULED'));
  IF (inflight > 0) THEN
    RETURN 'skipped: OBS_REFRESH in flight';
  END IF;
  CALL DLT_DB.OPS.SP_OBS_REFRESH();
  RETURN 'swept';
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Compatibility view. V_TASK_RUNS keeps its name and columns; only the
-- innards changed. COPY GRANTS preserves existing SELECT grants across the
-- redefinition. (The per-sport V_PIPELINE_RUNS views are NOT recreated: the
-- dashboard reads PIPELINE_RUNS directly, and sql/sources/<name>/04 drops them.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW DLT_DB.OPS.V_TASK_RUNS
    COPY GRANTS
    COMMENT = 'Thin passthrough over DLT_DB.OPS.TASK_RUNS (materialised 2026-08; refresh logic lives in SP_OBS_REFRESH).'
AS
SELECT * FROM DLT_DB.OPS.TASK_RUNS;

GRANT SELECT ON TABLE DLT_DB.OPS.TASK_RUNS     TO ROLE DLT_DEV_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.PIPELINE_RUNS TO ROLE DLT_DEV_ROLE;
GRANT SELECT ON VIEW  DLT_DB.OPS.V_TASK_RUNS   TO ROLE DLT_DEV_ROLE;

-- ---------------------------------------------------------------------------
-- 6. The tasks. Names deliberately do NOT start with DLT_TASK_ (that prefix
-- becomes a pipeline row in the TASK_RUNS merge filter; see ops/05 for the
-- original warning). Not managed by generate_tasks.py; suspend-before-alter is
-- built in here, and the RESUMEs are not redundant: CREATE OR ALTER TASK leaves
-- a task suspended.
--
-- On a FIRST apply the resumes below mean the streams' SHOW_INITIAL_ROWS
-- content triggers the bootstrap parse within about a minute, and the empty
-- TASK_RUNS watermark makes that same fire run the ACCOUNT_USAGE backfill:
-- applying this file IS the bootstrap.
-- ---------------------------------------------------------------------------
ALTER TASK IF EXISTS DLT_DB.OPS.OBS_REFRESH_SWEEP SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.OBS_REFRESH SUSPEND;
ALTER TASK IF EXISTS DLT_DB.OPS.OBS_COPY SUSPEND;

CREATE OR ALTER TASK DLT_DB.OPS.OBS_REFRESH
  WAREHOUSE = DLT_WH
  -- Hourly, not 60: at 60s a long-running container (the postgres copies) kept
  -- this firing continuously and the ops warehouse awake around the clock (~24
  -- credits/day, measured 2026-08-24). With daily ingest windows the streams
  -- only fill around them, so this self-reduces to a few fires a day.
  -- Freshness between fires comes from the dashboard's manual refresh
  -- (SP_OBS_SWEEP).
  USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 3600
  USER_TASK_TIMEOUT_MS = 600000
  COMMENT = 'Event-driven observability refresh: drains the ops/02+03 streams and re-merges TASK_RUNS / PIPELINE_RUNS. NOT managed by generate_tasks.py.'
  WHEN SYSTEM$STREAM_HAS_DATA('DLT_DB.OPS.STREAM_OBS_LOGS')
    OR SYSTEM$STREAM_HAS_DATA('DLT_DB.OPS.STREAM_OBS_METRICS')
AS
  CALL DLT_DB.OPS.SP_OBS_REFRESH();

-- Metrics flush later than logs (the "straddled run" note in ops/01), which the
-- OR above absorbs; the sweep covers the zero-event cases the OR cannot.
-- Twice daily, riding the warm periods behind the two NFL builds (12:30 and
-- 22:30) rather than waking the warehouse on its own six times a day. The
-- detection bound for a zero-event failure grows to <=12h, proportionate now
-- that ingestion itself is daily.
CREATE OR ALTER TASK DLT_DB.OPS.OBS_REFRESH_SWEEP
  WAREHOUSE = DLT_WH
  SCHEDULE  = 'USING CRON 15 13,23 * * * UTC'
  COMMENT   = 'Backstop poke of OBS_REFRESH twice daily: bounds how long a zero-event failure or a stale EXECUTING state can sit unrecorded. NOT managed by generate_tasks.py.'
AS
  CALL DLT_DB.OPS.SP_OBS_SWEEP();

-- Child before parent. IF EXISTS: OBS_COPY is created by ops/11, after the
-- standalone loader Task exists. Re-applying this file before 11 must not fail.
ALTER TASK IF EXISTS DLT_DB.OPS.OBS_COPY RESUME;
ALTER TASK DLT_DB.OPS.OBS_REFRESH RESUME;
ALTER TASK DLT_DB.OPS.OBS_REFRESH_SWEEP RESUME;
