-- =============================================================================
-- ops/10_headlines.sql
-- =============================================================================
-- Purpose       : AI ops headlines: once a day, feed the day's telemetry
--                 (PIPELINE_RUNS, DBT_BUILDS, ALERT_STATE, a 14-day form
--                 guide) to Cortex AI_COMPLETE with a structured-output
--                 schema and store <= 5 sports-desk headlines in
--                 DLT_DB.OPS.HEADLINES for the dashboard's Headlines panel.
-- Run as        : ACCOUNTADMIN (Cortex grant), then DBT_RUNNER_ROLE (one
--                 cross-grant on DBT_BUILDS), then DLT_LOADER_ROLE (table,
--                 proc, task, cost tag).
-- Prerequisites : ops/04 (PIPELINE_RUNS), ops/06 (DBT_BUILDS), ops/08
--                 (COST_CENTER tag + APPLY grants), ops/09 (ALERT_STATE).
-- Apply         : make setup-ops CONFIRM=1  (or snow sql -f directly)
--
-- BEST-EFFORT BY DESIGN, like alerts.py: headlines are decoration on top of
-- telemetry that already exists elsewhere. SP_HEADLINES swallows every error
-- and returns a string; it must never page anyone, never fail a chain, and a
-- day with no wire is a shrug, not an incident. The one thing it protects is
-- yesterday's-run-today idempotency: the day's rows are replaced only AFTER
-- a successful model call, so a failed call leaves the last good wire up.
--
-- THE CORTEX FACTS THIS FILE STANDS ON (verified against docs 2026-08-15):
--   * AI_COMPLETE is the successor of SNOWFLAKE.CORTEX.COMPLETE and is
--     called UNQUALIFIED (the SNOWFLAKE.CORTEX.AI_COMPLETE entries visible
--     in SHOW FUNCTIONS are plumbing; every documented example is bare).
--       docs.snowflake.com/en/sql-reference/functions/ai_complete
--   * Signature (single-string form), positional or named:
--       AI_COMPLETE(<model>, <prompt> [, <model_parameters>,
--                   <response_format>, <show_details>])
--     model_parameters keys: temperature, top_p, max_tokens (default 4096),
--     guardrails.
--       docs.snowflake.com/en/sql-reference/functions/ai_complete-single-string
--   * Structured output: response_format => {'type':'json','schema':{...}}
--     (a JSON-schema object constant). EVERY model AI_COMPLETE supports can
--     do structured output. Schema keywords beyond type/properties/required
--     (enum, maxItems) may not be enforced by every model, so the prompt
--     repeats those rules and the INSERT clamps them again -- three fences.
--       docs.snowflake.com/en/user-guide/snowflake-cortex/complete-structured-outputs
--   * TOKEN COUNTS EXIST ONLY WITH show_details => TRUE. The detailed
--     response is an OBJECT:
--       { model, created, structured_output: [ { raw_message: {...}, type:
--         'json' } ], usage: { prompt_tokens, completion_tokens, ... } }
--     Without show_details you get the bare structured object and NO usage.
--     This proc always passes TRUE: the token columns are the cost record.
--   * Privileges: calling AI_COMPLETE needs the account privilege USE AI
--     FUNCTIONS plus the database role SNOWFLAKE.CORTEX_USER. BOTH are
--     granted to PUBLIC by default; on this account DLT_LOADER_ROLE also
--     holds CORTEX_USER explicitly (rode in with the 2026-08-09 IMPORTED
--     PRIVILEGES slice, verified via SHOW GRANTS 2026-08-15). Section 1
--     pins it anyway: a task session runs the owner's PRIMARY role alone
--     (the ops/01 lesson), and PUBLIC/IMPORTED defaults are exactly the
--     kind of ambient grant a future hardening pass revokes.
--       docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-privileges-and-access
--   * No documented owner's-vs-caller's-rights restriction on AI_COMPLETE
--     in procs (unlike the QUERY_HISTORY functions ops/06 fought). The only
--     documented special case is EXECUTE AS RESTRICTED CALLER, which this
--     file does not use. EXECUTE AS CALLER below is house style, not a
--     Cortex requirement. NOT yet smoke-tested from a task session on this
--     account: run the read-back CALL as DLT_LOADER_ROLE before resuming
--     the task.
--   * Region/model reach: this account runs in AWS_US_EAST_2, which is NOT
--     on the native model-hosting lists, but CORTEX_ENABLED_CROSS_REGION =
--     'ANY_REGION' (account level, verified 2026-08-15), so any AI_COMPLETE
--     model resolves via cross-region inference. If that parameter is ever
--     tightened, revisit the model choice here.
--       docs.snowflake.com/en/user-guide/snowflake-cortex/aisql-regional-availability
--
-- MODEL AND COST (Service Consumption Table 6(a), AI credits per 1M tokens;
-- read from the 2026 table -- repo copy at /CreditConsumptionTable (3).pdf):
--   claude-haiku-4-5   0.60 in / 3.00 out   <- chosen: cheap, strong editor
--   claude-sonnet-4-6  1.80 in / 9.00 out      (upgrade path if the register
--                                               disappoints)
--   mistral-large2     1.20 in / 3.60 out
--   llama3.3-70b       0.432 in / 0.432 out    (cheapest credible fallback)
-- One call per day, digest capped ~5k input tokens, <= ~600 output tokens:
-- claude-haiku-4-5 costs about 0.005 AI credits per day, ~1.8 per year.
-- The warehouse second or two DLT_WH spends on the digest SQL costs
-- more than the model does. Full arithmetic in the read-back section.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: Cortex access (ACCOUNTADMIN -- database roles on the SNOWFLAKE
-- database can only be granted from there)
-- -----------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

-- Belt and suspenders, not a new capability: DLT_LOADER_ROLE already holds
-- CORTEX_USER via the IMPORTED PRIVILEGES slice (and PUBLIC holds it by
-- default). Pinning it here means the headlines survive either of those
-- being narrowed later. Idempotent; re-grant is a no-op.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE DLT_LOADER_ROLE;

-- USE AI FUNCTIONS (account privilege) is granted to PUBLIC by default and
-- is NOT re-granted here: granting account-level privileges per role is an
-- account-hardening decision, not this file's. If AI_COMPLETE ever fails
-- with an authorization error despite CORTEX_USER, check:
--   SHOW GRANTS TO ROLE PUBLIC;   -- look for USE AI FUNCTIONS
-- and if it was revoked, grant the narrow form:
--   GRANT USE AI FUNCTION AI_COMPLETE ON ACCOUNT TO ROLE DLT_LOADER_ROLE;

-- -----------------------------------------------------------------------------
-- Section 2: one cross-grant (DBT_RUNNER_ROLE owns DBT_BUILDS, ops/06)
-- -----------------------------------------------------------------------------

USE ROLE DBT_RUNNER_ROLE;

-- Verified missing 2026-08-15: DBT_BUILDS granted SELECT only to
-- DLT_DEV_ROLE. Without this, SP_HEADLINES dies on its dbt leg and the
-- exception handler turns every wire into 'headlines skipped'.
GRANT SELECT ON TABLE DLT_DB.OPS.DBT_BUILDS TO ROLE DLT_LOADER_ROLE;

-- -----------------------------------------------------------------------------
-- Section 3: the wire (DLT_LOADER_ROLE owns it, like the other ops tables)
-- -----------------------------------------------------------------------------

USE ROLE DLT_LOADER_ROLE;

-- One row per headline, <= 5 per day, today's rows replaced wholesale by
-- each run. SEQ preserves the model's worst-first ordering (0 = lead story)
-- so the dashboard renders the wire without re-deriving severity order.
-- MODEL + token columns are the cost record: SUM(PROMPT_TOKENS) per MODEL
-- is the reconciliation against CORTEX_AI_FUNCTIONS_USAGE_HISTORY.
CREATE TABLE IF NOT EXISTS DLT_DB.OPS.HEADLINES (
  GENERATED_AT      TIMESTAMP_TZ,   -- when this wire was set
  DAY               DATE,           -- the day the wire covers (session-TZ day)
  SEQ               NUMBER,         -- position in the wire, 0 = lead story
  SEVERITY          VARCHAR,        -- 'fail' | 'warn' | 'ok' | 'info'
  KIND              VARCHAR,        -- 'ingestion' | 'dbt' | 'alerting' | 'platform'
  ENTITY            VARCHAR,        -- pipeline name, 'dbt_build_<sport>', 'platform'
  HEADLINE          VARCHAR,        -- <= 200 chars, sports-desk register
  DETAIL            VARCHAR,        -- 1-2 sentences of specifics
  MODEL             VARCHAR,        -- model that wrote the wire (from the response)
  PROMPT_TOKENS     NUMBER,         -- usage.prompt_tokens (per CALL, repeated per row)
  COMPLETION_TOKENS NUMBER          -- usage.completion_tokens (ditto)
)
COMMENT = 'AI-written daily ops headlines for the dashboard Headlines panel. Rebuilt once a day by SP_HEADLINES (task HEADLINES_DAILY); today''s rows are replaced idempotently. Retention: self-pruned to 90 days by the proc.';

-- DBT_RUNNER_ROLE per the workflow spec (harmless); DLT_DEV_ROLE mirrors
-- the ops/04 and ops/06 read grants. The dashboard's SPCS path connects as
-- DLT_LOADER_ROLE (the owner), so it reads without a grant -- the same way
-- it reads PIPELINE_RUNS.
GRANT SELECT ON TABLE DLT_DB.OPS.HEADLINES TO ROLE DBT_RUNNER_ROLE;
GRANT SELECT ON TABLE DLT_DB.OPS.HEADLINES TO ROLE DLT_DEV_ROLE;

-- -----------------------------------------------------------------------------
-- Section 4: the desk (the procedure)
-- -----------------------------------------------------------------------------
-- Digest shape and size: four legs, each aggressively capped, all keys with
-- NULL values dropped by OBJECT_CONSTRUCT (its default, and here a feature:
-- a clean run serializes to a fraction of a failed one).
--   todays_pipeline_runs  <= 60 rows, failures first so truncation only ever
--                         drops successes; errors clipped to 180 chars
--   todays_dbt_builds     <= 20 rows. DBT_BUILDS records SUCCESSES ONLY
--                         (ops/06: failed builds never get a row), and the
--                         prompt says so explicitly -- otherwise the model
--                         reads an empty list as a dbt outage.
--   alerts_touched_today  <= 20 ALERT_STATE rows with UPDATED_AT today
--   form_guide_14d        <= 40 pipelines: W-L over 14 days + live streak
-- Worst case ~20k chars ~= 5k tokens; typical quiet day ~2k chars. The
-- LEFT(..., 28000) on the digest is a cost fuse, not a working path: the
-- per-leg caps make it unreachable, and clipping mid-JSON would feed the
-- model a broken tail, so if it ever fires the wire degrades rather than
-- the spend growing unbounded.
--
-- 'Today' is the session-TZ day (task sessions run the account default
-- timezone). At the 12:00 UTC fire every 2026 morning slot (07:00-10:00
-- UTC) lands inside 'today' for any US timezone, which is the case that
-- matters; chasing exact UTC day edges here buys nothing.
--
-- A run outcome is TASK_STATE = 'SUCCEEDED', full stop -- TASK_HISTORY is
-- the spine (CLAUDE.md: _DLT_RUNS under-reports failures, and
-- OUTCOME_DISAGREES is also TRUE for the benign missing-record case, so it
-- would mislabel wins as losses). OUTCOME_DISAGREES rides along in the
-- digest as a fact the model may headline as 'warn', not as the verdict.
--
-- BINDS ARE SCALARS ONLY, deliberately: every value crossing a bind
-- boundary here is VARCHAR or NUMBER. Snowflake Scripting's VARIANT/ARRAY
-- binds are the shaky corner (the GET_QUERY_OPERATOR_STATS lesson's
-- cousin), so the response is decomposed in ONE SELECT ... INTO over the
-- AI_COMPLETE call, items travel as a JSON string, and the INSERT re-parses
-- with PARSE_JSON(:bind). model_parameters and response_format stay inline
-- object CONSTANTS exactly as the structured-outputs docs write them.
--
-- THE EDITORIAL RULES LIVE IN THE PROMPT BELOW. Why each exists:
--   * "worst first"            -> SEQ doubles as render order; no sorting
--                                 logic leaks into the dashboard
--   * "max 5"                  -> a panel, not a report; schema maxItems,
--                                 prompt, and the INSERT clamp all repeat it
--                                 because schema keyword enforcement is
--                                 model-dependent
--   * "only facts from the digest, with its numbers" -> the model gets no
--                                 tools and no history beyond the digest;
--                                 anything else it writes is invented
--   * "exactly one calm all-quiet item when nothing is wrong" -> an empty
--                                 panel is indistinguishable from a broken
--                                 one; the quiet-day wire proves liveness
--   * "sports-desk register"   -> the product voice (it is a sports data
--                                 platform); 'factual' is stated first so
--                                 the register never outranks the facts
--   * successes-only DBT_BUILDS caveat -> see digest shape above
CREATE OR REPLACE PROCEDURE DLT_DB.OPS.SP_HEADLINES()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Daily AI headlines: digest of PIPELINE_RUNS / DBT_BUILDS / ALERT_STATE + 14-day form guide -> AI_COMPLETE structured output -> replace today''s DLT_DB.OPS.HEADLINES rows. Best-effort: swallows every error (alerts.py philosophy); never let this page anyone.'
EXECUTE AS CALLER
AS
$$
DECLARE
  v_model      VARCHAR DEFAULT 'claude-haiku-4-5';  -- see header for the pricing table
  v_digest     VARCHAR;
  v_prompt     VARCHAR;
  v_items_json VARCHAR;   -- headlines array as a JSON string (scalar bind; see file comments)
  v_model_out  VARCHAR;
  v_ptok       NUMBER;
  v_ctok       NUMBER;
  v_n          INTEGER DEFAULT 0;
BEGIN

  -- ---------------------------------------------------------------------
  -- 1. The digest. One statement, four capped legs.
  -- ---------------------------------------------------------------------
  v_digest := (SELECT TO_JSON(OBJECT_CONSTRUCT(
    'day', TO_VARCHAR(CURRENT_DATE),
    'generated_at_utc', TO_VARCHAR(CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()), 'YYYY-MM-DD"T"HH24:MI"Z"'),

    'todays_pipeline_runs', (
      SELECT COALESCE(ARRAY_AGG(o), ARRAY_CONSTRUCT())
      FROM (
        SELECT OBJECT_CONSTRUCT(
                 'pipeline',   PIPELINE,
                 'sport',      SPORT,
                 'outcome',    TASK_STATE,
                 'rows_loaded', ROWS_LOADED,
                 'duration_s', DURATION_S,
                 'dlt_status', DLT_STATUS,
                 'outcome_disagrees',       IFF(COALESCE(OUTCOME_DISAGREES, FALSE), TRUE, NULL),
                 'container_never_started', IFF(COALESCE(CONTAINER_NEVER_STARTED, FALSE), TRUE, NULL),
                 'error',      LEFT(ERROR_TEXT, 180)
               ) AS o
        FROM DLT_DB.OPS.PIPELINE_RUNS
        WHERE RUN_STARTED_AT >= CURRENT_DATE
        ORDER BY IFF(TASK_STATE = 'SUCCEEDED', 1, 0), RUN_STARTED_AT DESC
        LIMIT 60
      )
    ),

    'todays_dbt_builds', (
      SELECT COALESCE(ARRAY_AGG(o), ARRAY_CONSTRUCT())
      FROM (
        SELECT OBJECT_CONSTRUCT(
                 'sport',         SPORT,
                 'environment',   ENVIRONMENT,
                 'args',          ARGS,
                 'drained_loads', DRAINED_LOADS,
                 'duration_s',    DATEDIFF('second', STARTED_AT, FINISHED_AT)
               ) AS o
        FROM DLT_DB.OPS.DBT_BUILDS
        WHERE STARTED_AT >= CURRENT_DATE
        ORDER BY STARTED_AT DESC
        LIMIT 20
      )
    ),

    'alerts_touched_today', (
      SELECT COALESCE(ARRAY_AGG(o), ARRAY_CONSTRUCT())
      FROM (
        SELECT OBJECT_CONSTRUCT(
                 'scope',         SCOPE,
                 'status',        STATUS,
                 'pinged_today',  IFF(LAST_ALERTED_AT >= CURRENT_DATE, TRUE, NULL),
                 'last_error',    LEFT(LAST_ERROR, 180)
               ) AS o
        FROM DLT_DB.OPS.ALERT_STATE
        WHERE UPDATED_AT >= CURRENT_DATE
        ORDER BY IFF(STATUS = 'failing', 0, 1), UPDATED_AT DESC
        LIMIT 20
      )
    ),

    -- Wins-losses and the live streak per pipeline, 14 days. FIRST_VALUE
    -- gives each row its pipeline's latest result; the streak is then "rows
    -- before the first result that differs from the latest", or all of them.
    'form_guide_14d', (
      SELECT COALESCE(ARRAY_AGG(o), ARRAY_CONSTRUCT())
      FROM (
        SELECT OBJECT_CONSTRUCT(
                 'pipeline', PIPELINE,
                 'record',   WINS || '-' || LOSSES,
                 'streak',   STREAK
               ) AS o
        FROM (
          WITH runs AS (
            SELECT PIPELINE,
                   IFF(TASK_STATE = 'SUCCEEDED', 'W', 'L') AS RES,
                   ROW_NUMBER()       OVER (PARTITION BY PIPELINE ORDER BY RUN_STARTED_AT DESC) AS RN,
                   FIRST_VALUE(IFF(TASK_STATE = 'SUCCEEDED', 'W', 'L'))
                                      OVER (PARTITION BY PIPELINE ORDER BY RUN_STARTED_AT DESC) AS LATEST
            FROM DLT_DB.OPS.PIPELINE_RUNS
            WHERE RUN_STARTED_AT >= DATEADD('day', -14, CURRENT_TIMESTAMP())
              AND TASK_STATE IN ('SUCCEEDED', 'FAILED', 'FAILED_AND_AUTO_SUSPENDED')
          )
          SELECT PIPELINE,
                 COUNT_IF(RES = 'W') AS WINS,
                 COUNT_IF(RES = 'L') AS LOSSES,
                 ANY_VALUE(LATEST)
                   || COALESCE(MIN(IFF(RES <> LATEST, RN, NULL)) - 1, COUNT(*)) AS STREAK
          FROM runs
          GROUP BY PIPELINE
          ORDER BY LOSSES DESC, PIPELINE
          LIMIT 40
        )
      )
    )
  )));

  -- ---------------------------------------------------------------------
  -- 2. The prompt: editorial rules (rationale in the block comment above
  -- the proc) + the digest behind a cost fuse.
  -- ---------------------------------------------------------------------
  v_prompt :=
       'You are the overnight desk editor for "weekend warriors", a sports-data '
    || 'pipeline platform (NFL and NCAAF ingestion + dbt builds on Snowflake). '
    || 'Below is a JSON digest of today''s operations telemetry. Write the day''s '
    || 'wire: an array of at most 5 headline items.'
    || '\n\nRules, in priority order:'
    || '\n1. Factual above all. Use ONLY facts and numbers present in the digest. '
    ||     'Never invent counts, names, times, or causes. If the digest is empty '
    ||     'or ambiguous, say less, not more.'
    || '\n2. Worst news first: failures, then warnings, then good news, then color.'
    || '\n3. severity: "fail" = a run or build failed today, or a pipeline is on a '
    ||     'losing streak. "warn" = degraded but not failed (outcome_disagrees, '
    ||     'container_never_started, an alert scope still failing, unusually slow '
    ||     'runs). "ok" = recoveries, clean sweeps, notable win streaks. '
    ||     '"info" = neutral color (volumes, records, milestones).'
    || '\n4. If NOTHING is wrong today, return exactly ONE item: severity "ok", a '
    ||     'calm all-quiet headline with the day''s totals. No padding items.'
    || '\n5. kind: "ingestion" (dlt pipeline runs), "dbt" (dbt builds), "alerting" '
    ||     '(ALERT_STATE items), "platform" (anything cross-cutting).'
    || '\n6. entity: the pipeline name, "dbt_build_<sport>", or "platform".'
    || '\n7. headline: one line, under 90 characters, sports-desk register -- '
    ||     'punchy, win/loss/streak language welcome, facts non-negotiable. '
    ||     'detail: 1-2 plain sentences with the specifics (rows, seconds, error '
    ||     'text), understandable by someone who has not seen the digest.'
    || '\n8. Context you must know: todays_dbt_builds records SUCCESSFUL builds '
    ||     'only -- an empty list means "no builds ran or none succeeded", never '
    ||     'assert a dbt failure from absence alone. form_guide_14d is per-pipeline '
    ||     'wins-losses over 14 days; streak like "W12" or "L3" is the current run. '
    ||     'rows_loaded of 0 on a success is normal on quiet sports days.'
    || '\n\n=== TODAY''S DIGEST (JSON) ===\n'
    || LEFT(v_digest, 28000);

  -- ---------------------------------------------------------------------
  -- 3. The model call, decomposed in one SELECT ... INTO so nothing but
  -- scalars crosses a bind boundary afterwards. show_details => TRUE is
  -- what makes usage.* exist at all (see file header). temperature 0.2:
  -- enough for register, not enough for invention. max_tokens 1500 bounds
  -- the output spend at ~0.0045 credits even if the model rambles.
  -- ---------------------------------------------------------------------
  SELECT r:model::VARCHAR,
         r:usage:prompt_tokens::NUMBER,
         r:usage:completion_tokens::NUMBER,
         TO_JSON(r:structured_output[0]:raw_message:headlines)
    INTO :v_model_out, :v_ptok, :v_ctok, :v_items_json
  FROM (
    SELECT AI_COMPLETE(
             model            => :v_model,
             prompt           => :v_prompt,
             model_parameters => {'temperature': 0.2, 'max_tokens': 1500},
             response_format  => {
               'type': 'json',
               'schema': {
                 'type': 'object',
                 -- NO maxItems here, and that is load-bearing: AI_COMPLETE
                 -- silently returns NULL for the WHOLE call when the schema
                 -- carries maxItems (isolated live 2026-08-15: identical call
                 -- works without it, enum keywords are fine). The 5-item cap
                 -- is enforced by prompt rule and the INSERT's INDEX < 5
                 -- fence instead.
                 'properties': {
                   'headlines': {
                     'type': 'array',
                     'items': {
                       'type': 'object',
                       'properties': {
                         'severity': {'type': 'string', 'enum': ['fail', 'warn', 'ok', 'info']},
                         'kind':     {'type': 'string', 'enum': ['ingestion', 'dbt', 'alerting', 'platform']},
                         'entity':   {'type': 'string'},
                         'headline': {'type': 'string'},
                         'detail':   {'type': 'string'}
                       },
                       'required': ['severity', 'kind', 'entity', 'headline', 'detail']
                     }
                   }
                 },
                 'required': ['headlines']
               }
             },
             show_details     => TRUE
           ) AS r
  );

  -- An empty or missing array means the model gave us nothing usable.
  -- Leave the last good wire in place rather than publishing a blank day.
  IF (v_items_json IS NULL OR v_items_json IN ('[]', 'null')) THEN
    RETURN 'headlines skipped: empty structured_output from ' || COALESCE(v_model_out, v_model);
  END IF;

  -- ---------------------------------------------------------------------
  -- 4. Replace today's wire. DELETE + INSERT, only reached after a good
  -- call: re-running the proc replaces the day; a failed call changes
  -- nothing. The statements autocommit individually, so a crash exactly
  -- between them leaves today blank until the next run -- accepted, the
  -- next CALL repairs it. WHERE f.INDEX < 5 is the last of the three
  -- max-5 fences; the severity/kind CASEs clamp a model that ignored the
  -- schema enums (enforcement is model-dependent, see header).
  -- ---------------------------------------------------------------------
  DELETE FROM DLT_DB.OPS.HEADLINES WHERE DAY = CURRENT_DATE;

  INSERT INTO DLT_DB.OPS.HEADLINES
    (GENERATED_AT, DAY, SEQ, SEVERITY, KIND, ENTITY, HEADLINE, DETAIL,
     MODEL, PROMPT_TOKENS, COMPLETION_TOKENS)
  SELECT
    CURRENT_TIMESTAMP(),
    CURRENT_DATE,
    f.INDEX,
    CASE WHEN LOWER(f.value:severity::VARCHAR) IN ('fail', 'warn', 'ok', 'info')
         THEN LOWER(f.value:severity::VARCHAR) ELSE 'info' END,
    CASE WHEN LOWER(f.value:kind::VARCHAR) IN ('ingestion', 'dbt', 'alerting', 'platform')
         THEN LOWER(f.value:kind::VARCHAR) ELSE 'platform' END,
    LEFT(f.value:entity::VARCHAR, 200),
    LEFT(f.value:headline::VARCHAR, 200),
    LEFT(f.value:detail::VARCHAR, 1000),
    :v_model_out,
    :v_ptok,
    :v_ctok
  FROM TABLE(FLATTEN(input => PARSE_JSON(:v_items_json))) f
  WHERE f.INDEX < 5;
  v_n := SQLROWCOUNT;

  -- Self-pruning retention, a deliberate deviation from the ops/05-06
  -- retention-task pattern: at <= 5 rows a day a dedicated task (or an edit
  -- to another file's proc) costs more than it keeps. 90 days matches the
  -- parsed-telemetry tier.
  DELETE FROM DLT_DB.OPS.HEADLINES WHERE DAY < DATEADD('day', -90, CURRENT_DATE);

  -- TASK_HISTORY.RETURN_VALUE comes only from SYSTEM$SET_RETURN_VALUE, which
  -- demands a constant and errors outside a task (the ops/04 pattern, all
  -- three quirks verified there).
  BEGIN
    EXECUTE IMMEDIATE 'SELECT SYSTEM$SET_RETURN_VALUE(''wire set: ' || v_n
      || ' headlines, ' || COALESCE(v_ptok, 0) || ' in / ' || COALESCE(v_ctok, 0) || ' out'')';
  EXCEPTION
    WHEN OTHER THEN
      NULL;
  END;

  RETURN 'wire set: ' || v_n || ' headlines (' || COALESCE(v_model_out, v_model)
      || ', ' || COALESCE(v_ptok, 0) || ' in / ' || COALESCE(v_ctok, 0) || ' out)';

EXCEPTION
  -- Headlines are best-effort, full stop (the alerts.py philosophy): any
  -- failure -- missing grant, model unavailable, malformed response --
  -- returns a string and leaves the last good wire up. Never let this
  -- surface as a task failure someone gets paged for.
  WHEN OTHER THEN
    RETURN 'headlines skipped: ' || SQLERRM;
END;
$$;

-- -----------------------------------------------------------------------------
-- Section 5: the press run (the task)
-- -----------------------------------------------------------------------------
-- 13:30 UTC: the daily NFL ingest window ends ~12:20 and its dbt build runs
-- at 12:30, so by 13:30 the day's story is in (and the warehouse is warm
-- from the 13:00 test and 13:15/13:30 sweeps).
-- Name deliberately does NOT start with DLT_TASK_ (that prefix would turn it
-- into a pipeline row in the ops/04 TASK_RUNS merge). NOT managed by
-- generate_tasks.py; suspend-before-alter built in, per the ops/04 pattern.
ALTER TASK IF EXISTS DLT_DB.OPS.HEADLINES_DAILY SUSPEND;

CREATE OR ALTER TASK DLT_DB.OPS.HEADLINES_DAILY
  WAREHOUSE = DLT_WH
  SCHEDULE = 'USING CRON 30 13 * * * UTC'
  USER_TASK_TIMEOUT_MS = 600000
  COMMENT = 'Daily AI headlines for the ops dashboard (SP_HEADLINES). Best-effort; a failure costs a day''s wire and nothing else. NOT managed by generate_tasks.py.'
AS
  CALL DLT_DB.OPS.SP_HEADLINES();

-- Left SUSPENDED on purpose (CREATE OR ALTER TASK leaves it so, and unlike
-- ops/04-07 this file does not resume): the first CALL should be the human
-- smoke test in the read-back below -- it exercises the Cortex grant from
-- this role and shows the actual token spend. When the wire reads well:
--   ALTER TASK DLT_DB.OPS.HEADLINES_DAILY RESUME;

-- Cost attribution, same trailing-ALTER convention as ops/08 (which already
-- grants this role APPLY on the tag). 'ops': observability machinery.
ALTER TASK DLT_DB.OPS.HEADLINES_DAILY SET TAG DLT_DB.OPS.COST_CENTER = 'ops';

-- -----------------------------------------------------------------------------
-- Section 6: read-back
-- -----------------------------------------------------------------------------
-- Smoke, AS DLT_LOADER_ROLE (interactive success as SYSADMIN proves nothing
-- about the task context -- primary role alone, the ops/01 lesson):
--
--   USE ROLE DLT_LOADER_ROLE;
--   CALL DLT_DB.OPS.SP_HEADLINES();
--     -- expect: 'wire set: N headlines (claude-haiku-4-5, ~3000 in / ~400 out)'
--     -- a 'headlines skipped: ...' return IS the error report; read it.
--
--   SELECT SEQ, SEVERITY, KIND, ENTITY, HEADLINE, DETAIL,
--          MODEL, PROMPT_TOKENS, COMPLETION_TOKENS
--   FROM DLT_DB.OPS.HEADLINES
--   WHERE DAY = CURRENT_DATE
--   ORDER BY SEQ;
--
--   -- then, when the wire reads well:
--   -- ALTER TASK DLT_DB.OPS.HEADLINES_DAILY RESUME;
--
-- Cost estimate (Consumption Table 6(a), claude-haiku-4-5 at 0.60 in /
-- 3.00 out AI credits per 1M tokens, one call per day):
--   input : ~700 tokens of rules + digest 2k (quiet) to 5k (bad day)
--           ~= 3k typical -> 3,000 * 0.60 / 1,000,000 = 0.0018 credits
--   output: <= 600 tokens -> 600 * 3.00 / 1,000,000  = 0.0018 credits
--   => ~0.004 credits/day typical, ~0.008 worst case; ~1.5-3 credits/year.
--   The DLT_WH seconds running the digest SQL cost more than the model.
-- Reconcile actuals: SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
-- (function AI_COMPLETE, ~2h lag) against SUM(PROMPT_TOKENS)/SUM(COMPLETION_
-- TOKENS) per MODEL here.
-- =============================================================================
