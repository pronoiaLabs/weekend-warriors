# WORKFLOW-5: dbt observability log

Build log for the dbt-observability loop (query tags on every dbt query,
GET_QUERY_OPERATOR_STATS harvest into OPS tables, V_DBT_RUNS, cost tags,
and a dbt page + overview card on the ops dashboard), same format as
WORKFLOW-1/2/3/4. Plan of record: the approved "dbt observability" plan.
Branch: `feat/dbt-observability` off `main`.

Ground rules this loop (user-confirmed): full Snowflake write scope within
the planned objects, every statement also captured in sql/ files; throwaway
spike objects allowed and dropped; never touch RAW/RAW_STAGING content or
the 17 ingestion tasks (EXECUTE TASK fires for E2E allowed); capture
operator stats for ALL warehouse-executing queries per build; both QUERY_TAG
and object tags; dashboard gets a page plus an overview card; no push until
told.

## Phase 0 - spikes

**Ran:** throwaway `DLT_DB.DBT_SPIKE` sandbox (tables, procs, a triggered
root + child task graph), all as DBT_RUNNER_ROLE; dev-deployed the dev
project object carrying the real tagging edits (env.yml, profiles.yml,
macros/query_tags.sql) and ran a 2-model dev build with an ENV_VARS build id;
located and downloaded a live build's run_results.json. Sandbox dropped.

**Result: GATE GREEN, all five questions answered with evidence.**

- **S3, operator stats work inside a proc, but only via a bind.** `INSERT ...
  SELECT FROM TABLE(GET_QUERY_OPERATOR_STATS(:qid))` in a caller's-rights
  Scripting proc works first try (14 rows from a real WORKFLOW-4 merge
  query). The argument REJECTS a cursor record field (`invalid identifier
  'REC.QUERY_ID'`) and a LATERAL join (syntax error at `TABLE`); assigning to
  a local variable and passing `:qid` is the pattern. Timing: 10 queries in
  6.6s, ~660ms per call, so a full build's 150-250 warehouse queries costs
  roughly 1.5-2.5 min of XSMALL time. DBT_RUNNER_ROLE's existing OPERATE on
  DBT_WH satisfied the privilege check with no new grant.
- **S2, the QUERY_HISTORY prohibition is scoped to OWNER's-rights procs.**
  The docs say stored procedures cannot run Information Schema QUERY_HISTORY;
  empirically a caller's-rights proc ran QUERY_HISTORY_BY_WAREHOUSE fine
  (100 rows), while the owner's-rights twin failed with "Requested
  information on the current user is not accessible in stored procedure".
  Since EXECUTE DBT PROJECT already forces caller's rights on this chain,
  enumeration AND stats can live in ONE harvest proc; the planned
  two-child-task decomposition collapses to a single child task.
- **S4, a child task AFTER a TRIGGERED root works end to end.** Child created
  against the (suspended-by-default) triggered root, both resumed, one insert
  into the fake loads table: root fired at the interval window, child fired
  3s after root completion, and the child's caller's-rights proc successfully
  ran BOTH QUERY_HISTORY (200 rows) and GET_QUERY_OPERATOR_STATS (4 rows)
  from task context. The extra root evaluation that followed was SKIPPED
  (free), matching WORKFLOW-4.
- **S1, the managed dbt runtime honors all three tag layers.** profiles.yml
  `query_tag` from env.yml's new DBT_QUERY_TAG_BASE lands on non-model
  statements; the root-project `snowflake__set_query_tag` override wins the
  dispatch and stamps per-node JSON (`build_id` + `node`) on materialization
  queries; `ENV_VARS = ('DBT_BUILD_ID' = ...)` on EXECUTE DBT PROJECT flows
  through env_var() into the tag. Verified in QUERY_HISTORY_BY_WAREHOUSE on
  the dev warehouse. Note the two JSON spellings (tojson adds spaces, the
  literal base does not): the harvest must TRY_PARSE_JSON, never
  string-match.
- **S5, run_results.json survives with per-node query ids.** SYSTEM$LOCATE_
  DBT_ARTIFACTS on the morning's live WNBA build returned a snow:// path;
  run_results.json holds 629 nodes, 628 with adapter_response.query_id plus
  per-node status and execution_time. Kept as documented enrichment (not
  load-bearing; the tag is the join key).

**Surprises:** the live triggers fired on this morning's scheduled loads
while spiking (both sports SUCCEEDED at 05:20), confirming the WORKFLOW-4
machinery in unattended operation. And the zero-latency
SNOWFLAKE.INFORMATION_SCHEMA.DBT_PROJECT_EXECUTION_HISTORY table function
works as SYSADMIN, listing those builds seconds after completion.

**Changed from plan:** single harvest child task per sport instead of two
(S2's caller's-rights finding); the S1 tagging edits are the real Phase 1
files applied early, mirroring WORKFLOW-4's early grant slices.

**Open:** none.
