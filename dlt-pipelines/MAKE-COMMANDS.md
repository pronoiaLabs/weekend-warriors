# Running the NFL pipelines

A runbook. Copy commands from here rather than reconstructing them, because the season parameter is
spelled three different ways depending on the endpoint and **getting it wrong is usually silent**.

Everything below targets Snowflake. The database is **not** something you type: the registry says
`database: NFL`, and `make run-snowflake` resolves that to `NFL_DEV_DB` for you, landing in your own
`DEV_<user>` schema inside it. The command echoes the resolved target when it finishes.

`make run-prod NAME=… CONFIRM=1` is the laptop path to **production RAW** as `DLT_LOADER_ROLE`.
Use it to fill a new table that dbt will `source()`, not `CLONE` from `DEV_<you>`. Guarded by
`CONFIRM=1` because it writes prod.

Swap `run-snowflake` for `run-local` to load to DuckDB instead, with no credentials and no risk to
anything.

---

## The season parameter, spelled three ways

This is the only genuinely dangerous part of the whole runbook.

| Pipeline | How to pass a season | Why |
|---|---|---|
| `nfl_games`, `nfl_stats` | `PARAM="seasons[]=2024"` | array parameter, brackets required |
| `nfl_plays` | `PARAM="games_regular_ref:seasons[]=2024"` | the filter goes on the **parent** resource |
| `nfl_standings`, `nfl_advanced_stats` | `PARAM="season=2024"` | singular, and **required** |
| `nfl_game_odds`, `nfl_player_props` | qualified `..._games_*_ref:seasons[]=2024` | live resources fan out from games |
| `nfl_odds_opening` | qualified `opening_games_*_ref:seasons[]=2024` | both opening endpoints fan out from games |
| `nfl_reference`, `nfl_injuries` | none | not season-scoped at all |

**Why this matters.** The API ignores a parameter name it does not recognise and returns 200. So
`PARAM="season=2024"` against `nfl_games` does not error; it quietly pulls **every season ever** and
looks exactly like a successful filtered run. A wrong *type* (`seasons=2024` where an array is
expected) does get a 400, so mistyping is loud and misnaming is not.

**Always check `COUNT(DISTINCT season)` after a first load of a new season.** It is the only thing
that separates the two outcomes.

---

## Full backfill of one season

Set the year once and paste the block. Roughly 10 to 15 minutes, almost all of it `plays_regular`.

```bash
SEASON=2024

# 1. Schedule first. Everything else is easier to sanity-check against it.
make run-snowflake NAME=nfl_games RESOURCE=games_pre     PARAM="seasons[]=$SEASON"
make run-snowflake NAME=nfl_games RESOURCE=games_regular PARAM="seasons[]=$SEASON"
make run-snowflake NAME=nfl_games RESOURCE=games_post    PARAM="seasons[]=$SEASON"

# 2. Box scores, player grain and team grain.
make run-snowflake NAME=nfl_stats RESOURCE=stats_pre          PARAM="seasons[]=$SEASON"
make run-snowflake NAME=nfl_stats RESOURCE=stats_regular      PARAM="seasons[]=$SEASON"
make run-snowflake NAME=nfl_stats RESOURCE=stats_post         PARAM="seasons[]=$SEASON"
make run-snowflake NAME=nfl_stats RESOURCE=team_stats_pre     PARAM="seasons[]=$SEASON"
make run-snowflake NAME=nfl_stats RESOURCE=team_stats_regular PARAM="seasons[]=$SEASON"
make run-snowflake NAME=nfl_stats RESOURCE=team_stats_post    PARAM="seasons[]=$SEASON"

# 3. Standings. Note the singular `season`.
make run-snowflake NAME=nfl_standings RESOURCE=standings PARAM="season=$SEASON"

# 4. Advanced stats. Singular `season`, and no preseason exists for these.
make run-snowflake NAME=nfl_advanced_stats RESOURCE=adv_passing_regular   PARAM="season=$SEASON"
make run-snowflake NAME=nfl_advanced_stats RESOURCE=adv_rushing_regular   PARAM="season=$SEASON"
make run-snowflake NAME=nfl_advanced_stats RESOURCE=adv_receiving_regular PARAM="season=$SEASON"
make run-snowflake NAME=nfl_advanced_stats RESOURCE=adv_passing_post      PARAM="season=$SEASON"
make run-snowflake NAME=nfl_advanced_stats RESOURCE=adv_rushing_post      PARAM="season=$SEASON"
make run-snowflake NAME=nfl_advanced_stats RESOURCE=adv_receiving_post    PARAM="season=$SEASON"

# 5. Play by play last: the longest by far, and the qualified PARAM form.
make run-snowflake NAME=nfl_plays RESOURCE=plays_post    PARAM="games_post_ref:seasons[]=$SEASON"
make run-snowflake NAME=nfl_plays RESOURCE=plays_pre     PARAM="games_pre_ref:seasons[]=$SEASON"
make run-snowflake NAME=nfl_plays RESOURCE=plays_regular PARAM="games_regular_ref:seasons[]=$SEASON"
```

**Not in the block, on purpose:**

`nfl_reference` (teams, players) is **current state, not seasonal**. Running it during a backfill
does not give you the 2019 roster; it overwrites with today's. Run it on its own schedule.

`nfl_injuries` is the same, only more so. See "Tables that only accumulate" below.

Live `ODDS` and `PLAYER_PROPS` movement is also not in the block: the API only exposes the current
line, so historical movement cannot be backfilled. Start their schedules before the games you want
to analyze. Opening lines are backfillable; see the betting section below.

**Everything is safe to re-run.** Current-state resources merge on keys and historical snapshots use
SCD2 content hashes, so a failed or interrupted run is fixed by running it again.

---

## One pipeline at a time

### `nfl_reference`: teams and players

Current state. No season parameter exists.

```bash
make run-snowflake NAME=nfl_reference                      # both
make run-snowflake NAME=nfl_reference RESOURCE=teams       # just one
```

`teams` replaces wholesale (32 rows). `players` merges on `id`, about 13,500 rows and roughly 135
requests.

### `nfl_games`: schedule and results

```bash
make run-snowflake NAME=nfl_games RESOURCE=games_regular PARAM="seasons[]=2024"
make run-snowflake NAME=nfl_games                                    # every season, all types
```

Three resources into one `games` table, one per `season_type`. **All three are needed:** the API
defaults to regular season, so loading only the default silently omits every playoff game.

### `nfl_stats`: box scores, two grains

Six resources into two tables. `stats` is one row per player per game; `team_stats` is one row per
team per game.

```bash
make run-snowflake NAME=nfl_stats RESOURCE=stats_regular      PARAM="seasons[]=2024"
make run-snowflake NAME=nfl_stats RESOURCE=team_stats_regular PARAM="seasons[]=2024"
```

`stats_regular` is the second-biggest job here, roughly 18,000 rows and 180 requests.

### `nfl_plays`: play by play

The big one, and the only pipeline with a **qualified** parameter.

```bash
make run-snowflake NAME=nfl_plays RESOURCE=plays_regular PARAM="games_regular_ref:seasons[]=2024"
```

The prefix is not optional. This pipeline fetches a list of games first, then one request per game,
so the season filter belongs on the resource that lists the games. Put it on `plays` and nothing
happens: by then each request is already about one specific game, and the parent will have listed
**every game the API holds**, turning ~550 requests into several thousand.

Roughly 49,000 rows and 550 requests for a regular season, two to three minutes.

### `nfl_standings`: 32 rows a season

```bash
make run-snowflake NAME=nfl_standings RESOURCE=standings PARAM="season=2024"
```

`RESOURCE=` is needed even with only one resource, because a bare `PARAM` binds to whatever is
selected and the runner refuses to guess. `PARAM="standings:season=2024"` works without it.

**This table keeps history** (scd2). See below.

### `nfl_injuries`: who is hurt today

```bash
make run-snowflake NAME=nfl_injuries
```

No parameters. There is nothing to filter and no history to backfill.

### `nfl_advanced_stats`: tracking metrics

```bash
make run-snowflake NAME=nfl_advanced_stats RESOURCE=adv_passing_regular PARAM="season=2024"
```

Six resources into three tables. `season` is **required**; a bare run returns
`{"param":"season","error":"Invalid value"}`. No preseason data exists for these endpoints.

### NFL betting: live movement and opening lines

`nfl_game_odds` and `nfl_player_props` run every two hours Thu-Mon at minutes 0 and 10. Both fan
out over current-season regular/postseason games and keep SCD2 history. Current lines require
`WHERE _dlt_valid_to IS NULL`.

```bash
# Local DuckDB smoke tests (one child; its selected:false parent runs automatically).
make run-local NAME=nfl_game_odds RESOURCE=odds_regular
make run-local NAME=nfl_player_props RESOURCE=player_props_regular

# Developer Snowflake refreshes.
make run-snowflake NAME=nfl_game_odds
make run-snowflake NAME=nfl_player_props
make run-snowflake NAME=nfl_odds_opening
```

`nfl_odds_opening` runs daily at 09:30 UTC. Backfill immutable opening lines for 2023-2025:

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

Both opening endpoints require a game filter for historical loads. `/odds/opening` specifically
requires bracketed `game_ids[]` (the registry supplies it from the parent); `season` alone and bare
`game_ids` both return HTTP 400. Opening lines merge on `id`; live line movement cannot be
reconstructed by a backfill.

---

## Tables that only accumulate

`STANDINGS`, `PLAYER_INJURIES`, `ODDS`, and `PLAYER_PROPS` use scd2, so they keep every version
rather than overwriting.

**Current rows are `WHERE _dlt_valid_to IS NULL`.** The other tables need no such filter, so it is
easy to forget, and forgetting it silently returns every historical version instead of erroring.

`PLAYER_INJURIES` cannot be backfilled at all. The endpoint only ever answers "today", so its value
comes entirely from running it repeatedly. Every day it does not run is a day of injury history that
does not exist anywhere. It is the only pipeline here with a real cost to not scheduling.

`STANDINGS` can be backfilled per season, but you get the **final** table for a past season, not its
week-by-week progression. That accumulates from now on.

---

## Checking a load

After any first load of a new season:

```sql
-- Did the season filter actually bite? Must return 1.
SELECT COUNT(DISTINCT season) FROM NFL_DEV_DB.DEV_JSMITH.GAMES;

-- Games by type. Expect roughly 49 / 272 / 13 for a modern season.
SELECT season, season_type, COUNT(*) AS n, COUNT(DISTINCT id) AS ids
FROM NFL_DEV_DB.DEV_JSMITH.GAMES GROUP BY 1,2 ORDER BY 1,2;

-- Did the plays fan-out cover every game? `games` must match the GAMES count exactly.
SELECT season_type, COUNT(*) AS n, COUNT(DISTINCT id) AS ids,
       COUNT(DISTINCT game__id) AS games
FROM NFL_DEV_DB.DEV_JSMITH.PLAYS GROUP BY 1 ORDER BY 1;

-- team_stats must be exactly twice its game count.
SELECT season_type, COUNT(*) AS n, COUNT(DISTINCT game__id) AS games
FROM NFL_DEV_DB.DEV_JSMITH.TEAM_STATS GROUP BY 1 ORDER BY 1;
```

### Coverage: is every game represented?

The single most useful check, and the only one that catches a whole game silently going missing.
A fan-out that skips games produces no error, no warning and a green run, and nothing inside `PLAYS`
itself reveals it. You have to join back to `GAMES` and count.

```sql
WITH g AS (SELECT id, season, season_type FROM NFL_DEV_DB.DEV_JSMITH.GAMES)
SELECT season, season_type, COUNT(*) AS games,
  COUNT(*) - COUNT(DISTINCT CASE WHEN s.game__id IS NOT NULL THEN g.id END) AS missing_stats,
  COUNT(*) - COUNT(DISTINCT CASE WHEN t.game__id IS NOT NULL THEN g.id END) AS missing_team_stats,
  COUNT(*) - COUNT(DISTINCT CASE WHEN p.game__id IS NOT NULL THEN g.id END) AS missing_plays
FROM g
LEFT JOIN (SELECT DISTINCT game__id FROM NFL_DEV_DB.DEV_JSMITH.STATS) s ON g.id = s.game__id
LEFT JOIN (SELECT DISTINCT game__id FROM NFL_DEV_DB.DEV_JSMITH.TEAM_STATS) t ON g.id = t.game__id
LEFT JOIN (SELECT DISTINCT game__id FROM NFL_DEV_DB.DEV_JSMITH.PLAYS) p ON g.id = p.game__id
GROUP BY 1, 2 ORDER BY 1, 2;
```

**A non-zero result is not automatically a bug.** Before re-running anything, find the games and ask
the API directly:

```sql
SELECT g.id, g.week, g.date::date, g.home_team__abbreviation, g.visitor_team__abbreviation
FROM NFL_DEV_DB.DEV_JSMITH.GAMES g
LEFT JOIN (SELECT DISTINCT game__id FROM NFL_DEV_DB.DEV_JSMITH.PLAYS) p ON g.id = p.game__id
WHERE g.season = 2024 AND g.season_type = 2 AND p.game__id IS NULL ORDER BY g.week;
```

```bash
curl -s -H "Authorization: $BALL_DONT_LIE_API_KEY" \
  "https://api.balldontlie.io/nfl/v1/plays?game_id=7011&season_type=2&per_page=100"
```

Zero rows from the API means the source does not have it and re-running will not help. Rows from the
API mean the load genuinely missed it, and re-running that resource fixes it.

---

## Known source gaps

Confirmed against the API, not load failures. Re-running does not fix them, and they will not fix
themselves unless the vendor backfills.

**Five 2024 regular-season games have no play-by-play.** All are `Final` and all have complete box
scores; only `PLAYS` is missing them.

| game_id | week | date | matchup |
|---|---|---|---|
| 7011 | 1 | 2024-09-08 | LAC vs LV |
| 7022 | 2 | 2024-09-15 | MIN vs SF |
| 7043 | 3 | 2024-09-22 | DAL vs BAL |
| 7118 | 8 | 2024-10-27 | SEA vs BUF |
| 7122 | 8 | 2024-10-28 | SF vs DAL |

**2025 weekly advanced stats have holes.** Weeks 10 and 12 are thin (2 to 14 quarterbacks instead of
about 32) and week 18 is absent entirely, in all three advanced tables at once. 2022, 2023 and 2024
are complete, so this is a recent gap in the vendor feed rather than a property of the dataset. Worth
re-running 2025 periodically to pick up a backfill, which costs nothing because everything merges.

This also means **season totals cannot be rebuilt by summing weeks** in the advanced tables. The
vendor computes `week = 0` from its own complete data, so it does not match the weeks it publishes.

**The pattern to expect.** The core feeds (`games`, `stats`, `team_stats`, `standings`) have been
complete in every check so far. The derived and detailed ones (`plays`, advanced stats) have holes.
Treat that as a property of the source, and check coverage after every backfill rather than assuming.

**In non-SCD2 tables, `COUNT(*)` should equal the distinct count of the declared key.** SCD2 tables
intentionally hold several versions; filter `_dlt_valid_to IS NULL` before checking current-row
uniqueness.

What ran, and with what parameters:

```sql
SELECT pipeline, resources, params, status, row_counts, finished_at
FROM NFL_DEV_DB.OPS._DLT_RUNS ORDER BY finished_at DESC LIMIT 20;
```

`resources` and `params` are NULL for a whole-pipeline run and populated for a filtered one, so a
partial load cannot masquerade as a complete one.

### 2025 as a baseline

| Table | Rows | pre / regular / post |
|---|---:|---|
| `TEAMS` | 32 | not seasonal |
| `PLAYERS` | 13,503 | not seasonal |
| `GAMES` | 334 | 49 / 272 / 13 |
| `TEAM_STATS` | 668 | 98 / 544 / 26 |
| `STATS` | 23,085 | 4,453 / 17,777 / 855 |
| `PLAYS` | 60,359 | 8,758 / 49,150 / 2,451 |
| `STANDINGS` | 32 | not seasonal |

---

## Other things the Makefile does

```bash
make list                    # every pipeline in registries/*.yml
make help                    # all targets
make run-local NAME=sample   # credential-free smoke test into DuckDB
make test                    # full suite
```

**Run a whole group:**

```bash
make run-snowflake GROUP=nfl     # every NFL pipeline, unfiltered
```

Useful as a refresh once seasons are loaded. Not useful for a backfill, since it cannot pass
per-resource parameters and `nfl_advanced_stats` will fail for want of a `season`.

**Test against DuckDB first** when trying a new season or a changed registry entry. Same commands,
no credentials, nothing written to Snowflake:

```bash
make run-local NAME=nfl_games RESOURCE=games_post PARAM="seasons[]=2019"
```

---

## When something fails

**Re-run it.** Keyed merges and SCD2 content hashes both make a partial load safe to repeat. There
is no cleanup step.

**Check `_DLT_RUNS` for the failure**, which is recorded with its resources and params even when the
run never moved a row:

```sql
SELECT pipeline, resources, params, error, finished_at
FROM NFL_DEV_DB.OPS._DLT_RUNS WHERE status = 'failed' ORDER BY finished_at DESC;
```

**A 400 usually means a parameter name.** The API names the offending parameter in the response body,
which is included in the error. Check it against the table at the top of this file.

**A green run with zero rows** means a filter matched nothing. The most likely cause is a
`season_type` that does not exist for that endpoint, or a season the API does not carry.
