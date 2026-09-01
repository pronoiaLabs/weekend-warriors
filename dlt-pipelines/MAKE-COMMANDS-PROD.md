# Running the NFL and NCAAF pipelines in production

(The mechanics here -- Tasks, tokens, deployment, watching, backfilling --
apply to every sport. The schedules and calendars are per sport: NFL below,
NCAAF in its own section near the end.)

Scheduled Snowflake Tasks loading `NFL_PROD_DB.RAW`. The third runbook, after
[MAKE-COMMANDS.md](MAKE-COMMANDS.md) (laptop) and [MAKE-COMMANDS-SPCS.md](MAKE-COMMANDS-SPCS.md)
(container, by hand).

The difference that matters: **nobody is watching.** A Task fires at 11:00 UTC and reports itself
only in `TASK_HISTORY` and `_DLT_RUNS`. Everything below exists because a failure here is silent by
default.

---

## What a Task can and cannot do

A Task passes **no arguments**. There is no `--resource`, no `--param`, no season on a command line.
That single constraint explains most of the design:

| Need | How a manual run does it | How a Task does it |
|---|---|---|
| Which season | `PARAM="season=2026"` | `{current_season}` token in the registry, resolved at run time |
| The API key | `SECRET=` on the command line | `secret` field in the registry, bound by the job spec |
| Network egress | `EAI=` on the command line | `external_access` field, emitted into the Task DDL |
| Which database | resolved from the registry | resolved from the registry, always `_PROD_DB` |

So a scheduled pipeline must carry `schedule`, `secret`, `env_var` and `external_access` in its
registry entry. `make test` fails if one is missing, because the alternative is finding out at
11:00 UTC.

### The season token

```yaml
- name: standings
  endpoint:
    params:
      season: "{current_season}"
```

`run.py` substitutes the real year before dlt sees the config. The rule is `year if month >= 8 else
year - 1`, so it rolls over on 1 August when preseason opens, and January stays on the season that is
still being played.

**A backfill still wins.** `--param season=2023` merges after the token resolves, so nothing about
scheduling changes how you load history.

**Why not a literal year.** It works until the August nobody remembers it. Then every nightly load
reports success while re-fetching a season that ended months ago.

---

## The schedules, and the calendar behind them

Everything NFL runs once a day in one 11:00-12:20 UTC window, except injuries (deadline-driven at
22:00). One window, one warm warehouse and pool, one 12:30 dbt build.

| Pipeline | Cron (UTC) | Cadence | Why |
|---|---|---|---|
| `nfl_reference` | `0 11 * * *` | daily | rosters churn on waivers all season; first in the window so players land before stats |
| `nfl_games` | `5 11 * * *` | daily | flex scheduling moves kickoffs; scores same-day |
| `nfl_stats` | `10 11 * * *` | daily | box scores follow the games |
| `nfl_nflverse_stats` | `15 11 * * *` | daily | nflverse season files (pbp, player weeks, snaps, Next Gen, injury reports) merged on their keys; a reload is how corrections arrive. 11:15 is the window's floor: nflverse rebuilds overnight |
| `nfl_odds_opening` | `20 11 * * *` | daily | immutable game and player-prop openings, both fanned out per game |
| `nfl_weather_forecast` | `25 11 * * *` | daily | 16-day outlook for outdoor and retractable sites |
| `nfl_game_odds` | `15 2,6,10,14,18,22 * * 0,1,4,5,6` | every 4h Thu-Mon | SCD2 snapshots of current game lines; cadence IS the line-history resolution |
| `nfl_player_props` | `25 2,6,10,14,18,22 * * 0,1,4,5,6` | every 4h Thu-Mon | SCD2 snapshots, staggered ten minutes off game odds for the shared key |
| `nfl_nflverse_depth_charts` | `45 11 * * *` | daily | one new depth-chart snapshot a day, cursor on `dt` |
| `nfl_nflverse_reference` | `50 11 * * 3` | Wednesday | all-history files replaced: players id crosswalk, officials, combine, trades |
| `nfl_news` | `20 2,6,10,14,18,22 * * *` | every 4h | Firecrawl RSS scrape in the odds/props cycle's middle slot; six runs keep the short-post wires whole |
| `nfl_plays` | `0 12 * * 2` | Tuesday | ~334 requests; plays are final once a game ends |
| `nfl_standings` | `5 12 * * 2` | Tuesday | only meaningful after a full week |
| `nfl_sleeper_players` | `10 12 * * *` | daily | the ~15 MB player dump, replaced; Sleeper asks for at most one pull a day |
| `nfl_sleeper_market` | `15 12 * * *` | daily | trending adds/drops (a 24h window, so daily loses nothing) and this week's projections as dated snapshots; stats for this week and last merged |
| `nfl_injuries` | `0 22 * * *` | daily | scd2, so a missed state is gone permanently; late by deadline, see below |

Cron is five fields, **Sunday is 0**, so Tuesday is `2`.

Neither vendor entry carries a season token. nflverse's `seasons: current` asks nflreadpy for its
own year (game data rolls the Thursday after Labor Day, depth charts on 15 March), logged on every
run; Sleeper reads season, week and season_type from `/v1/state/nfl` at the top of every run.
History is the unscheduled backfill entries (2023 onward, the BallDontLie floor), run once each:
`make run-prod NAME=nfl_nflverse_backfill CONFIRM=1` and `make run-prod NAME=nfl_sleeper_backfill CONFIRM=1`;
the Tasks then keep the current season fresh.

**Why one 11:00-12:20 window instead of staggering across the day.** Every warehouse resume bills a
60-second minimum plus a 60-second auto-suspend tail, so spread-out wakes cost more than the queries
they run (measured 2026-08-30: two thirds of daily spend was wake overhead). One window warms the
warehouse and pool once; the 5-minute stagger, rather than the same minute, keeps one API key from
being hit concurrently and lets a single warm pool node work through the queue. dbt is no longer
load-triggered: `DBT_BUILD_NFL` is a scheduled task at 12:30 and 22:30 UTC whose `WHEN
SYSTEM$STREAM_HAS_DATA` clause drains the whole window in one `ARGS='run'` (models only) build and
makes an empty slot a free SKIPPED. Tests run once a day on `DBT_TEST_NFL` at 13:00 UTC.
`sql/**` is not CI-applied: after merging trigger SQL, `make setup-source SOURCE=nfl CONFIRM=1`
(and `SOURCE=ncaaf`) is required.

The betting and news Tasks are the one intraday exception (restored 2026-09-01 after a single
daily-cadence day proved an extra cycle costs ~0.15 credits under the scheduled-build design):
a tight :15/:20/:25 cluster at hours 2/6/10/14/18/22, odds and props on game days, news every
day. Only observations captured while they run exist -- line movement between pulls cannot be
backfilled. No build fires behind them; their loads drain at the next 12:30/22:30 build, so the
pages lag up to half a day while the snapshots keep full resolution.

**Why 11:00 UTC.** nflverse rebuilds its files overnight and cannot be pulled before ~11:15, which
sets the window's floor; everything else joined it there. It also clears Monday Night Football
(final ~03:45 UTC Tuesday under EDT, 04:45 under EST) by hours, so the DST drift on 1 November
changes nothing.

**Why `nfl_injuries` is late and daily.** Injury reports are filed Wed/Thu/Fri by 16:00 ET. 22:00 UTC
is 18:00 EDT and 17:00 EST, after the deadline year-round. This is the one table where cadence is not
a convenience: it is scd2, so a state never captured while true cannot be recovered by any backfill.

### 2026 season dates

| Date | Day | Event |
|---|---|---|
| 6 Aug 2026 | Thu | Hall of Fame Game, preseason opens |
| 13 to 29 Aug | | Preseason weeks 1 to 3 |
| **30 Aug, 18:00 ET** | Sun | 90 to 53 roster cut, the year's biggest `players` churn |
| 31 Aug, 13:00 ET | Mon | waivers clear, practice squads form |
| **9 Sep 2026** | Wed | regular season opener (a Wednesday, unusually) |
| 10 Sep | Thu | Melbourne game, 20:35 ET |
| 10 Nov, 16:00 ET | Tue | trade deadline |
| 10 Jan 2027 | Sun | Week 18 ends |
| 16 Jan to 14 Feb 2027 | | postseason through Super Bowl LXI |

Games run Thu 20:15, Sun 09:30 (international) / 13:00 / 16:25 / 20:20, Mon 20:15 ET, with Saturday
games from Week 16.

**Two things not to hardcode anywhere.** Games per week varies from 13 to 16 because byes run Weeks 5
to 14. And flex scheduling moves kickoffs with 12 to 28 days notice, which is why `nfl_games` re-reads
daily instead of assuming the schedule has settled.

---

## First deployment

```bash
make setup-prod CONFIRM=1
```

Creates `DLT_POOL`, `DLT_WH` and the `DLT_LOADER` service user. `NFL_PROD_DB` already exists from
`make setup-source SOURCE=nfl CONFIRM=1`.

**Seed the data.** Do **not** clone a person's `DEV_<user>` schema as the way to introduce a new
RAW table. That was the original NFL bootstrap (recipe below, kept because it is how GAMES got
here). New tables: empty landing DDL in `sql/sources/<vendor>/` (`make setup-source`), then
`make run-prod NAME=<pipeline> CONFIRM=1`. A one-time `CREATE OR REPLACE TABLE … CLONE` is only
for a backfill already sitting in a sandbox you do not want to fetch again.

Cloning a **whole** schema from dev is instant, costs no storage and makes no API calls, and it
carries dlt's `_dlt_*` state so the first Task continues rather than rebuilding:

**Neither role can do this alone, and that is the isolation working.** `DLT_LOADER_ROLE` has no
grant at all on `NFL_DEV_DB`, so it cannot read the source. `DLT_DEV_ROLE` has none on `NFL_PROD_DB`,
so it cannot write the target. Only `SYSADMIN`, which both roles are granted to, spans them.

But a schema created by `SYSADMIN` is **owned** by `SYSADMIN`, and the Task's role could then read it
and not write to it. So the ownership transfer is not optional:

```sql
USE ROLE SYSADMIN;

DROP SCHEMA IF EXISTS NFL_PROD_DB.RAW;                 -- CLONE cannot target an existing schema
CREATE SCHEMA NFL_PROD_DB.RAW CLONE NFL_DEV_DB.DEV_JSMITH;

DROP TABLE IF EXISTS NFL_PROD_DB.RAW.CUSTOMERS;        -- sample fixtures ride along
DROP TABLE IF EXISTS NFL_PROD_DB.RAW.ORDERS;

-- Without these the first Task fails on a permission error that reads nothing like
-- an ownership problem.
GRANT OWNERSHIP ON SCHEMA NFL_PROD_DB.RAW
    TO ROLE DLT_LOADER_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA NFL_PROD_DB.RAW
    TO ROLE DLT_LOADER_ROLE COPY CURRENT GRANTS;
```

Verify before moving on:

```sql
SHOW SCHEMAS LIKE 'RAW' IN DATABASE NFL_PROD_DB;   -- owner must read DLT_LOADER_ROLE
SELECT COUNT(*) FROM NFL_PROD_DB.RAW.GAMES;        -- 1002 for three seasons
```

```bash
make sync-apply          # schedules + bindings into DLT_DB.OPS.PIPELINE_REGISTRY
make tasks-sql           # review build/tasks.sql
make tasks-apply         # Tasks created SUSPENDED, applied as DLT_LOADER_ROLE
```

**Read `build/tasks.sql` before applying it.** One `CREATE OR ALTER TASK` per scheduled pipeline,
each carrying its full container spec inline and followed by an `ALTER TASK ... SET TAG
COST_CENTER = 'ingestion'` (the tag itself lives in `sql/ops/08_cost_tags.sql`, which must have
been applied first: the ALTER needs APPLY on the tag). `make deploy` does sync and apply in one
step once you trust it.

**The spec is inlined rather than staged.** `SPECIFICATION_TEMPLATE_FILE` looked tidier, but every
Task failed two seconds after firing with `Unable to render service spec from given template:
Object 'snowflake.snowpark.pypi_shared_repository' does not exist or not authorized`. Snowflake's
server-side renderer resolves a dependency we do not control, and granting
`SNOWFLAKE.PYPI_REPOSITORY_USER` did not help because it was already granted to `PUBLIC`. Rendering
locally removes the whole class of problem, and the emitted SQL now states exactly what will run.

The cost: changing the image or container env means re-running `make tasks-apply` rather than
re-uploading one file. There is no prod spec upload at all now; `@DLT_DB.DEPLOY.SPECS` serves the
dev templates only.

---

## Starting and stopping

Tasks are created **suspended**. Generating a schedule and starting one are different decisions.

`nfl_app_to_postgres` and `obs_to_postgres` are not cron. They are standalone
Tasks in `DLT_DB.OPS`. `NFL_PROD_DB.OPS.APP_COPY_NFL` (08) sits `AFTER`
harvest and `EXECUTE TASK`s the APP loader. `OBS_COPY` (DLT_LOADER_ROLE)
sits after `OBS_REFRESH`; `DBT_OBS_COPY` (DBT_RUNNER_ROLE) sits after
`DBT_RUNS_REFRESH` — one owner per graph. `make tasks-suspend` does not
touch those graphs. Setup and laptop prove:
[MAKE-COMMANDS-POSTGRES.md](MAKE-COMMANDS-POSTGRES.md).

```bash
snow sql -c weekend-warriors --role DLT_LOADER_ROLE -q "
ALTER TASK DLT_DB.OPS.dlt_task_nfl_reference RESUME;"
```

```sql
ALTER TASK DLT_DB.OPS.dlt_task_nfl_reference SUSPEND;

SHOW TASKS IN SCHEMA DLT_DB.OPS;    -- `state` is started | suspended
                                    -- `owner` must read DLT_LOADER_ROLE
```

**Check the `owner` column the first time.** A Task runs with its owner's privileges,
so one created by `SYSADMIN` works while granting every scheduled load far more than it
needs. `make tasks-apply` uses `$(SNOW_LOADER)` to get this right; a Task applied by
hand without `--role` will not be.

**Resume one at a time, cheapest first**, confirming each before the next: `nfl_reference` (32 rows
plus a merge), then `nfl_standings`, then the daily ones, then `nfl_plays`, `nfl_game_odds`, and
`nfl_player_props` last because their per-game fan-outs make them the expensive Tasks.

Run one by hand without waiting for its cron:

```sql
EXECUTE TASK DLT_DB.OPS.dlt_task_nfl_reference;
```

That works on a suspended Task, which makes it the right way to test before resuming anything.

---

## Watching it

Three layers, and they fail differently.

```sql
-- 1. Did the Task fire, and did the SQL succeed?
SELECT name, state, scheduled_time, completed_time, error_code, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(day, -2, CURRENT_TIMESTAMP())))
ORDER BY scheduled_time DESC;

-- 2. Did the pipeline inside it load anything?
SELECT pipeline, status, row_counts::string AS counts, error, finished_at
FROM NFL_PROD_DB.OPS._DLT_RUNS
WHERE finished_at > DATEADD(day, -2, CURRENT_TIMESTAMP())
ORDER BY finished_at DESC;

-- 3. Why did the container fail? Job services are auto-named, so find it first.
SHOW SERVICES IN SCHEMA DLT_DB.DEPLOY;
--   the `comment` column carries the pipeline name; take the newest matching `name`
SELECT SYSTEM$GET_SERVICE_LOGS('DLT_DB.DEPLOY.JOB_<uuid>', 0, 'dlt');
```

**Job services have generated names on purpose.** A completed job is kept for 30 days
so its logs stay readable, and there is no `OR REPLACE`, so a fixed name would succeed
once and collide on every run after. Letting Snowflake name each run keeps a month of
per-run history instead of destroying the previous night's logs. `COMMENT` carries the
pipeline name so `SHOW SERVICES` is still readable.

**A green Task is not a successful load.** `TASK_HISTORY` reports whether `EXECUTE JOB SERVICE`
returned, and a job that runs and loads zero rows returns fine. `_DLT_RUNS` is the one that knows what
was written. Check layer 2, not layer 1.

**A missing `_DLT_RUNS` row is worse than a failed one.** It means the container died before the
observability write, so look at layer 3.

### Failure table

| Symptom | Cause | Fix |
|---|---|---|
| Task never fires | still suspended | `ALTER TASK ... RESUME` |
| `Object 'DLT_DB.DEPLOY.DLT_JOB_...' already exists` | a fixed job-service NAME | omit `NAME`; a completed job lingers 30 days |
| `Insufficient privileges to operate on schema 'OPS'` | auto-named services are created in the Task's own schema | `GRANT CREATE SERVICE ON SCHEMA DLT_DB.OPS TO ROLE DLT_LOADER_ROLE` |
| `syntax error ... unexpected 'EXTERNAL_ACCESS_INTEGRATIONS'` | clause after `FROM` | it belongs before `FROM` |
| `SECRET ... does not exist or not authorized` | missing `READ` on the secret | `GRANT READ ON SECRET ... TO ROLE DLT_LOADER_ROLE` |
| `KeyError` from `dlt.secrets` | `env_var` does not match the registry `secret:` path | fix the registry, re-sync |
| connection timeout to the API | EAI missing from the Task | check `external_access` is set, re-generate |
| cannot create schema `RAW_STAGING` | no `CREATE SCHEMA` grant | `sql/sources/<name>/01_databases.sql` grants it |
| runs fine, loads a stale season | token did not resolve | check the log line `resolved runtime tokens` |
| `no enabled pipeline named ...` | registry table out of date | `make sync-apply` |

---

## Alerting

Failure pings go to Slack from inside the failing run itself — the runner
(`pipelines/common/alerts.py`, gated on `DLT_ALERTS=1` which only the prod
job template sets) and each sport's `SP_DBT_BUILD` / `SP_DBT_TEST` exception
handlers. Both
send through the account's `SLACK_ALERTS_INT` webhook integration
(`sql/ops/09_alerting.sql`). Noise policy is transitions + recovery via the
`DLT_DB.OPS.ALERT_STATE` latch: first failure of a streak pings, the first
success after pings RECOVERED, everything between is silent.

What silence means: healthy, OR one of the two designed blind spots — a
container that never started, or a schedule that is dead without failing
(all tasks suspended). The dashboard still shows both; only the ping is
absent.

```sql
-- Pause all pings (senders keep working; their errors are swallowed):
ALTER NOTIFICATION INTEGRATION SLACK_ALERTS_INT SET ENABLED = FALSE;

-- Smoke the delivery path (run as the WORKER role, not SYSADMIN --
-- task sessions carry the owner's primary role alone):
CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
  SNOWFLAKE.NOTIFICATION.TEXT_PLAIN(
    SNOWFLAKE.NOTIFICATION.SANITIZE_WEBHOOK_CONTENT('smoke')),
  SNOWFLAKE.NOTIFICATION.INTEGRATION('SLACK_ALERTS_INT'));

-- "Enqueued notifications" proves nothing: delivery is async. Verify with
SELECT * FROM TABLE(DLT_DB.INFORMATION_SCHEMA.NOTIFICATION_HISTORY(
  RESULT_LIMIT => 20)) ORDER BY CREATED DESC;   -- 14-day lookback

-- What has alerted, and what is currently latched failing:
SELECT * FROM DLT_DB.OPS.ALERT_STATE ORDER BY UPDATED_AT DESC;
```

Rotating the webhook (Slack app rebuilt, URL leaked): create the new Slack
webhook, then `ALTER SECRET DLT_DB.OPS.SLACK_ALERTS_WEBHOOK SET
SECRET_STRING = '<part after /services/>'`. No integration or code change;
the secret substitutes at send time. A stuck `failing` row alongside a green
dashboard self-heals on the scope's next successful run (the success hook
sends a late RECOVERED and clears it); only a scope that will never run
again — a paused sport, a retired pipeline — needs a manual `UPDATE` of its
`STATUS` to `'ok'`, or just `DELETE` the row.

---

## Checking a season rollover

The one scheduled behaviour that changes without anyone editing anything. On 1 August the token
starts resolving to the new year.

```bash
python -m pipelines.batch.models --current-season
```

After the first scheduled run past a rollover:

```sql
SELECT season, COUNT(*) FROM NFL_PROD_DB.RAW.STANDINGS GROUP BY season ORDER BY season;
```

The new season should appear. If it does not, the token did not resolve, and the container log says
so directly: look for `resolved runtime tokens`.

For `nfl_games` and `nfl_stats` the failure mode is the opposite and quieter. Those endpoints ignore
an unrecognised filter rather than rejecting it, so a broken token means **every** season comes back
and the run looks unusually productive:

```sql
SELECT COUNT(DISTINCT season) FROM NFL_PROD_DB.RAW.GAMES;
```

---

## Backfilling in production

Scheduled Tasks only ever load the current season, so history has to be loaded some other way.

**There is no `make` target for this yet, deliberately.** `make run-spcs` is hardwired to the dev
environment: it resolves the database with `--env DEV`, submits as `DLT_DEV_ROLE`, and uses
`DLT_DEV_POOL`. None of those can touch `NFL_PROD_DB`, and widening them would give the dev path a
route into production, which is the boundary this layout exists to create.

Two workable options, neither built:

- **Backfill in dev, then clone forward.** Load the season into `NFL_DEV_DB.DEV_<user>` with the
  normal SPCS commands, then clone as above. Cheap and uses the path that is already proven, but it
  replaces the whole prod schema rather than adding to it, so it only suits a quiet moment.
- **A prod backfill target.** `run-spcs` gains an `ENV=` switch that also selects the role and pool.
  Small, but it is a new way into production and deserves its own review rather than being added in
  passing.

Whichever gets built, the merge keys mean a backfill and a scheduled run cannot corrupt each other.

Opening lines are the betting exception: they are immutable and can be backfilled in dev for
2023-2025 before cloning forward. Live `ODDS` and `PLAYER_PROPS` are SCD2 observations of what the
API returns now; no command can reconstruct line movement that was not captured at the time.

```bash
for SEASON in 2023 2024 2025; do
  make run-snowflake NAME=nfl_odds_opening RESOURCE=odds_opening_regular \
    PARAM="opening_games_regular_ref:seasons[]=$SEASON"
  make run-snowflake NAME=nfl_odds_opening RESOURCE=odds_opening_post \
    PARAM="opening_games_post_ref:seasons[]=$SEASON"
  make run-snowflake NAME=nfl_odds_opening RESOURCE=player_props_opening_regular \
    PARAM="opening_games_regular_ref:seasons[]=$SEASON"
  make run-snowflake NAME=nfl_odds_opening RESOURCE=player_props_opening_post \
    PARAM="opening_games_post_ref:seasons[]=$SEASON"
done
```

The parent filter is required for both opening tables. `/odds/opening` rejects `season` alone and
accepts only bracketed `game_ids[]`, which the child resources resolve from those parents.

---

## NCAAF: schedules and calendar

**THE SPORT IS PAUSED (2026-09):** the BDL subscription's NCAAF access lapsed
(every endpoint 401s), so the registry schedules are commented out, the
generator no longer manages the Tasks, and the live NCAAF Tasks plus its dbt
build/test roots are suspended by hand. The resume recipe is in
ncaaf-registry.yml's header. The table below describes the paused design.

Deployed 2026-08-09 (WORKFLOW-7). The band is **02:00-07:59 UTC**, below the
NFL's 11:00-12:20 window, so the two sports never stack against the shared
600 req/min API limit or `DLT_POOL`.

| Pipeline | Cron (UTC) | Cadence | Why |
|---|---|---|---|
| `ncaaf_games` | `0 6 * * *` | daily | the latest kickoffs (Hawaii, 10:30pm ET Sat) go final ~05:45 UTC; 06:00 catches the whole slate same-night. Anchor of the cluster; first so stats can join on games |
| `ncaaf_stats` | `5 6 * * *` | daily | box scores right behind the games |
| `ncaaf_standings` | `10 6 * * 1` | Monday | weekend settled well before Monday morning; scd2 weekly snapshot |
| `ncaaf_season_stats` | `15 6 * * 1` | Monday | rollups move when games complete |
| `ncaaf_rankings` | `20 6 * * 1` | Monday | AP poll releases Sunday ~18:00 UTC; endpoint returns the latest week only, so the weekly run accumulates the season |
| `ncaaf_reference` | `10 6 * * 3` | Wednesday | 536 teams + 124k players is ~1,250 requests; college rosters churn on portal windows, not daily waivers |

**One 06:00-06:20 window, same pattern as the NFL's 11:00 window.** The pool
and warehouse wake once per morning, and `DBT_BUILD_NCAAF` is a scheduled
task at 06:45 UTC whose `WHEN SYSTEM$STREAM_HAS_DATA` drains the whole
cluster in one `ARGS='run'` build (an empty day is a free SKIPPED). The
cluster stays inside the NCAAF band, so the sports still never stack against
the shared API limit. Daily tests are `DBT_TEST_NCAAF` at 07:00 UTC. Apply
trigger SQL with `make setup-source SOURCE=ncaaf CONFIRM=1`.

**No injuries, no plays, no odds.** The API has no NCAAF injuries endpoint at
all; play-by-play carries no down/distance/field position (scoring timeline
only) and odds were scoped out. All three can be added later as registry
entries.

**Postseason has no flag.** No `season_type` and no `postseason` boolean
exist for this sport; bowls and the CFP arrive in the same `/games` stream
marked `week: 999` (with at least one known mislabel, the Jan 2025 Gator
Bowl as week 1). Anything that separates regular season from bowls does it
on `week`, downstream.

### 2026 season dates

| Date | Event |
|---|---|
| ~11 Aug 2026 | preseason AP poll (first `ncaaf_rankings` rows of the season) |
| 29 Aug 2026 (Sat) | week 1 begins; 1,623 games already on the schedule |
| Sep-Nov | regular season, Saturdays; weeks 1-16 |
| early Dec | conference championships (still week-numbered) |
| mid Dec onward | bowls + CFP, `week: 999` |
| Jan 2027 | CFP final; season 2026 rows carry January dates |
| 1 Aug 2027 | `{current_season}` rolls to 2027 (`season_rollover_month: 8`) |

**Rankings backfill is a week loop**, unlike everything else: the endpoint
returns only one week per call, so history is
`PARAM="rankings:season=2025 rankings:week=5"` iterated over weeks 2-16.
Games, stats and season stats take the usual season params; standings takes
`PARAM="standings:season=2024"` and fans out over all 25 conferences on its
own.
