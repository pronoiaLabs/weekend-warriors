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

## Fix or replace the wnba_plays pipeline

**Problem:** the `/plays` WNBA endpoint returns a bare `{data: [...]}` with no
`meta`, so the cursor paginator cannot walk it; the pipeline has never produced
a PLAYS table anywhere (dev or prod). WNBA play-by-play is simply absent, and
the wnba_analyst agent declines those questions.

**The fix:** a per-game fetch loop like NFL `plays` uses (fan out over
`games_ref`), or a response adapter that tolerates the meta-less shape. The
registry comments on `wnba_plays` document the pagination problem. Until then
the scheduled Task is idle spend on every fire; consider suspending it.

## Investigate NFL raw drift flagged by the reconciliation tests

**Problem:** as of Aug 8 the NFL dev rebuild fails three data checks that all
passed when the models were authored: 2 `team_stats` rows reference games
absent from `GAMES` (source relationship test), `assert_player_game_phase_coverage`
is 1 row over its documented threshold, and `assert_phase_fact_measures_reconcile`
returns 12 rows. Code is unchanged; a week of daily loads moved the data. This
is the `stats?seasons[]` incompleteness gap doing what the tests were built to
surface.

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
