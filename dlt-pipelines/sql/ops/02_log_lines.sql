-- =============================================================================
-- ops/02_log_lines.sql
-- Purpose : Parse SPCS job container logs into one queryable row per log line.
-- Run as  : DLT_LOADER_ROLE, which owns it, matching every other prod object.
-- Prerequisites : ops/01_event_table.sql.
-- Apply   : make setup-ops CONFIRM=1
--
-- WHY A VIEW AND NOT A DYNAMIC TABLE
--   The design called for a dynamic table and that was over-engineering. Measured
--   before writing this: steady state at 30-day retention is about 74,000 rows, and
--   the full parse below over 14,800 rows returns in well under a second.
--
--   Three things decided it:
--
--     A dynamic table buys no retention here. It mirrors its source, so once
--     ops/04 trims the event table at 30 days the dynamic table trims with it.
--     That was the main reason to materialise and it does not hold.
--
--     The cost inverts. A dynamic table at TARGET_LAG '60 minutes' refreshes ~24
--     times a day with a 60-second billing minimum, roughly 0.4 credits a day, paid
--     whether or not anyone looks. A view costs only when queried, and this is
--     queried a few times a day.
--
--     Staleness is backwards for the use case. A dynamic table is up to TARGET_LAG
--     behind, and you read an ops view immediately after something fails, which is
--     exactly when an hour-old answer is worthless. Cutting the lag to a minute
--     multiplies the cost about fortyfold.
--
--   It also removes change tracking, incremental-vs-full refresh, the FLATTEN/SEQ
--   restriction and "can a dynamic table even source an event table" from the design
--   in one go. Converting this to a dynamic table later is a mechanical edit if
--   retention ever grows to a year and query volume grows with it.
--
-- FOUR WIRE FORMATS, NOT ONE, AND THE FOURTH ONLY APPEARS AFTER THE IMAGE CHANGE
--   Counts are from live data at the time of writing:
--
--     dlt          855  ts|[LEVEL]|pid|tid|logger|file|func:line|msg
--     stdlib       102  ts LEVEL logger msg           (may carry [pipeline=X])
--     continuation  12  raw traceback frames, no prefix at all
--     structured     8  bare msg; severity in RECORD, logger in SCOPE
--
--   `structured` is what snowflake-telemetry-python produces for the `dlt_pipeline`
--   logger. Its VALUE has NO prefix, because the formatter moved the timestamp,
--   level and logger into structured columns. The parse handles it by falling
--   through every regex to raw VALUE, which for those rows already is the clean
--   message. That is correct but it is luck rather than design, so it is stated here
--   rather than left for someone to discover by changing a regex.
--
--   Verified coverage on live data: severity and logger resolve for 100% of dlt,
--   stdlib and structured rows; continuation rows correctly resolve to NULL; and no
--   parsed MESSAGE retains a pipe delimiter.
--
-- SNOWFLAKE REGEX IS POSIX ERE
--   `(?:...)` is rejected with "no argument for repetition operator: ?". Bracket
--   classes stand in for escapes throughout: [|] for a pipe, [[] and []] for
--   brackets. That survives this file, any shell that quotes it, and anyone who
--   copies a fragment into a worksheet.
-- =============================================================================

USE ROLE DLT_LOADER_ROLE;

CREATE OR REPLACE VIEW DLT_DB.OPS.V_LOG_LINES
    COMMENT = 'One row per SPCS job container log line, parsed. Source: DLT_DB.OPS.DLT_EVENTS.'
AS
SELECT
    e.TIMESTAMP                                                    AS EVENT_TS,
    e.RESOURCE_ATTRIBUTES:"snow.query.id"::string                  AS QUERY_ID,
    e.RESOURCE_ATTRIBUTES:"snow.service.name"::string              AS SERVICE_NAME,
    e.RESOURCE_ATTRIBUTES:"snow.service.container.name"::string    AS CONTAINER_NAME,

    -- Which of the four shapes this line arrived in. Kept as a column so the parser
    -- reports its own coverage: a sudden rise in 'continuation' means a format
    -- changed underneath it, which is otherwise invisible because unparsed lines
    -- still return their raw text and look fine.
    CASE
        WHEN e.RECORD:severity_text IS NOT NULL                                THEN 'structured'
        WHEN e.VALUE::string RLIKE '^[0-9-]{10} [0-9:]{8},[0-9]{3}[|].*'       THEN 'dlt'
        WHEN e.VALUE::string RLIKE '^[0-9-]{10} [0-9:]{8},[0-9]{3} [A-Z]+ .*'  THEN 'stdlib'
        ELSE 'continuation'
    END                                                            AS LOG_FORMAT,

    -- Structured value first: it is authoritative when present. The regexes carry
    -- the other 97%, so they are the primary path and not a fallback awaiting
    -- deletion. Ordering them this way makes the definition correct both before and
    -- after the image change, which is what let the two ship independently.
    COALESCE(
        e.RECORD:severity_text::string,
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3}[|][[]([A-Z]+)[]]', 1, 1, 'e', 1),
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3} ([A-Z]+) ',        1, 1, 'e', 1)
    )                                                              AS SEVERITY,

    COALESCE(
        e.SCOPE:name::string,
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3}[|][[][A-Z]+[]][|][0-9]+[|][0-9]+[|]([A-Za-z0-9_.]+)[|]',
            1, 1, 'e', 1),
        REGEXP_SUBSTR(e.VALUE::string,
            '^[0-9-]{10} [0-9:]{8},[0-9]{3} [A-Z]+ ([A-Za-z0-9_.]+) ',
            1, 1, 'e', 1)
    )                                                              AS LOGGER_NAME,

    -- RECORD_ATTRIBUTES carries the pipeline as a first-class field on structured
    -- rows, which beats scraping it out of message text. NULLIF strips the '-'
    -- placeholder that _PipelineDefaultFilter substitutes when the LoggerAdapter was
    -- not used, so "unknown" reads as NULL in both the attribute and the text form.
    --
    -- Sparse by nature: only our own adapter emits it, so most rows are NULL. The
    -- run-summary layer promotes it to the whole run with MAX() per query id, and
    -- QUERY_ID is the reliable join. This is a cross-check, not the key.
    NULLIF(
        COALESCE(
            e.RECORD_ATTRIBUTES:"pipeline"::string,
            REGEXP_SUBSTR(e.VALUE::string, '[[]pipeline=([A-Za-z0-9_]+)[]]', 1, 1, 'e', 1)
        ), '-')                                                    AS PIPELINE,

    -- Message with its prefix removed. The dlt form is split on the seventh pipe
    -- rather than matched field by field, because the file and func:line fields
    -- vary enough that enumerating them invites a miss. 'es' flags: extract, and let
    -- `.` match a newline so a wrapped line is not truncated at the first break.
    --
    -- The final COALESCE arm returns VALUE unchanged, which is correct for both
    -- structured rows (already a bare message) and continuation rows (a raw
    -- traceback frame that should not be mangled).
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
    )                                                              AS MESSAGE,

    e.VALUE::string                                                AS RAW_LINE

FROM DLT_DB.OPS.DLT_EVENTS e
WHERE e.RECORD_TYPE = 'LOG'
  AND e.RESOURCE_ATTRIBUTES:"snow.service.type"::string = 'Job';

GRANT SELECT ON VIEW DLT_DB.OPS.V_LOG_LINES TO ROLE DLT_DEV_ROLE;

-- ---------------------------------------------------------------------------
-- EXPECT DUPLICATES, AND DO NOT DEDUPLICATE THEM HERE.
--   run.py calls logging.basicConfig() while configure_logging() separately attaches
--   a handler, so every `dlt_pipeline` message is emitted twice: once structured and
--   once as stdlib text. This view reports what the container actually wrote, which
--   is the job of the parsing layer.
--
--   A log tail that wants one copy per message should filter on LOG_FORMAT, e.g.
--   prefer 'structured' and fall back to 'stdlib'. Collapsing them here would hide a
--   real defect in the container and would have to guess which copy to keep.
--
--   The underlying fix is one line in run.py (propagate = False) and is not in scope
--   for the modelling layer.
-- ---------------------------------------------------------------------------
