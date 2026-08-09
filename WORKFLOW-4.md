# WORKFLOW-4: event-driven dbt builds log

Build log for the dbt-trigger loop (per-sport stream -> triggered task ->
EXECUTE DBT PROJECT), same format as WORKFLOW-1/2/3. Plan of record: the
approved "Event-driven dbt builds after ingestion" plan.
Branch: `feat/dbt-trigger` off `main`.

Ground rules this loop (user-confirmed): full write scope including role and
grant DDL, every statement also captured in sql/ files; throwaway spike
objects allowed and dropped; never touch RAW/RAW_STAGING content or the 17
ingestion tasks; no push until told.

## Phase 0 - sandbox spikes

**Ran:** bootstrapped DBT_RUNNER_ROLE + DBT_WH + EXECUTE TASK grant (kept,
formalized in sql/base/04_dbt_runner.sql); branch-edited env.yml prod envs to
the new role/warehouse; built a throwaway DLT_DB.DBT_SPIKE sandbox (fake
loads table, streams, audit table, tasks) plus a CORTEX_LIFECYCLE_SPIKE
project object carrying the branch env.yml; ran spikes C, D, B, A, E; applied
the Phase-1 per-sport grant slices early (spikes A and E needed real
write paths); dropped the sandbox and the spike project object.

**Result: GATE GREEN, all five questions answered with evidence.**

- **C, the re-fire hazard is real and the drain kills it.** A triggered task
  whose body does not consume its stream fired 4 times in 90 seconds and
  would never stop. The drain version (INSERT ... SELECT FROM stream) fired
  exactly once, SYSTEM$STREAM_HAS_DATA flipped false, no further fires. The
  drain also swept a leftover unconsumed row from the earlier test: pending
  backlog coalesces into one drain.
- **D, raising the trigger interval coalesces, not queues.** With
  USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 300, three inserts spread
  over 46 seconds produced ONE run draining all 3 rows, then one SKIPPED
  evaluation at the next window (zero cost). Production value 900 confirmed.
- **B, the invoke privilege is USAGE on the project object** (the docs
  contradict themselves; USAGE worked first try). No usage on the
  DBT_EXT_ACCESS integration is needed at execute time. The wnba_prod
  environment applied correctly as the role (the nfl-disabled warnings in
  parse output prove DBT_SPORT rode along).
- **A, the full chain works as DBT_RUNNER_ROLE**: role-owned triggered task
  -> caller's-rights SQL proc -> EXECUTE DBT PROJECT, real WNBA prod build,
  SUCCEEDED in 124s. Two extra findings: (1) a task cannot run unless its
  owner role has USAGE on the task's schema and database (first attempt
  failed with exactly that message; the grant is now called out in the sql
  files); (2) EXECUTE TASK does NOT bypass a triggered task's WHEN clause,
  a manual fire against an empty stream is SKIPPED ("Conditional expression
  evaluated to false"), so manual smoke tests need a row inserted first.
- **E, a partial dbt failure raises a real SQL error**: EXECUTE DBT PROJECT
  with NFL's currently-red source test errored the statement itself, so a
  task shows FAILED with ERROR_MESSAGE in TASK_HISTORY and counts toward
  SUSPEND_TASK_AFTER_NUM_FAILURES. The proc needs no result inspection.

**Surprises:**
- NFL's drift moved again: the red check is now
  source_accepted_values_nfl_raw_games_status with 149 rows (the 2026 NFL
  season's scheduled games are landing with new status values), and in
  `dbt build` that single failed source test SKIPPED 129 downstream nodes.
  Strong confirmation that the NFL trigger must run `dbt run` until the
  drift item closes; the BACKLOG entry needs this update.
- The bulk ownership transfer has a semantic-view form
  (GRANT OWNERSHIP ON ALL SEMANTIC VIEWS IN SCHEMA ...): worked, 4 + 3
  objects across the two sports. No drop-and-rebuild needed.

**Changed from plan:** grant slices for BOTH sports applied during Phase 0
(the plan had WNBA-only early); spike E doubled as the first
DBT_RUNNER_ROLE-owned NFL prod write.

**Open:** none.

## Phase 1 - role and grants as reviewed SQL

**Ran:** wrote `sql/base/04_dbt_runner.sql` (role, DBT_WH, control-plane
usage, EXECUTE TASK grant) and section 1 of
`sql/sources/{nfl,wnba}/05_dbt_trigger.sql` (per-sport grants, change
tracking on _DLT_LOADS as its owner, ownership transfer of
PREP/CORE/ANALYTICS with COPY CURRENT GRANTS including the semantic-view
bulk form). Re-applied the base file from disk against the already-live
objects.

**Result:** GATE GREEN. Idempotent re-apply ("already exists, statement
succeeded" for role and warehouse, everything else clean); as
DBT_RUNNER_ROLE both sports' _DLT_LOADS are readable (90 NFL / 9 WNBA
rows) and CORE tables show owner DBT_RUNNER_ROLE.

**Notes:** the per-sport 05 files carry both sections but their
GRANT ON DBT PROJECT lines need the Phase-2 project objects, so file
application order on a fresh account is deploy-sport first; header says so.
The NFL file runs `dbt run` (not build) with the skip-cascade evidence in
its comment.

**Changed from plan:** none.

**Open:** none.
