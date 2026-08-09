# Backlog

Deliberately deferred work, with enough context to pick each item up cold.

## Materialize the observability views' expensive middle layer

**Problem:** every uncached dashboard query against `V_PIPELINE_RUNS` costs 4.6 to
6.0 seconds, and compilation (2.5 to 3.6s) exceeds execution (~2.1s). The view
stack is five layers deep (`V_PIPELINE_RUNS` -> `V_TASK_RUNS` -> `TASK_HISTORY()`
table function + `ACCOUNT_USAGE.TASK_HISTORY` + `V_LOG_LINES` / `V_METRICS` regex
parsing over the event table + `_DLT_RUNS` flatten), and Snowflake re-expands and
re-executes all of it per query. The result cache cannot help: the queries use
`CURRENT_TIMESTAMP()` and metadata table functions, both disqualifying.

**Current mitigation:** the dashboard API caches query results for
`OPS_DASHBOARD_CACHE_SECONDS` (default 60; 600 recommended for reading sessions),
so the cold path is paid once per TTL window and every other click is ~3ms.

**The fix:** feed parsed logs and metric aggregates into real tables via a task on
an APPEND_ONLY stream over `DLT_DB.OPS.DLT_EVENTS`, and point `V_TASK_RUNS` at
those tables instead of the regex views. Collapses both the compile tree and the
execution work; cold queries should drop well under a second. Foreshadowed in the
closing note of `dlt-pipelines/sql/ops/05_retention.sql` (retention currently
applies uniformly because the views read the event table directly; materialized
tables would also decouple parsed-log retention from raw retention).

**Why deferred:** with the app cache the cold hit bites at most once per TTL
window. Live with the dashboard first; only build the stream + task + two table
swaps if the cold path still hurts in practice.

## Model WNBA play-by-play

**Problem:** `WNBA_PROD_DB.RAW.PLAYS` started landing on 2026-08-09 (98,658
rows on first successful run; the provider evidently fixed the meta-less
pagination that had made `wnba_plays` a dead pipeline since setup). Nothing
models it: no stg/fact, no semantic view exposure, and the wnba_analyst agent
still declines play-by-play questions with "upstream pipeline broken", which
is now wrong.

**The fix:** mirror NFL's play modeling shape (`stg_nfl__plays` -> `fact_play`
/ `dim_play_type`) as `stg_wnba__plays` -> `fact_wnba_play`, decide whether a
semantic view exposes it, and update the agent's not-available list plus the
registry's stale pagination comments. Add source tests first: the table is
brand new and its grain and NULL behavior are unprofiled.

## Enable deploy.yml's dbt job

**Problem:** the dbt CI job stays disabled. Its original blocker (env.yml
demanded SYSADMIN) is gone: `DBT_RUNNER_ROLE` now exists and prod envs use it.
What remains is wiring: `GRANT ROLE DBT_RUNNER_ROLE TO USER DLT_DEPLOYER;`,
replace the stale `DBT_PROJECT_FQN` / `DBT_PROJECT_NAME` vars (the object is
now `DLT_DB.DEPLOY.CORTEX_LIFECYCLE` plus per-sport `_NFL` / `_WNBA` siblings),
and make the job deploy all three objects (a matrix or `make deploy-all`).
Note the job then only needs to DEPLOY: the triggers run the builds when data
lands, so the CI build step becomes optional-or-removed.

## Isolate the dbt harvest onto its own warehouse

**Problem:** the harvest's 8-wide async profiling saturates `DBT_WH`'s default
concurrency (MAX_CONCURRENCY_LEVEL 8), so a build arriving mid-harvest queues
for a few minutes behind it (observed live). Harmless in unattended operation,
but it delays build completion and makes verification feel slow.

**The fix:** a dedicated `DBT_HARVEST_WH` (XSMALL, AUTO_SUSPEND 60) for the
`DBT_HARVEST_<SPORT>` tasks: create it in `sql/base/04_dbt_runner.sql` and
point the two harvest task definitions at it. The harvest can run on any
warehouse while reading DBT_WH's query history; that privilege is about which
warehouse ran the queries, not where the harvest executes. Deliberately NOT
multi-cluster: that is an Enterprise feature priced for concurrent users, and
it would auto-spin a second cluster (double burn) exactly when every harvest
runs.

**Why deferred:** the queue delay costs nothing in production; spend the
extra warehouse only if it bothers in practice.

## Tag SPCS compute pools for ingestion cost attribution

**Problem:** `sql/ops/08_cost_tags.sql` tags the warehouses and dbt tasks
with `DLT_DB.OPS.COST_CENTER`, but ingestion cost lives in the SPCS compute
pools, which the file deliberately leaves untagged (and the 17 ingestion
tasks are untouchable by standing rule). Component-level cost reporting
therefore covers dbt/dev/ops but not ingestion.

**The fix:** decide whether to `ALTER COMPUTE POOL ... SET TAG` the pools
(object tagging supports compute pools) and whether the ingestion tasks
should carry the tag too, which would mean amending the generate_tasks.py
template rather than hand-editing tasks. Low urgency: pool cost is visible
untagged in `SNOWFLAKE.ACCOUNT_USAGE.SNOWPARK_CONTAINER_SERVICES_HISTORY`.

## Investigate NFL raw drift flagged by the reconciliation tests

**Problem:** NFL data checks that passed at authoring time now fail, and the
failure set is moving as the 2026 NFL season starts loading. Aug 8: 2 orphan
`team_stats` rows plus two phase reconciliation failures. Aug 9: the dominant
failure is `source_accepted_values_nfl_raw_games_status` with 149 rows (the
2026 season's scheduled games carry status values beyond Final/Final OT), and
in `dbt build` that single source failure SKIPS 129 downstream nodes, so a
triggered build would refresh nothing. Code is unchanged; the data moved.
Partly the `stats?seasons[]` incompleteness gap, partly models authored
against completed-seasons-only data meeting an in-progress season.

**The fix:** replay the affected games by `game_id` (the known workaround), or
adjust thresholds if investigation shows benign timing effects. Until then NFL
`dbt build` is red on these three and `dbt run` (models only) is the clean path,
which is how the Aug 8 NFL prod refresh was run.

## Slack alerting on pipeline failures

**Problem:** no alerting on Task failure (known gap). Failures are visible in the
dashboard's incidents feed and `V_PIPELINE_RUNS`, but only if someone looks.

**The fix:** a scheduled check over the same incident classes the dashboard
derives (failure, record-missing, disagreement, missed slot) that posts to Slack.
Two viable shapes: (a) a Snowflake-native path via a webhook NOTIFICATION
INTEGRATION pointed at a Slack incoming webhook, called from a Task, no
container involved; (b) the Slack SDK inside a small SPCS job, which needs an
EXTERNAL ACCESS INTEGRATION for slack.com egress (same pattern as the sports
API EAIs). Decide dedupe/repeat policy up front so a flapping pipeline does not
spam the channel; the missed-slot class needs the same young-pipeline guard as
the dashboard (see missed-slot inflation note in WORKFLOW-2.md).
