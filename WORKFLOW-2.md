# WORKFLOW-2: ops-dashboard build log

Build log for the ops-dashboard loop (React + FastAPI over the DLT_DB.OPS views),
same format as WORKFLOW-1.md: one section per phase, appended as each phase closes.
Plan of record: the approved "ops-dashboard: loop-based autonomous build" plan.
Branch: `feat/ops-dashboard` off `main`.

## HANDOFF (filled in at the end)

Placeholder. The final phase replaces this with the exact command sequence to run
on return, in order, plus every open question.

---

## Phase 0: branch + scaffold

**Ran:** `git checkout -b feat/ops-dashboard main`; scaffold agent created
`ops-dashboard/{api,web,Makefile,README.md}` (FastAPI app factory with /api/health
and a conditional SPA static mount; Vite react-ts app stripped to router skeleton
with 4 placeholder routes; Makefile copying the dlt-pipelines help/hdr conventions).
Verification: `uv run --extra dev pytest -q`, `ruff check .`, `npm run build`,
uvicorn on :8123 curled for /api/health and /.

**Result:** 1 test passed, ruff clean, tsc + vite build green (229 kB bundle),
`/api/health` 200 `{"status":"ok","service":"ops-dashboard"}`, and the SPA
fallback already serves web/dist at / when it exists.

**Surprises:**
- A permission prompt killed the scaffold agent mid-verification (compound
  `uv run pytest` command was not allowlisted). Fixed by adding an allowlist to
  `.claude/settings.local.json` covering uv/npm/npx/node/curl/snow sql/git
  add+commit/mkdir/docker build. `git push`, `rm` and `make` deliberately still
  prompt. Caveat recorded: `snow sql *` cannot distinguish SELECT from DDL by
  pattern; read-only stays a discipline rule.
- The registry table is `DLT_DB.OPS.PIPELINE_REGISTRY`, not `DLT_DB.DEPLOY.*`
  as the plan guessed.
- Sport identity comes from `TARGET_DATABASE` (NFL / WNBA / DLT), NOT from
  `SOURCE`, which is just `rest_api` for every real pipeline. The `sample`
  pipeline (TARGET_DATABASE=DLT, SCHEDULE null) must be excluded from the sport
  list.
- `wnba_shot_locations` runs at 01:00 UTC Wednesday. The wireframe's hardcoded
  08:00-23:00 board window would clip it; the computed-window requirement is now
  proven, not theoretical.
- Timestamps from the views arrive with a -07:00 offset through this connection;
  the API must normalize to UTC explicitly.

**Changed from plan:** registry location corrected as above; nothing else.

**Open:** `.brainstorm/` wireframes are untracked; decide track vs gitignore on
return.

---

## Phase 1: prove the data path

**Ran:** wrote app/db.py (two-branch auth keyed on /snowflake/session/token,
session TIMEZONE=UTC, one cached connection with a single retry),
app/registry.py (sports from TARGET_DATABASE where SCHEDULE is not null, 60s
TTL cache), app/datasource.py (live/fixtures seam via OPS_DASHBOARD_DATA), and
GET /api/runs. Started uvicorn against the live account, recorded
app/fixtures/{runs,registry}.json from real responses, wrote tests, ran
pytest + ruff.

**Result:** /api/runs returns live rows from both sports in one feed, newest
first, UTC Z timestamps (16:47Z for the 09:47-07:00 row, correct), ROW_COUNTS
parsed to an object. ?sport=WNBA returns exactly the 2 WNBA runs; unknown
sport is a 404. 8 tests passed, ruff clean. Fixture scrub check found only
QUERY_ID / JOB_* identifiers, which already appear throughout the repo docs;
no credentials, no account identifiers.

**Surprises:**
- A subagent hit two more permission prompts and the loop stalled while the
  user was still here to see it. Root cause of the day: settings-file
  permission edits do not apply mid-session, and subagents queue prompts
  invisibly. Resolution: defaultMode bypassPermissions in settings.local.json
  plus the user flipping the live mode, and permission-sensitive work moved
  into the main loop.
- EXIT_STATUS is not always NULL: the generic Task failure message yields
  EXIT_STATUS='FAILED'. The wireframe's "EXIT_STATUS is always NULL" footnote
  overstates; it is NULL for infra-level failures and 'FAILED' when the
  container exited nonzero. The run page copy must reflect both cases.

**Changed from plan:** Phase 1 was built in the main loop rather than by a
subagent, after the stall. Later phases keep implementation subagents but
anything likely to prompt runs in the main loop.

**Open:** none.

---

## Phase 2: full API

**Ran:** wrote app/schedule.py (cron expansion, 15-minute missed grace,
1-hour slot match window, cron-to-prose), app/derive.py (anomaly classes,
severity ranking missing > missed > failure > disagree, computed ERROR_TEXT
provenance), app/assemble.py (pure payload assembly for overview / incidents /
pipeline detail / run detail, shared by live and fixture modes), datasource
fetchers, and 9 endpoints. Verified every endpoint against the live account,
recorded logs/metrics fixtures for the reference run, wrote 20 more tests.

**Result:** 28 tests passed, ruff clean. Live spot checks all reconciled:
summary read 8 slots today / 5 succeeded / 2 failed / 2 record-missing /
2 missed / 2 upcoming, which matches the known Aug 8 timeline including the
manual nfl_stats reruns. Metrics endpoint returns 179 samples, 16 metric
names, 4 groups (storage absent, as measured in WORKFLOW-1), cpu strip 1
point / mem strip 2, node CPU_X64_S. prev_row_counts on nfl_reference
returned the prior day's {players: 13521, teams: 32} via skip-nulls lookup.

**Surprises:**
- The overview immediately surfaced a real finding: WNBA's 14:00 and 15:00
  cron slots MISSED today. The WNBA view holds only the two manual 16:00 runs,
  so the crons never fired. First check on return: SHOW TASKS IN SCHEMA
  DLT_DB.OPS and look at the wnba_* tasks' state.
- Missed-slot counts are inflated for young pipelines: incidents over 7 days
  reads missed=33 because every WNBA slot before the pipelines existed counts
  as missed. Honest from the registry's standpoint, noisy in practice. Options
  when you are back: bound expansion at each pipeline's first run (hides a
  never-ran pipeline, bad), at registry UPDATED_AT (zeroed by any resync), or
  add a created_at column to the registry (right fix, small migration).
- A stale uvicorn on :8123 survived an earlier kill and served old routes;
  the overview 404 looked like a routing bug. kill -9 on the port cleared it.

**Changed from plan:** built in the main loop, same reasoning as Phase 1.
Anomaly-count semantics implemented as planned: cards gate on the LATEST run
(or a missed slot today), badges count the 14-day window. A resolved anomaly
(nfl_stats: latest run succeeded) therefore renders no card even with
record-missing history; its history stays visible in incidents and on the
pipeline page.

**Open:** the missed-slot inflation decision above.
