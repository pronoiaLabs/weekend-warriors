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

## Phase 1 - tag plumbing shipped to all objects

**Ran:** `make -C dbt-pipelines deploy-all` (dev + both sport objects picked
up env.yml/profiles.yml/macro from Phase 0), then a 1-model prod run on
CORTEX_LIFECYCLE_NFL as DBT_RUNNER_ROLE with
`ENV_VARS = ('DBT_BUILD_ID' = 'phase1-prod-tag-check')`.

**Result:** GATE GREEN. The prod CREATE_VIEW query carries the full tag
(`app/sport/env/build_id/node`) and
`TRY_PARSE_JSON(QUERY_TAG):build_id` filters it cleanly, which is exactly
the predicate the harvest will use. Dev was verified in Phase 0/S1.

**Changed from plan:** the SP_DBT_BUILD edit (build_id + ENV_VARS +
DBT_BUILDS insert) moved to Phase 2 so the 05_dbt_trigger.sql files are
touched once, alongside the tables and child task the proc references.

**Open:** none.

## Phase 2 - harvest machinery + live E2E

**Ran:** sql/ops/06_dbt_harvest.sql (DBT_BUILDS / DBT_QUERY_LOG /
DBT_QUERY_OPERATOR_STATS + SP_DBT_HARVEST + retention task + grant slice);
both 05_dbt_trigger.sql files gained the build_id plumbing and a
DBT_HARVEST_<SPORT> child task; fired DLT_TASK_WNBA_GAMES and
DLT_TASK_NFL_REFERENCE as the live test. Applied twice where it mattered
(idempotency).

**Result: GATE GREEN, after a real shakedown.** The proven chain: load ->
build fires with a minted build_id -> every dbt query tagged with it ->
DBT_BUILDS row (drained loads, exec query id) -> harvest child logs the
queries and captures operator stats. A third build (the next scheduled WNBA
load) then ran the whole chain unattended: 1,263 tagged queries, 245
profiled, zero intervention.

**Five real-world corrections, each now encoded in the files:**
- EXECUTE DBT PROJECT's ENV_VARS clause validates at CREATE PROCEDURE time
  and rejects a Scripting :bind -> EXECUTE IMMEDIATE with the (self-minted)
  build_id inlined.
- GET_QUERY_OPERATOR_STATS is far slower live than spiked: 0.5 s to 50 s+
  per call (spike sample averaged 660 ms), and the first-run backlog plus
  two concurrent harvests drove both children into their 30-min timeout.
  Fix: 200-per-run cap, heaviest first.
- Serial profiling was the wrong shape entirely -> Snowflake Scripting
  ASYNC child jobs, 8 per chunk (matching default MAX_CONCURRENCY_LEVEL),
  AWAIT ALL per chunk inside an exception handler (AWAIT is fail-fast and
  unawaited children are auto-cancelled at proc exit). Snowpark was
  evaluated and rejected: collect_nowait/AsyncJob is documented as
  unsupported inside Python stored procedures. Measured result: 174
  profiles in 182 s, zero errors, versus timeout before.
- EXECUTION_TIME > 0 is not a metadata filter: USE and ALTER SESSION report
  8-14 ms of "execution time", so the first day admitted 9k+ no-ops to the
  profile queue. Fix: QUERY_TYPE allowlist (SELECT/INSERT/MERGE/UPDATE/
  DELETE/CTAS/COPY/UNLOAD).
- Claim-first dedupe (flip STATS_CAPTURED, then profile) so concurrent
  sport harvests never pay the same profile call twice.

**Also:** two stuck old-code harvest calls were cancelled mid-shakedown
(committed rows kept; incremental state self-heals). The QUERY_HISTORY
stored-proc prohibition being owner's-rights-only held in task context too.

**Changed from plan:** one harvest child per sport instead of two (Phase 0
finding); profile-eligibility narrowed to plan-bearing statement types,
which is what the user's "skip the metadata no-ops" choice meant all along.

**Open:** none.

## Phase 3 - V_DBT_RUNS, retention, cost tags

**Ran:** sql/ops/07_dbt_runs.sql (V_DBT_RUNS: live per-DB TASK_HISTORY
UNION ACCOUNT_USAGE, QUALIFY dedupe, joined to DBT_BUILDS and per-build
query rollups) and 08_cost_tags.sql (COST_CENTER tag on DBT_WH /
DEVELOPMENT_WH / DLT_OPS_WH and the five dbt tasks). Retention rode in
Phase 2's 06 file (weekly, 90 d query log + operator stats, 365 d build +
trigger audit rows).

**Result:** GATE GREEN. The view returns the full task history including
WORKFLOW-4's documented rollout failures, correctly attributed; tag
bindings verified via TAG_REFERENCES; DBT_RUNNER_ROLE reads
ACCOUNT_USAGE.TASK_HISTORY with no new grant (verified empirically).
ALTER TASK SET TAG works on a started task, no suspend needed.

**One correction, which took two rounds:** TASK_HISTORY.RETURN_VALUE comes
only from SYSTEM$SET_RETURN_VALUE, not from a proc's RETURN string
(verified None), so SP_DBT_BUILD now sets it explicitly; V_DBT_RUNS parses
build_id from it. The first version failed silently in production because
the guard swallowed the real error: **the function demands a CONSTANT
argument**, and stamping a concatenation with :binds is a compilation
error ("argument 1 ... needs to be constant"). Found by escalating probe
tasks (literal stamp works; + graph child works; + EXECUTE DBT PROJECT
works; + binds fails), fixed by assembling the message into a literal via
EXECUTE IMMEDIATE. Builds that ran before the fix stay unjoined and render
unlinked on the dashboard, which is fine since this data is disposable
until the happy-state truncation.

**Changed from plan:** retention lives in 06 (same owner as the tables)
rather than a separate file.

**Open:** V_DBT_RUNS build_id join confirmation on the next natural build.

## Phase 4 - dashboard API

**Ran:** (delegated to a python subagent against a fixed endpoint contract)
four routes in ops-dashboard/api following the datasource/main seam:
GET /api/dbt/builds, /api/dbt/builds/{id}, /api/dbt/builds/{id}/queries,
/api/dbt/queries/{qid}/operators. Fixtures recorded from the live tables
(read-only), 8 new tests including 404 paths, deploy/sql/01_ops_role.sql
grants kept in sync.

**Result:** GATE GREEN. 41 API tests pass, ruff clean, live smoke test of
all four endpoints against Snowflake.

**One shared-helper fix rode along:** _iso_utc now converts tz-aware values
to UTC before stamping Z. The dbt tables are TIMESTAMP_TZ (unlike the LTZ
views), arrive in writer-local offsets regardless of session TIMEZONE, and
were being stamped as UTC while holding -07:00 wall time. Guarded on
tzinfo, so LTZ/NTZ payloads are byte-identical to before.

**Changed from plan:** none.

**Open:** endpoints 2-4 return 404 live until a post-RETURN_VALUE build
exists (fixtures cover the joined shape; recorded values, real join).

## Phase 5 - dashboard web

**Ran:** (delegated to a react subagent against the same contract) /dbt
page (interleaved newest-first build table, state chips, failed-query
highlighting), /dbt/builds/:buildId detail (facts grid, triggering loads,
slowest-first query table with per-query operator expanders), Fleet dbt
card (latest build per sport), TopBar nav, types + client + CSS.

**Result:** GATE GREEN. tsc, oxlint and vite build clean; make test lint
green over the combined API + web tree.

**Notes:** operator breakdown deliberately compact (share-of-time column,
top statistics, no nested bags); node names shown without the
model.cortex_agent_lifecycle. prefix; sub-second timings render in ms via
a new shared elapsedMs formatter.

**Changed from plan:** single interleaved table instead of per-sport
grouping (the feed is newest-first across sports; grouping would destroy
the ordering that matters).

**Open:** none.

## Phase 6 - docs and wrap-up

**Ran:** CLAUDE.md (event-driven section now covers the harvest child,
build_id plumbing and SET_RETURN_VALUE; new "dbt observability" section
under Telemetry with the four hard-won GET_QUERY_OPERATOR_STATS facts);
BACKLOG.md/.html (dbt-trigger-observability item closed, SPCS pool-tagging
item added); dbt-pipelines README (query-tag contract paragraph). Scaffold
template + tests landed back in Phase 2's commit. Full dlt suite 189
passed; BACKLOG.html re-validated.

**Changed from plan:** none.

**Open:** in HANDOFF.

## HANDOFF

**End state: dbt builds are first-class observability citizens.** Every
prod build mints a build_id that rides in every query's JSON QUERY_TAG;
a harvest child task persists the build's query log and (ASYNC, 8-wide,
200-per-run) operator-stats profiles into DLT_DB.OPS; V_DBT_RUNS joins
task history, build records and per-build rollups; COST_CENTER object tags
sit on the warehouses and dbt tasks; and the ops dashboard has a /dbt page,
build detail with query-profile drill-down, and a Fleet card.

**Verified live:** the full chain end to end including one fully unattended
build+harvest cycle, plus the shakedown corrections recorded in Phase 2
(ENV_VARS binds, operator-stats latency, ASYNC rework, metadata-noise
filter, claim-first dedupe, SET_RETURN_VALUE).

**Still pending when this log closed:** the first V_DBT_RUNS row with a
parsed build_id (needs one natural build after the SET_RETURN_VALUE patch;
a watcher was running). Until then the dashboard's build-detail endpoints
404 live and the /dbt list shows unlinked rows, both by design.

**The user intends to truncate the observability tables once at a happy
state** (first-day data is shakedown noise: three builds, one with
pre-patch NULL joins, backlog-heavy query log). Truncation is theirs to
run: DBT_BUILDS, DBT_QUERY_LOG, DBT_QUERY_OPERATOR_STATS, and optionally
both DBT_TRIGGER_LOADS.

**Costs:** harvest adds roughly 2-4 min of XSMALL DBT_WH per build day
under the 200-cap (backlog drains then stabilizes); operator rows ~5-15k
per WNBA build under full capture, 90-day retention.

**Follow-ups, priority order:**
1. WNBA play-by-play modeling (BACKLOG, unchanged, still top).
2. deploy.yml dbt job wiring (BACKLOG, unchanged).
3. NFL raw drift (BACKLOG, unchanged; gates run->build flip).
4. SPCS pool cost tagging decision (new BACKLOG item).
5. Optional harvest tuning if runtime ever matters: batch the claim
   UPDATEs (the remaining serial cost, ~0.4 s per row).

**Branch state:** feat/dbt-observability, NOT pushed, no PR (your call).
