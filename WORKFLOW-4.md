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

## Phase 2 - env.yml switch, Makefile, per-sport project objects

**Ran:** finalized the env.yml edit (prod and wnba_prod: DBT_ROLE
DBT_RUNNER_ROLE, DBT_WAREHOUSE DBT_WH; dev envs untouched). Created
dbt-pipelines/Makefile (deploy-dev / deploy-sport / deploy-all /
build-dev / build-sport, dlt-pipelines conventions) and deployed all
three project objects through it: CORTEX_LIFECYCLE (dev),
CORTEX_LIFECYCLE_NFL, CORTEX_LIFECYCLE_WNBA. Granted USAGE on the sport
objects to the role.

**Result:** GATE GREEN. As DBT_RUNNER_ROLE on the sport objects:
WNBA `build` PASS=629 in 127s, NFL `run` PASS=33 in 13s, both on DBT_WH.

**Notes:** the Makefile encodes the release model: the triggers always run
whatever the sport object holds, so `make deploy-sport` after merging model
changes IS the prod release step. NFL's grandfathered env name (`prod`,
not `nfl_prod`) is a documented case switch in one place.

**Changed from plan:** none.

**Open:** none.

## Phase 3 - trigger machinery + live end-to-end

**Ran:** applied section 2 of both 05_dbt_trigger.sql files (stream, audit
table, caller's-rights proc, triggered task per sport), then fired
DLT_TASK_WNBA_GAMES, DLT_TASK_NFL_REFERENCE, and DLT_TASK_WNBA_PLAYS as the
live test.

**Result:** GATE GREEN after two real-world corrections:
- CREATE PROCEDURE clause order: COMMENT must precede EXECUTE AS (the spike
  proc had no comment, so this surfaced only in the real files).
- The audit tables declared INSERTED_AT TIMESTAMP_NTZ but the real
  _DLT_LOADS column is TIMESTAMP_TZ; the drain INSERT failed the type check.
  The failure mode itself validated the design: task FAILED loudly with the
  message in TASK_HISTORY, the failed transaction rolled back, the streams
  kept their rows, and after the column fix the tasks SELF-HEALED at the
  next 15-minute window with no manual re-fire.
- Final state: DBT_BUILD_WNBA SUCCEEDED in 144s draining TWO loads into one
  build (live coalescing); DBT_BUILD_NFL SUCCEEDED in 34s; audit tables
  record which loads triggered which build; both streams empty; no re-fires.

**The headline surprise: wnba_plays WORKS NOW.** The "broken upstream"
pipeline, fired as the negative control, succeeded and landed
WNBA_PROD_DB.RAW.PLAYS with 98,658 rows: the provider evidently fixed the
meta-less pagination. The negative-control property (failed loads never
insert into _DLT_LOADS, so never trigger) stands on the Phase 0 spike
evidence instead, since no reliably-failing pipeline exists anymore.
BACKLOG rewritten: the gap is now "model WNBA play-by-play", not "fix the
pipeline".

**Changed from plan:** the negative control became a data win; two type/
syntax fixes folded into the files.

**Open:** none.

## Phase 4 - scale template

**Ran:** new_source.py gained a fifth scaffold template rendering
sql/sources/<name>/05_dbt_trigger.sql from the proven WNBA file (new sports
follow the <name>_prod env convention; NFL's plain `prod` is the documented
grandfather), plus dbt next-steps in the generator's guidance text.
test_new_source.py: five-file assertion and a name-agreement test for the
trigger file (task/stream/project-object/env all carry the sport, never the
DLT_TASK_ prefix).

**Result:** GATE GREEN. Scaffold render verified with a throwaway `ncaaf`
instantiation (correct names throughout); full dlt-pipelines suite 189
passed.

**Changed from plan:** none.

**Open:** none.

## Phase 5 - docs and wrap-up

**Ran:** CLAUDE.md (known gap closed, new "Event-driven dbt builds" section
with the release model, kill switch, and observability pointers); BACKLOG.md
(chaining item out; wnba_plays item rewritten as a modeling item; deploy.yml
enablement and dbt-trigger observability items in; NFL drift item updated
with the moving Aug 9 failure set); deploy.yml dbt job comment block updated
(prerequisite now partly satisfied, remaining wiring listed); dbt-pipelines
README "Production builds are event-driven" section. Plus, user-requested:
BACKLOG.html at repo root, a local check-off tracker (localStorage state,
BACKLOG.md stays the content source of truth).

**Changed from plan:** BACKLOG.html added by user request mid-loop.

**Open:** in HANDOFF.

## HANDOFF

**End state: prod dbt is event-driven for both sports.** Load lands in
RAW -> stream -> DBT_BUILD_<SPORT> (15-min coalescing window) -> per-sport
project object builds as DBT_RUNNER_ROLE on DBT_WH. Verified live end to
end, including a failure that healed itself.

**The release model changed:** merging dbt model changes no longer reaches
prod by itself. `make -C dbt-pipelines deploy-sport SPORT=<sport>` (or
deploy-all) ships code to the sport objects; the next load builds it.

**Kill switch per sport:**
`ALTER TASK <SPORT>_PROD_DB.OPS.DBT_BUILD_<SPORT> SUSPEND;`

**Watch it:** SNOWFLAKE.ACCOUNT_USAGE.DBT_PROJECT_EXECUTION_HISTORY,
per-database TASK_HISTORY, and <SPORT>_PROD_DB.OPS.DBT_TRIGGER_LOADS (which
loads triggered which build). Deliberately absent from V_TASK_RUNS.

**Costs:** XSMALL DBT_WH, ~8 builds/day typical (~14 Tue), WNBA ~2.5 min,
NFL ~35s per build, 60s auto-suspend tail. Roughly 0.5-1 credit/day.

**Follow-ups, priority order:**
1. WNBA play-by-play is LANDING now (98,658 rows day one): model it
   (BACKLOG item) and update the agent's not-available list.
2. NFL drift: the trigger runs `dbt run`; flipping to `build` waits on the
   BACKLOG investigation (Aug 9 failure: 149 new game-status rows skip 129
   nodes under build).
3. deploy.yml dbt job: prerequisites now mostly exist (BACKLOG item lists
   the three remaining wires).
4. dbt trigger observability (V_DBT_RUNS + dashboard card + audit
   retention): BACKLOG item.

**Branch state:** feat/dbt-trigger, NOT pushed, no PR (your call).
