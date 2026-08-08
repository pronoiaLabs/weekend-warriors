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

## Trigger relevant dbt jobs after ingestion jobs complete

**Problem:** nothing chains dbt behind the ingestion Tasks (a known gap since the
CI/CD build): `dbt build` runs on a code push, not when new rows land in `RAW`,
so models lag ingestion by up to a day.

**The fix:** a Task graph with `EXECUTE DBT PROJECT` as a child of the last dlt
Task per sport, so models rebuild the moment their sport's ingestion finishes.
Per-sport graphs keep an NFL failure from blocking WNBA models. Needs a decision
on granularity (one dbt run per sport per day vs per pipeline) and on where the
graph is generated (`generate_tasks.py` already renders the dlt Tasks and is the
natural place to add AFTER dependencies).

## WNBA dbt models and Cortex agent

**Problem:** `dbt-pipelines` only models NFL (`models/nfl/`, NFL semantic views,
NFL agent). WNBA raw data has been landing in `WNBA_PROD_DB.RAW` since Aug 8
with nothing built on top of it.

**The fix:** mirror the NFL layer structure (`prep/` -> `core/` -> `semantic_views/`)
for WNBA, plus a `deploy_<name>` agent macro. The NFL layer is the template;
the WORKING-SESSION.md runbook in dbt-pipelines was built for exactly this kind
of guided build. Watch for the cross-discipline trap that disabled
`sv_nfl_player_advanced`: check WNBA endpoint overlap before promising
cross-stat comparisons in a semantic view.

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
