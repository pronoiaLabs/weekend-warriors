# ml/

uv project for NFL models on `NFL_PROD_DB.FEATURES`. First model is
`NFL_GAME_TOTAL`: walk-forward 2023–24 / 2025 on `feat_game_matchup`,
logged to `NFL_PROD_DB.ML` with `pip_requirements` and
`target_platforms=["SNOWPARK_CONTAINER_SERVICES"]`, scored on `ML_DEV_POOL`.

Does not write `FEATURES` or `RAW`. Does not use conda. Does not hang a
scorer inside `SP_DBT_BUILD`. `close_*` is never in X.

```bash
cd ml
uv sync
uv run python -m weekend_warriors_ml inspect
uv run python -m weekend_warriors_ml fit
uv run python -m weekend_warriors_ml cook          # register + local preds + run_batch
uv run python -m weekend_warriors_ml cook --no-batch
```

Workspace notebook (Container Runtime / SPCS): `notebooks/nfl_game_total_v1.ipynb`.
SQL inspect plus the same fit / register / score path as `cook`. Keep the `ml/`
folder in the Workspace so `weekend_warriors_ml` imports. The first Python cell
is `!uv pip install scikit-learn snowflake-ml-python` — rerun it after a
notebook-service restart. Laptop still: `uv run python -m weekend_warriors_ml cook`.

Uses the `weekend-warriors` snow CLI connection (`connections.toml`).
Override with `SNOWFLAKE_CONNECTION_NAME`.

Greenfield (same globs a new clone runs):

```bash
make -C dlt-pipelines setup-dev CONFIRM=1          # ML_DEV_POOL
make -C dlt-pipelines setup-source SOURCE=nfl CONFIRM=1  # 01 schema + 06 stage
make -C dlt-pipelines setup-ops CONFIRM=1          # cost tag on the pool
```

`sql/**` is not in `deploy.yml` — CI will not create these. Re-apply with those
targets or `snow sql -f`.
