# snowpark/

Python stored procedures that dbt calls from hooks. One uv project for the
tooling (ruff, pytest), one `snow snowpark` project per procedure.

```
snowpark/
  pyproject.toml              ruff + pytest; snowflake-snowpark-python for the import check
  player_bridge/
    snowflake.yml             the CREATE PROCEDURE, as data: handler, signature, stage, runtime
    requirements.txt          what the procedure declares in PACKAGES
    src/player_bridge/        zipped onto @DLT_DB.DEPLOY.SNOWPARK by snow snowpark build/deploy
      main.py                 handler run(session, target_db, target_schema, full_refresh)
      evidence.py             pure: team map, position groups, name normalization, hashes
      expressions.py          the same rules as Snowpark columns (generated from evidence.py)
      frames.py               the vendor frame (BDL + Sleeper) and the index frame (nflverse)
      tiers.py                deterministic tiers: id, exact, tiebreak
      search.py               one CORTEX_SEARCH_BATCH job over every pending row
      confirm.py              AI_FILTER(PROMPT(...)) over the residual's candidates
      tables.py               PLAYER_BRIDGE / PLAYER_BRIDGE_UNMATCHED DDL, MERGEs, the pending query
    tests/test_evidence.py    the only unit tests: pure Python, run in CI
```

```bash
make -C dbt-pipelines snowpark-test       # ruff + pytest
make -C dbt-pipelines deploy-snowpark     # build, upload, CREATE OR REPLACE, re-grant
```

## SP_PLAYER_BRIDGE

Interactive walkthrough of the design (funnel, tiers, name gate):
[docs/player-bridge.html](docs/player-bridge.html).

`DLT_DB.DEPLOY.SP_PLAYER_BRIDGE(target_db, target_schema, full_refresh)` maps
BallDontLie and Sleeper player ids onto nflverse `gsis_id` and writes two tables
into `target_db.target_schema`:

| table | grain | what |
|---|---|---|
| `PLAYER_BRIDGE` | vendor x vendor_player_id | `gsis_id`, `match_method` (`id`, `exact`, `tiebreak`, `search_ai`), `match_score`, the search's top hit and whether it agreed, the evidence hash, `decided_at` |
| `PLAYER_BRIDGE_UNMATCHED` | vendor x vendor_player_id | the evidence that failed (VARIANT), the candidates with both verdicts (VARIANT), `reason` (`no_candidates`, `ai_rejected`, `name_rejected`, `ambiguous`), `last_tried_at` |

One call:

1. Pending = vendor players with no bridge row and no unmatched row carrying
   today's evidence hash. **None pending: return.** No search job, no AI call.
2. Deterministic tiers over the pending rows, best tier wins, and a tier that
   offers two candidates offers none (ambiguity falls through to step 4).
3. One batch search over every pending row, filtered per row to the same team
   or the same position group, top 5. The top hit is stored beside every
   deterministic decision as an audit (`search_agrees`); it never overrides one.
4. Residual rows: each candidate is put to `AI_FILTER` with both records
   rendered as "name, position, team, #jersey, college, born YYYY", and to a
   name gate (same normalized surname, prefix-compatible first names: Pat and
   Patrick pass, Rashod and Tinker do not). A candidate counts only when both
   say yes. Exactly one yes decides the row; zero or several send it to the
   ledger with both verdicts per candidate. The gate exists because the first
   full refresh showed the model alone accepting same-surname strangers.
5. MERGE both tables; return a JSON summary (`new`, `bridged`, `by_method`,
   `by_reason`, `search_disagrees`, `search_queries`, `ai_pairs`).

Why the shape is what it is:

- **Stable ids only.** Team, jersey, position and college are evidence at match
  time, never columns of the bridge, so a trade or a number change touches
  nothing. The ledger's hash is over exactly those fields, so the same change on
  an unmatched player is what earns him a retry.
- **Batch, not interactive, search.** The call is set-based inside a procedure,
  and batch mode runs against a suspended service, so the service sleeps
  between the weekly players refreshes. It is written as SQL (`LATERAL
  CORTEX_SEARCH_BATCH(...)`) rather than `join_table_function`: the documented
  form, and the output columns are whatever the service indexes.
- **Everything is cached.** Snowpark is lazy; without `cache_result()` a frame
  used twice would run the search job or the prompts twice.
- **Caller's rights.** Dev callers write under their own role into their dev
  schema; the prod trigger task writes as `DBT_RUNNER_ROLE` into `CORE`. The
  procedure holds no credentials and reads only `NFL_PROD_DB.RAW`.

What the unit tests pin: the vendor team codes all map into nflverse's set, every
position code any vendor emits has a group, the groups are disjoint, the name
normalization matches the dbt macro, and the hash is order- and case-stable.
Everything session-bound is proven against the account by hand:

```sql
CALL DLT_DB.DEPLOY.SP_PLAYER_BRIDGE('NFL_DEV_DB', 'DEV_<USER>', TRUE);   -- full, reports rates
CALL DLT_DB.DEPLOY.SP_PLAYER_BRIDGE('NFL_DEV_DB', 'DEV_<USER>', FALSE);  -- {"new": 0}
SELECT reason, count(*) FROM NFL_DEV_DB.DEV_<USER>.PLAYER_BRIDGE_UNMATCHED GROUP BY 1;
```

Account objects it needs (stage, grants, the search service) are created by
`dlt-pipelines/sql/sources/nfl/09_player_bridge.sql`, applied with
`make -C dlt-pipelines setup-source SOURCE=nfl CONFIRM=1`. Three vocabularies are
mirrored and must move together: `TO_NFLVERSE_TEAM` and `POSITION_GROUPS` here,
`nfl_team_abbr_nflverse` and `nfl_position_group` in
`macros/nfl/nfl_bridge_helpers.sql`, and the `POS_GROUP` case in the 09 file.

## Adding a procedure

Copy `player_bridge/` as `snowpark/<name>/`, rename the entity and handler in
`snowflake.yml`, add the deploy line and re-grants to `make deploy-snowpark`,
add the procedure to the `deploy.yml` assertion, and call it from a model's
hook with the model's own `{{ this.database }}` / `{{ this.schema }}`.
