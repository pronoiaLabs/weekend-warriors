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
