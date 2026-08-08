# WORKFLOW-1: prod telemetry rollout

Build log for the rollout of a dedicated event table, SPCS platform metrics and structured
logging into the seventeen production Tasks. Written as we go, one section per phase, before
the next phase starts.

The point of this file is the **Surprises** line. Over the preceding week, four stacked bugs
took the whole fleet down and every one of them was a wrong value that looked like a right one:
a stale image, three registry columns that were never synced, a `SELECT` list that omitted
them, and a season rollover silently falling back to the NFL's answer. Several contradicted
what `CLAUDE.md` said. None were written down until after they had cost real time.

Anything recorded here that contradicts committed documentation is a correction owed to
`CLAUDE.md` or to `.docs/pipeline-observability.html`.

Environment: Snowflake connection `weekend-warriors`, `snow` CLI 3.23.0, branch
`feat/prod-telemetry-rollout` off `main` at `bb5e66a`.

---

## Prereq: `--suspend` and the task Makefile targets

Blocker for everything else. `CREATE OR ALTER TASK` cannot be applied to a fleet that is
running, and there was no way to stop one.

**Ran**

```bash
make test          # 185 passed
make lint          # All checks passed
make tasks-suspend-sql
cat build/suspend.sql
```

**Result**

185 tests pass, up from 182. Lint clean. `build/suspend.sql` contains **17**
`ALTER TASK IF EXISTS ... SUSPEND` statements plus `-- skipped 'sample': no schedule in
registry`, which matches `SHOW TASKS IN SCHEMA DLT_DB.OPS` exactly: 7 NFL, 10 WNBA.

Nothing was applied to the account. `tasks-suspend-sql` writes the file; `tasks-suspend`
applies it.

**Surprises**

1. **CI had the same bug, unnoticed.** `.github/workflows/deploy.yml` applied `tasks.sql` with
   no suspend step. The next deploy touching a registry file would have aborted mid-fleet the
   same way `make deploy` did by hand, leaving some Tasks on the new spec and some on the old.
   The `tasks` path filter includes `generate_tasks.py` and the registry files, so this was
   live, not theoretical.

2. **Three docstrings and one CI comment asserted the opposite of the truth.** All of them
   said `CREATE OR ALTER TASK` "resets a Task to SUSPENDED" and that "the DDL succeeds,
   nothing errors". Measured behaviour on 2026-08-08 against the live fleet:

   ```
   091421 (22000): Unable to update graph with root task
   DLT_DB.OPS.DLT_TASK_NFL_REFERENCE since that root task is not suspended.
   ```

   It errors and changes nothing. That is the better of the two failures, but the remedy is
   different and nothing documented it.

3. **`snow sql -f` stops at the first error**, which is what turns the above from an annoyance
   into a half-applied fleet. The abort happens before most statements are attempted and the
   output does not say which Tasks were reached.

**Changed from plan**

- Added a `Suspend scheduled Tasks` step to `.github/workflows/deploy.yml`. The plan named only
  the Makefile; CI is the more likely place to hit this, since it runs unattended.
- Split into `tasks-suspend-sql` / `tasks-suspend` and `tasks-resume-sql` / `tasks-resume`,
  mirroring the existing `tasks-sql` / `tasks-apply` pair, so the SQL can be read before it is
  applied.
- `--suspend` and `--resume` are an argparse mutually exclusive group rather than two
  independent flags where the first `if` would silently win.
- Wrote three tests rather than the one implied: coverage agreement across all three emitters,
  `IF EXISTS` present on suspend and deliberately absent on resume, and rejection of both flags
  together.

**Open**

- The old `resume_sql` docstring claims "all seven Tasks were found suspended after a re-apply,
  hours after they were resumed". That is a real observation and it does not fit today's
  measured behaviour. Possibly an older Snowflake version, possibly `CREATE OR REPLACE` rather
  than `CREATE OR ALTER`. Not chased; today's behaviour is unambiguous and both the old and new
  failure modes are now handled.
- `CLAUDE.md` still carries the wrong claim. Correction pending as its own change.

---

## Phase A / C1 / C2: dedicated event table and binding

Wrote `sql/ops/01_event_table.sql` and a `setup-ops` target, applied it, and verified that SPCS
telemetry actually lands in the new table. Took three attempts. Both failures were the same
shape as the rest of this project: the configuration read back as correct and did nothing.

**Ran**

```bash
make setup-ops CONFIRM=1
make run-spcs NAME=sample
# attempt 1 failed, fixed the binding scope, re-applied
# attempt 2 failed, cycled the pool:
snow sql -q "ALTER COMPUTE POOL DLT_DEV_POOL SUSPEND;"
make run-spcs NAME=sample
```

**Result**

Creates `DLT_OPS_WH` and `DLT_DB.OPS.DLT_EVENTS` (change tracking on, 1 day Time Travel), grants
to `DLT_LOADER_ROLE` and `DLT_DEV_ROLE`, and binds the event table at account and database level.

Final state, both halves of the check passing:

```
EVENT_TABLE IN ACCOUNT   value=DLT_DB.OPS.DLT_EVENTS  level=ACCOUNT
DLT_DB.OPS.DLT_EVENTS    LOG 145, METRIC 36           (query 01c6417c, the post-restart run)
SNOWFLAKE.TELEMETRY.EVENTS   frozen for that run
```

`DLT_POOL` was already SUSPENDED with zero nodes, so production needed no intervention.

**Surprises**

1. **SPCS ignores a database-level `EVENT_TABLE` binding. Only the account-level one works.**
   The general "Event table overview" documentation says a database binding overrides the
   account one for objects in that database. The SPCS monitoring page says container stdout goes
   to "the event table configured for your account" and points at `SHOW PARAMETERS ... IN
   ACCOUNT`. The two pages disagree and the SPCS one is right.

   With `EVENT_TABLE` set on `DLT_DB` and not on the account, a fresh job service in
   `DLT_DB.DEPLOY` wrote all 192 of its rows to the shared table and zero to ours, while
   `SHOW PARAMETERS ... IN DATABASE DLT_DB` reported `level=DATABASE` throughout. The binding
   looked applied and was never consulted.

2. **A compute pool node caches the event table at node start.** After fixing the scope, the
   next run *still* wrote to the shared table. `run-spcs` drops and recreates the SERVICE every
   run, which is not the same as a new NODE. `ALTER COMPUTE POOL DLT_DEV_POOL SUSPEND` followed
   by one more run, on a freshly provisioned node, routed correctly.

   Rollout consequence: any pool with live nodes needs cycling after the binding changes. A pool
   already suspended does not, since its next job provisions a new node.

3. **One run straddled the cutover and split across both tables.** Query `01c64179` put its 36
   remaining log lines in the shared table and 8 metrics, flushed later, in the new one. Expect
   exactly one such run; it is not a partial failure.

4. **Metrics were already flowing before this phase.** The account event table held 293 METRIC
   rows from the earlier dev probe, so the dev templates have been emitting since then.

**Changed from plan**

- The plan said bind `DLT_DB`. That is wrong for SPCS and the file now binds the account, keeping
  the database binding only as a same-target no-op for future non-SPCS objects.
- The plan's stated reason for avoiding the account binding, that it would redirect telemetry
  this project does not own, was checked and is false here: 14 days of the account event table
  is 14,975 rows, every one `snow.service.type='Job'` in `DLT_DB`. Nothing else emits. That is a
  property of this account, not a general rule, and the file says so.
- `setup-ops` now prints the pool-cycling step, because applying the file is genuinely not
  sufficient on its own.

**Open**

- Whether the node caches the binding for the node's whole lifetime or refreshes on some
  interval. Not chased: cycling the pool is cheap and deterministic.
- `make run-spcs NAME=sample` still binds `NFL_API_KEY` although `sample` declares no secret,
  so the no-secret template remains unreachable and untested. Unrelated to this phase.

---

## Phase B / C3: platform metrics in the prod spec, structured logs in the image

Added `platformMonitor` with all five groups to `deploy/spcs/dlt_job.tmpl.yaml`,
`snowflake-telemetry-python` to `pyproject.toml`, and a test asserting all three templates
declare the block. Pushed the image and ran a real pipeline on it as a canary.

**Ran**

```bash
make test && make lint
make image-push
make run-spcs NAME=nfl_reference
```

**Result**

Image pushed 16:36:36 UTC. Canary ran 16:37:18 to 16:38:58 on the new image and **succeeded**:
`nfl_reference` status `ok`, 13,521 players and 32 teams, 416 LOG and 48 METRIC rows into
`DLT_DB.OPS.DLT_EVENTS`. No dependency conflict between `snowflake-telemetry-python` and
`dlt[snowflake]`, which was the one risk that could have taken the fleet down at the next cron.

Structured logging works and lands where predicted:

```
severity=INFO  scope=dlt_pipeline    4 lines
severity=NULL  scope=NULL          412 lines
```

Four of 416, about 1%. The estimate going in was "under 3%", from a fleet-wide measurement of
385 of 13,514. The regex parser stays the primary path.

**Surprises**

1. **`RECORD_ATTRIBUTES` carries the pipeline name as a structured field.** This is better than
   the `[pipeline=X]` regex the design was going to rely on, and it arrives with source
   location attached:

   ```json
   {"code.filepath":"/app/pipelines/batch/run.py","code.function":"run_pipeline",
    "code.lineno":512,"log.iostream":"stderr","pipeline":"nfl_reference"}
   ```

   Caveat: it is `"-"` rather than absent when the LoggerAdapter was not used, the same
   placeholder `_PipelineDefaultFilter` puts in the text form. Needs `NULLIF(..., '-')`.

2. **There is a THIRD wire format, not two.** A structured line's `VALUE` is the bare message
   with no timestamp, level or logger prefix, because the formatter moved those into `RECORD`
   and `SCOPE`. So the parser sees: stdlib prefixed, dlt pipe-delimited, and now bare. The
   planned design survives this by accident rather than by intent, since the message regexes
   fail to match and fall through to raw `VALUE`, which for these lines already is the clean
   message. Worth an explicit comment in `sql/ops/02` rather than leaving it to luck.

3. **`log.iostream` is `stderr`** for dlt's output, which may matter if `logExporters.logLevel`
   is ever narrowed from `INFO` to `ERROR`.

**Changed from plan**

- Added `test_every_template_enables_platform_metrics`, which asserts on parsed YAML rather than
  file text so it can catch `platformMonitor` nested one level too deep inside the container.
  Indented wrongly the key is ignored without error, the spec still parses and the job still
  runs, and no metric is ever emitted. Same failure class as everything else this week.
- The plan said the Dockerfile needs no edit because it installs from `pyproject.toml`. That
  held.

**Open**

- The double-logging bug is now visible in a new way: the four structured lines each have an
  unstructured duplicate, because `logging.basicConfig` in `run.py` and `configure_logging`
  both emit. Deduplication for the modelling layer is a real question, not cosmetic.

---

## C4 / C5: seventeen Tasks reapplied, metrics proven in production

**Ran**

```bash
make tasks-suspend        # ✓ suspended 17 task(s)
make tasks-apply          # ✓ applied 17 task(s)
make tasks-resume         # ✓ resumed 17 task(s)
snow sql --role DLT_LOADER_ROLE -q "EXECUTE TASK DLT_DB.OPS.dlt_task_nfl_reference;"
```

**Result**

All 17 Tasks `started`, and all 17 Task definitions contain `platformMonitor` and
`system_limits`. Checking the definitions matters as much as the state: a green tick from
`tasks-apply` says the statements ran, not that the spec inside them changed.

The suspend target worked first time, which is the whole reason `tasks-apply` did not abort the
way it did by hand earlier in the day.

Prod run `01c6418f`, SUCCEEDED in 92 seconds, all three C5 checks pass:

```
DLT_EVENTS   JOB_01C6418F01075E62000FCF02000B054E  schema=OPS   LOG 416, METRIC 25
attribution  snow.query.id == TASK_HISTORY.QUERY_ID           MATCH
```

Metric contract, measured in production and identical to the dev probe:

```
system         container.cpu.usage (1 sample), container.memory.usage (2)
system_limits  container.cpu.limit, container.cpu.requested,
               container.memory.limit, container.memory.requested   (2 each)
status         container.restarts, container.state.started/running/pending/finished
network        network.egress.received.bytes/.packets,
               network.egress.transmitted.bytes/.packets, .denied.packets  (1 each)
storage        NOTHING, again
```

16 metrics, 25 rows, on a 92 second run.

**Surprises**

1. **Nothing.** First phase of the day where the check passed on the first attempt. Worth
   recording precisely because the preceding three did not, and the difference is that this
   phase was built on facts established by those failures rather than on documentation.

2. Minor confirmation rather than surprise: metric names in production are **identical** to the
   dev probe, so the dev pool is a faithful rehearsal for name discovery. Density is not:
   `container.cpu.usage` landed once on a 92 second run, and `container.memory.usage` twice.
   The ~30 second scrape interval holds, and the thin-sample conclusion holds with it.

3. `storage` produced zero rows for the third time, now including a production run. It stays
   enabled per the collect-everything decision, but any downstream query should assume it is
   empty rather than joining to it hopefully.

**Changed from plan**

- Nothing.

**Open**

- Whether metrics arrive for a Task fired by cron rather than by hand. Nothing suggests a
  difference, but `EXECUTE TASK` is not identical to a scheduled fire and the natural
  confirmation is free: `nfl_injuries` at 22:00 UTC.
- Cost has not yet been measured over a full day. Estimate was ~400 metric rows/day, about a
  20% increase on event volume. Check `METERING_HISTORY` once a day of real cron fires exists.

---

## Modelling layer: five views and a retention task

Built `sql/ops/02` through `05` plus a per-sport view for each league. **The dynamic table in the
design became a plain view**, and four separate bugs were found by checking output against
something already known to be true. None of them raised an error.

**Ran**

```bash
make setup-ops CONFIRM=1                  # x2, one fix in between
make setup-source SOURCE=nfl  CONFIRM=1   # x2, one fix in between
make setup-source SOURCE=wnba CONFIRM=1   # x2
```

**Result**

```
DLT_DB.OPS.V_LOG_LINES        one row per log line, four formats parsed
DLT_DB.OPS.V_METRICS          one row per metric sample, group derived
DLT_DB.OPS.V_TASK_RUNS        one row per run: 44 rows, 44 distinct query ids
DLT_DB.OPS.DLT_EVENTS_RETENTION   task, state=started, Sun 04:30 UTC
NFL_PROD_DB.OPS.V_PIPELINE_RUNS   42 rows / 42 runs, 5 dlt_record_missing
WNBA_PROD_DB.OPS.V_PIPELINE_RUNS   2 rows /  2 runs
```

The one run with full telemetry reads exactly as designed: 92s task, 63s container span, 29s
startup overhead, 416 log lines, 179 metric samples, 0.127 cores from **one** sample, 133 MB.

`ROWS_LOADED` correctly excludes `_dlt_pipeline_state`: `nfl_stats` reads 85, not 86.

**Surprises**

Four bugs, all silent, all caught by comparing output to a known answer rather than by an error:

1. **`CREATE VIEW` was never granted.** `01_event_table.sql` granted `CREATE DYNAMIC TABLE`,
   left over from the earlier design. The failure reads
   `Insufficient privileges to operate on schema 'OPS'`, which names the schema rather than the
   missing privilege and looks like a role problem.

2. **`QUALIFY` after `UNION ALL` binds to the last branch only.** Written as
   `SELECT ... UNION ALL SELECT ... QUALIFY`, the deduplicate silently did not happen and every
   run appeared twice, once per history source. No error; the row count just doubled. Fixed by
   wrapping the union in its own CTE.

3. **`TIMESTAMP_NTZ` compared against `TIMESTAMP_LTZ`.** The event table's `TIMESTAMP` is NTZ
   holding UTC; `TASK_HISTORY.QUERY_START_TIME` is LTZ. Compared directly, the NTZ value is read
   in session time and the boundary lands seven hours in the future, so `TELEMETRY_AVAILABLE`
   was FALSE for every row including ones sitting on 416 log lines.

4. **Two different history boundaries, and I used the wrong one.** `DLT_RECORD_MISSING` was
   guarded on `TELEMETRY_AVAILABLE`, the event table's boundary of 2026-08-08. `_DLT_RUNS` has
   been collecting since 2026-08-01. Every genuinely missing record predated the event table, so
   the column came back false for all 42 rows. A column that is always false does not look
   broken.

Also worth recording, from building `V_METRICS`:

- **`RESULT_LIMIT` on `INFORMATION_SCHEMA.TASK_HISTORY` defaults to 100.** Seventeen Tasks over
  seven days exceeds that, and the truncation is silent. Set to 10000, the maximum.
- **A view CAN wrap an `INFORMATION_SCHEMA` table function.** Open question in the design;
  answered by building one. This is what makes the zero-lag half of `V_TASK_RUNS` possible.
- **Metric rows carry `snow.compute_pool.name` and `snow.compute_pool.node.instance_family`**,
  which log rows do not. That is the only place the pool and node size are recorded, and it is
  what separates prod from dev runs sharing one event table.
- **The metrics that matter are the sparsest.** Across every run collected so far:
  `container.cpu.limit` 37 samples, `container.cpu.usage` **2**. Constants are sampled every
  scrape; the varying ones are not.

**Changed from plan**

- **The dynamic table became a view.** Measured first: ~74k rows at steady state, full parse over
  14.8k rows in well under a second. A dynamic table mirrors its source so it buys no retention
  once `05` trims at 30 days, it costs ~0.4 credits/day whether or not anyone looks, and its
  `TARGET_LAG` is backwards for a view you read right after a failure.
- **Added `V_METRICS`**, which the plan did not have. The plan surfaced metrics only as a
  per-run rollup, which throws away the individual samples and contradicts the decision to
  collect all five groups and filter downstream.
- File numbering shifted: retention is now `05`, not `04`.

**Open**

- The `_DLT_RUNS` join is still a time window, because `_DLT_RUNS` carries no run identifier.
  Verified 1:1 with no fan-out on all live rows, but two concurrent runs of one pipeline would
  be ambiguous. One line in `observability.py` stamping `SNOWFLAKE_SERVICE_NAME` turns it into
  an equality join.
- `V_LOG_LINES` reports duplicates rather than deduplicating them, because `run.py` emits every
  `dlt_pipeline` message twice. Filtering is left to the consumer via `LOG_FORMAT`.
- Cost of the views under real dashboard load is unmeasured. The estimate rests on a single
  timing over 14.8k rows.
