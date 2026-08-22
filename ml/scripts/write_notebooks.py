"""Emit Workspace notebooks from specs. Run from ml/: python scripts/write_notebooks.py"""

from __future__ import annotations

import json
import uuid
from pathlib import Path

from weekend_warriors_ml.specs import SPECS, ModelSpec

ROOT = Path(__file__).resolve().parents[1] / "notebooks" / "v1"


def _id() -> str:
    return uuid.uuid4().hex[:8]


def _md(text: str) -> dict:
    return {"cell_type": "markdown", "id": _id(), "metadata": {}, "source": _lines(text)}


def _code(text: str) -> dict:
    return {
        "cell_type": "code",
        "execution_count": None,
        "id": _id(),
        "metadata": {},
        "outputs": [],
        "source": _lines(text),
    }


def _lines(text: str) -> list[str]:
    body = text.strip("\n")
    if not body:
        return [""]
    parts = body.split("\n")
    return [p + "\n" for p in parts[:-1]] + [parts[-1]]


def _nb(cells: list[dict]) -> dict:
    return {
        "cells": cells,
        "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}},
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def _write(name: str, cells: list[dict]) -> None:
    path = ROOT / name
    path.write_text(json.dumps(_nb(cells), indent=2) + "\n")
    print(path.name)


def _install_cells() -> list[dict]:
    return [
        _md(
            "## Packages\n\n"
            "`uv pip` against the Snowflake-managed PyPI artifact repo (no Anaconda).\n"
            "Rerun this after a notebook-service restart. If it cannot reach a repo, attach\n"
            "the Snowflake PyPI artifact repository on the notebook service — do not point\n"
            "this at public pypi.org."
        ),
        _code(
            "!uv pip install scikit-learn snowflake-ml-python\n"
            "\n"
            "import importlib.metadata as md\n"
            "\n"
            'print("sklearn", md.version("scikit-learn"))\n'
            'print("snowflake-ml-python", md.version("snowflake-ml-python"))'
        ),
    ]


def _import_cells(model_name: str) -> list[dict]:
    return [
        _md(
            "## Session and import\n\n"
            "Kernel session via `get_active_session()`. Add `ml/` to `sys.path` so this\n"
            "notebook can import the same module the laptop `uv run` uses."
        ),
        _code(
            "from pathlib import Path\n"
            "import sys\n"
            "\n"
            "here = Path.cwd().resolve()\n"
            "for cand in (here, *here.parents):\n"
            '    if (cand / "weekend_warriors_ml" / "pipeline.py").exists():\n'
            "        if str(cand) not in sys.path:\n"
            "            sys.path.insert(0, str(cand))\n"
            "        break\n"
            "else:\n"
            "    raise FileNotFoundError(\n"
            '        "weekend_warriors_ml not found. Put the repo ml/ folder in this Workspace."\n'
            "    )\n"
            "\n"
            "from snowflake.snowpark.context import get_active_session\n"
            "from weekend_warriors_ml.specs import get_spec\n"
            "from weekend_warriors_ml.pipeline import (\n"
            "    cook,\n"
            "    fit,\n"
            "    inspect,\n"
            "    log_experiment,\n"
            "    register,\n"
            "    score_batch,\n"
            "    score_local,\n"
            ")\n"
            "\n"
            f'SPEC = get_spec("{model_name}")\n'
            "session = get_active_session()\n"
            'print(SPEC.name, SPEC.task, len(SPEC.feature_columns), "features")\n'
            "print(session.get_current_role(), session.get_current_warehouse())"
        ),
    ]


def _game_sql(spec: ModelSpec) -> list[dict]:
    close = ""
    if spec.comparator_column:
        close = (
            f",\n    COUNT(IFF({spec.comparator_column} IS NOT NULL, 1, NULL)) AS close_nonnull"
        )
    grain = (
        "## FEATURES grain\n\n"
        "Expect 1,323 games. Eligible RS+post completed should be 285 per season 2023–25."
    )
    return [
        _md(grain),
        _code(
            "%%sql -r matchup_grain\n"
            "SELECT\n"
            "    COUNT(*) AS rows,\n"
            "    COUNT(IFF(is_completed AND season_type IN (2, 3), 1, NULL)) AS eligible_rs_post,\n"
            f"    COUNT(IFF({spec.label_column} IS NULL, 1, NULL)) AS label_null"
            f"{close}\n"
            "FROM NFL_PROD_DB.FEATURES.FEAT_GAME_MATCHUP"
        ),
        _code(
            "%%sql -r eligible_by_season\n"
            "SELECT season, COUNT(*) AS n\n"
            "FROM NFL_PROD_DB.FEATURES.FEAT_GAME_MATCHUP\n"
            f"WHERE is_completed AND season_type IN (2, 3) AND {spec.label_column} IS NOT NULL\n"
            "GROUP BY 1\n"
            "ORDER BY 1"
        ),
    ]


def _player_sql(spec: ModelSpec) -> list[dict]:
    gate = spec.min_feature or "n_games_played_l5"
    grain = (
        "## FEATURES grain\n\n"
        "Player x game from `FEAT_PLAYER_GAME_ROLLING` + `FEAT_PLAYER_WEATHER`.\n"
        f"Train gate: `{gate} > 0`. Labels come from CORE box scores, not the rolling table."
    )
    return [
        _md(grain),
        _code(
            "%%sql -r player_grain\n"
            "SELECT\n"
            "    COUNT(*) AS rows,\n"
            "    COUNT(IFF(r.is_completed AND r.season_type IN (2, 3), 1, NULL)) AS completed_rs_post,\n"
            f"    COUNT(IFF(r.is_completed AND r.season_type IN (2, 3) AND r.{gate} > 0, 1, NULL)) AS gated\n"
            "FROM NFL_PROD_DB.FEATURES.FEAT_PLAYER_GAME_ROLLING r"
        ),
        _code(
            "%%sql -r eligible_by_season\n"
            "SELECT r.season, COUNT(*) AS n\n"
            "FROM NFL_PROD_DB.FEATURES.FEAT_PLAYER_GAME_ROLLING r\n"
            "WHERE r.is_completed AND r.season_type IN (2, 3)\n"
            f"  AND r.{gate} > 0\n"
            "GROUP BY 1\n"
            "ORDER BY 1"
        ),
    ]


def _walkforward_sql(spec: ModelSpec) -> str:
    pred = spec.pred_column
    label = spec.label_column
    table = spec.pred_table
    if spec.task == "classification":
        return (
            "%%sql -r walkforward\n"
            "SELECT\n"
            "    COUNT(*) AS n_2025_rs_post,\n"
            f"    ROUND(AVG(POW({pred} - {label}, 2)), 3) AS brier,\n"
            f"    ROUND(AVG(IFF(IFF({pred} >= 0.5, 1, 0) = {label}, 1, 0)), 3) AS accuracy\n"
            f"FROM NFL_PROD_DB.ML.{table}\n"
            "WHERE season = 2025\n"
            "  AND season_type IN (2, 3)\n"
            f"  AND {label} IS NOT NULL"
        )
    return (
        "%%sql -r walkforward\n"
        "SELECT\n"
        "    COUNT(*) AS n_2025_rs_post,\n"
        f"    ROUND(AVG(ABS({pred} - {label})), 3) AS mae,\n"
        f"    ROUND(AVG(POW({pred} - {label}, 2)), 3) AS mse\n"
        f"FROM NFL_PROD_DB.ML.{table}\n"
        "WHERE season = 2025\n"
        "  AND season_type IN (2, 3)\n"
        f"  AND {label} IS NOT NULL"
    )


def _pred_summary_sql(spec: ModelSpec) -> str:
    close = (
        f"    COUNT({spec.comparator_column}) AS with_close,\n"
        if spec.comparator_column
        else ""
    )
    return (
        "%%sql -r pred_summary\n"
        "SELECT\n"
        "    COUNT(*) AS rows,\n"
        f"    COUNT({spec.label_column}) AS labeled,\n"
        f"{close}"
        "    MIN(scored_at) AS scored_at,\n"
        "    MIN(version_name) AS version_name\n"
        f"FROM NFL_PROD_DB.ML.{spec.pred_table}"
    )


def model_notebook(spec: ModelSpec) -> list[dict]:
    task_line = (
        "HistGradientBoostingClassifier; `pred_*` is P(anytime TD)."
        if spec.task == "classification"
        else "HistGradientBoostingRegressor. Prints error vs a mean baseline."
    )
    sql_cells = _game_sql(spec) if spec.family == "game" else _player_sql(spec)
    return [
        _md(
            f"# {spec.name}\n\n"
            "Workspace notebook on Container Runtime (SPCS). Same contract as `ml/`:\n"
            f"`{spec.label_column}` only, train 2023–24 RS+post, walk-forward 2025, no `close_*` in X,\n"
            "`log_model` to `NFL_PROD_DB.ML` with `pip_requirements` and SPCS only.\n\n"
            f"{spec.comment}\n\n"
            "SQL cells inspect. Python cells fit, register, and score via `weekend_warriors_ml`.\n"
            "Keep that package in this Workspace (the `ml/` folder from the repo).\n\n"
            "Run the install cell first. Extra `uv pip` installs do not survive weekend service restarts.\n"
            "One-cell path at the bottom: `cook(session, SPEC.name)`."
        ),
        *_install_cells(),
        *sql_cells,
        *_import_cells(spec.name),
        _code("inspect(session, SPEC.name)"),
        _md(f"## Fit\n\n{task_line}"),
        _code("model, metrics = fit(session, SPEC.name)\nmetrics"),
        _md(
            "## Register\n\n"
            "Logs the experiment (best-effort), then `log_model` to `NFL_PROD_DB.ML` for SPCS.\n"
            "`version_name` is whatever `log_model` auto-generates."
        ),
        _code(
            "try:\n"
            "    log_experiment(session, metrics, SPEC.name)\n"
            "except Exception as exc:\n"
            '    print("Experiment tracking skipped:", exc)\n'
            "\n"
            "version_name = register(session, model, SPEC.name)\n"
            "version_name"
        ),
        _code(
            "%%sql -r models\n"
            f"SHOW MODELS LIKE '{spec.name}' IN SCHEMA NFL_PROD_DB.ML"
        ),
        _code(
            "%%sql -r model_fns\n"
            f"SHOW FUNCTIONS IN MODEL NFL_PROD_DB.ML.{spec.name} VERSION {{{{version_name}}}}"
        ),
        _md(
            f"## Score\n\n"
            f"Writes `NFL_PROD_DB.ML.{spec.pred_table}` from the in-kernel model (full slate)."
        ),
        _code("preds = score_local(session, model, version_name, SPEC.name)\npreds.head(5)"),
        _code(_pred_summary_sql(spec)),
        _code(_walkforward_sql(spec)),
        _md(
            "## Optional: `run_batch` on ML_DEV_POOL\n\n"
            "Skip if you only needed the pred table. Pool is `CPU_X64_S`, not `DLT_POOL`."
        ),
        _code("score_batch(session, version_name, SPEC.name)"),
        _md(
            "## One cell\n\n"
            "Same as inspect + fit + register + score_local. Does not fire the pool.\n"
            "Use this if an agent is driving the notebook end to end."
        ),
        _code("cook(session, SPEC.name)"),
    ]


def index_notebook() -> list[dict]:
    rows = "\n".join(
        f"| `{s.name}` | {s.family} | {s.task} | `{s.label_column}` | `{s.notebook}` |"
        for s in SPECS.values()
    )
    return [
        _md(
            "# NFL dedicated models (v1)\n\n"
            "These notebooks live in `ml/notebooks/v1/`. Each one is the same pipeline: inspect FEATURES,\n"
            "walk-forward 2023–24 / 2025, register on `NFL_PROD_DB.ML`, write a pred table.\n"
            "Do not promote a version because it exists. Do not add FEATURES or ML to agents.\n\n"
            "| Model | Family | Task | Label | Notebook |\n"
            "|---|---|---|---|---|\n"
            f"{rows}\n\n"
            "Deferred: first TD (needs play-level order), CLV vs close (2023–25 closes missing),\n"
            "`feat_player_prop_train` as a later FEATURES grain."
        ),
        *_install_cells(),
        *_import_cells("NFL_GAME_TOTAL"),
        _code(
            "from weekend_warriors_ml.specs import SPECS\n"
            "\n"
            "for name, spec in SPECS.items():\n"
            '    print(name, spec.family, spec.task, spec.label_column, spec.notebook)'
        ),
        _md(
            "## Cook one model\n\n"
            "Change the name, then run. Do not loop all 14 in one cell on the first pass."
        ),
        _code(
            'MODEL = "NFL_GAME_TOTAL"\n'
            "cook(session, MODEL)"
        ),
    ]


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    _write("00_nfl_models.ipynb", index_notebook())
    for spec in SPECS.values():
        _write(spec.notebook, model_notebook(spec))


if __name__ == "__main__":
    main()
