# ml/

uv project for NFL models on `NFL_PROD_DB.FEATURES`. Specs live in
`weekend_warriors_ml/specs.py`. Each dedicated model has a Workspace notebook
under `notebooks/v1/`. Fit and register in the Workspace — do not cook from the
laptop.

X is FEATURES only. `close_*` is never in X. `label_*` is the target only.
Player labels come from `NFL_PROD_DB.CORE.FACT_PLAYER_GAME_OFFENSE` (joined at
train time); rolling tables stay leak-free. Classification is anytime TD;
everything else is regression. Registry: `NFL_PROD_DB.ML` with
`pip_requirements` and `target_platforms=["SNOWPARK_CONTAINER_SERVICES"]`.
Score pool is `ML_DEV_POOL`, not `DLT_POOL`. Does not write `FEATURES` or `RAW`.
Does not hang a scorer inside `SP_DBT_BUILD`.

```bash
cd ml
uv sync
uv run python -m weekend_warriors_ml list
uv run python -m weekend_warriors_ml inspect NFL_GAME_HOME_POINTS
# Fit in the Workspace notebook, not here.
```

Workspace (Container Runtime / SPCS): start at `notebooks/v1/00_nfl_models.ipynb`,
then open the per-model notebook. Keep the `ml/` folder in the Workspace so
`weekend_warriors_ml` imports. First Python cell is
`!uv pip install scikit-learn snowflake-ml-python` — rerun it after a
notebook-service restart.

Laptop CLI still exists for inspect. `cook` writes the registry + pred table;
`--batch` also fires `run_batch` on `ML_DEV_POOL`.

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
