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
        "metadata": {
            "kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}
        },
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
            "## Install the ML libraries\n\n"
            "A model is just math that finds patterns in a table. We use two libraries:\n\n"
            "- **scikit-learn** — trains the model on your laptop-shaped Python process "
            "(the notebook kernel).\n"
            "- **snowflake-ml-python** — saves that trained model into Snowflake's Model "
            "Registry and can score it on a compute pool later.\n\n"
            "This cell installs them with `uv pip` against Snowflake's own PyPI mirror "
            "(not public pypi.org, not Anaconda). The base image often already has them, "
            "but a weekend service restart wipes extra installs, so run this first every "
            "session. The `print` lines confirm versions so a later error is not a mystery "
            "missing-package."
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
            "## Connect the notebook to Snowflake and load this model's recipe\n\n"
            "Two things happen here:\n\n"
            "1. **Find `weekend_warriors_ml`.** The training code lives in the repo's "
            "`ml/` folder, not inside this notebook. We walk up from the current "
            "directory until we see `weekend_warriors_ml/pipeline.py`, then put that "
            "folder on `sys.path` so `import` works. If this raises, the Workspace is "
            "missing the `ml/` folder from the git pull.\n"
            "2. **Open the kernel session.** `get_active_session()` is the Snowflake "
            "login this notebook already has. We do not type a password here.\n\n"
            f"`get_spec(\"{model_name}\")` loads the recipe: which table, which columns "
            "are X (inputs), which column is the label (the answer we want to predict), "
            "and whether this is regression (a number) or classification (a yes/no "
            "probability). Nothing is trained yet."
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
    close_md = ""
    if spec.comparator_column:
        close = (
            f",\n    COUNT(IFF({spec.comparator_column} IS NOT NULL, 1, NULL)) AS close_nonnull"
        )
        close_md = (
            f"- **`close_nonnull`** — rows that have a sportsbook line "
            f"(`{spec.comparator_column}`). That line is a **comparison after we predict**, "
            "never an input. Most historical seasons have no close, so this number is "
            "much smaller than `rows`.\n"
        )
    return [
        _md(
            "## Count the games we can actually learn from\n\n"
            "Before training, we look at the raw table. `FEAT_GAME_MATCHUP` is one row "
            "per NFL game on the slate (played and not-yet-played).\n\n"
            "Vocabulary for this cell:\n\n"
            "- **`rows`** — every game in the table (about 1,323).\n"
            "- **`eligible_rs_post`** — finished regular-season or postseason games. "
            "Preseason is excluded because it is a different sport, statistically.\n"
            f"- **`label_null`** — games with no `{spec.label_column}` yet (usually "
            "unplayed). We cannot train on those; we can still score them later.\n"
            f"{close_md}\n"
            "If `eligible_rs_post` is near zero, stop. There is nothing to fit."
        ),
        _code(
            "%%sql -r matchup_grain\n"
            "SELECT\n"
            "    COUNT(*) AS rows,\n"
            "    COUNT(IFF(is_completed AND season_type IN (2, 3), 1, NULL)) AS eligible_rs_post,\n"
            f"    COUNT(IFF({spec.label_column} IS NULL, 1, NULL)) AS label_null"
            f"{close}\n"
            "FROM NFL_PROD_DB.FEATURES.FEAT_GAME_MATCHUP"
        ),
        _md(
            "## Confirm each season has a full slate\n\n"
            "We train on **2023 and 2024**, then test on **2025**. That is a "
            "**walk-forward split**: time moves one direction, so the model never "
            "sees 2025 while it is learning. A random 80/20 shuffle would leak future "
            "games into training and make the score look better than it is.\n\n"
            "Expect about **285 completed RS+post games per season**. A missing season "
            "or a tiny count means FEATURES is stale — do not fit until this looks right."
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
    return [
        _md(
            "## Count the player-games we can actually learn from\n\n"
            "Player models sit on **one row per player per game**. Features come from "
            "`FEAT_PLAYER_GAME_ROLLING` (trailing rates) plus a few weather products. "
            f"The **answer** (`{spec.label_column}`) does **not** live on that rolling "
            "table — current-game yards would leak the thing we are trying to predict. "
            "Labels are joined later from `CORE.FACT_PLAYER_GAME_OFFENSE`.\n\n"
            f"The **gate** `{gate} > 0` means: this player actually did that thing in "
            "the trailing window. A receiver with zero recent targets is not a useful "
            "receiving-yards example. Week 1 of a season often fails the gate (no "
            "trailing games yet). That is correct, not a bug.\n\n"
            "- **`rows`** — every player-game stub, including unplayed slates.\n"
            "- **`completed_rs_post`** — finished regular-season / postseason rows.\n"
            "- **`gated`** — those rows that also pass the role gate. Training uses gated."
        ),
        _code(
            "%%sql -r player_grain\n"
            "SELECT\n"
            "    COUNT(*) AS rows,\n"
            "    COUNT(IFF(r.is_completed AND r.season_type IN (2, 3), 1, NULL)) AS completed_rs_post,\n"
            f"    COUNT(IFF(r.is_completed AND r.season_type IN (2, 3) AND r.{gate} > 0, 1, NULL)) AS gated\n"
            "FROM NFL_PROD_DB.FEATURES.FEAT_PLAYER_GAME_ROLLING r"
        ),
        _md(
            "## Confirm each season has gated player-games\n\n"
            "Same walk-forward idea as the game models: **train 2023–24, test 2025**. "
            f"This count is players who passed `{gate} > 0`, not every roster name. "
            "A collapsed 2025 bar means the holdout is empty and `fit` will error."
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


def _inspect_md(spec: ModelSpec) -> str:
    extra = ""
    if spec.comparator_column:
        extra = (
            f" `close_nonnull` is how many rows have `{spec.comparator_column}` — "
            "again, a market line we compare later, not a feature.\n"
        )
    return (
        "## Same counts, through the Python pipeline\n\n"
        "`inspect` runs the **same filters the trainer will use**, then prints a JSON "
        "summary. Read it as a sanity check before you spend time fitting:\n\n"
        "- **`rows`** — pulled into pandas.\n"
        "- **`eligible_rs_post`** — completed RS+post with a label"
        + (f" and `{spec.min_feature} > 0`" if spec.min_feature else "")
        + ".\n"
        "- **`by_season`** — must include 2023, 2024, and 2025.\n"
        f"- **`n_features`** — width of X. None of those names start with `close_` or "
        f"`label_`.\n"
        f"{extra}\n"
        "If this disagrees with the SQL cells above, stop and look at the join — "
        "do not fit a broken frame."
    )


def _fit_md(spec: ModelSpec) -> str:
    if spec.task == "classification":
        return (
            "## Train the model, then grade it on 2025\n\n"
            f"This is **classification**: the label `{spec.label_column}` is 1 if the "
            "player scored a rushing or receiving TD, else 0. The model outputs a "
            f"**probability** (`{spec.pred_column}`), not a yes/no.\n\n"
            "**HistGradientBoostingClassifier** is a tree ensemble. It splits the "
            "feature space into regions (\"if trailing TD rate is high and they are "
            "home…\") and averages many small trees. We are not tuning it yet — "
            "fixed depth 6, 200 iterations, so v1 is comparable across models.\n\n"
            "What the printed metrics mean:\n\n"
            "- **`log_loss` / `brier`** — how wrong the probabilities were. Lower is "
            "better. `brier` is mean squared error of the probability vs 0/1.\n"
            "- **`roc_auc`** — 0.5 is a coin flip, 1.0 is perfect ranking. Useful even "
            "when TDs are rare.\n"
            "- **`accuracy`** — share of games where (probability ≥ 0.5) matches the "
            "label. Easy to misread when most players do not score.\n"
            "- **`*_rate_baseline`** — \"always predict the training TD rate.\" If we "
            "cannot beat that, the features are not helping yet.\n\n"
            "`n_train` / `n_test` should look like 2023–24 vs 2025 gated rows."
        )
    close_line = ""
    if spec.comparator_column:
        close_line = (
            f" After scoring we will also compare predictions to `{spec.comparator_column}` "
            "(the close). That is a market check, not part of training.\n"
        )
    return (
        "## Train the model, then grade it on 2025\n\n"
        f"This is **regression**: we predict a number (`{spec.label_column}`). "
        "**X** is the feature columns (rest, weather, trailing rates). **y** is the "
        "label. The model never sees `close_*` or `label_*` in X.\n\n"
        "**HistGradientBoostingRegressor** is a tree ensemble: many small decision "
        "trees, each correcting the last. Depth 6 and 200 iterations are fixed for "
        "v1 so every notebook is comparable. We are not searching hyperparameters "
        "here.\n\n"
        "What the printed metrics mean (all on **2025 only**, the holdout):\n\n"
        "- **`mae`** — mean absolute error. \"On average we were off by this many "
        "units\" (points, yards, …).\n"
        "- **`rmse`** — same idea, but big misses hurt more.\n"
        "- **`mae_mean_baseline`** — error if we predicted the **training-set average** "
        "every time. If `mae` is not better than this, the model is not yet beating "
        "\"guess the mean.\" That is information, not a failure of the notebook.\n"
        f"{close_line}\n"
        "The function returns `(model, metrics)`. `model` is the fitted object we "
        "register and score next."
    )


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


def _walkforward_md(spec: ModelSpec) -> str:
    if spec.task == "classification":
        return (
            "## Grade 2025 from the pred table\n\n"
            "Same holdout, read back from Snowflake so you are not trusting only the "
            "in-memory printout.\n\n"
            "- **`brier`** — should match `fit`'s Brier (small rounding differences are "
            "fine).\n"
            "- **`accuracy`** — threshold 0.5. Remember the class is imbalanced; a high "
            "accuracy can still be a model that almost never predicts a TD.\n\n"
            "If this is empty, `score_local` did not write 2025 labeled rows."
        )
    return (
        "## Grade 2025 from the pred table\n\n"
        "This is the number you quote: **how far off were we on games the model "
        "had never seen?**\n\n"
        "- **`mae`** — should be close to `fit`'s printed MAE.\n"
        "- **`mse`** — mean squared error (RMSE is the square root of this).\n\n"
        "We filter to 2025 regular season + postseason with a known label. Unplayed "
        "2026 rows are excluded here on purpose — there is no truth to compare."
    )


def _pred_summary_sql(spec: ModelSpec) -> str:
    close = (
        f"    COUNT({spec.comparator_column}) AS with_close,\n" if spec.comparator_column else ""
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


def _pred_summary_md(spec: ModelSpec) -> str:
    close = ""
    if spec.comparator_column:
        close = (
            f"- **`with_close`** — rows that also have `{spec.comparator_column}`. "
            "Mostly 2026 unplayed games today. Useful for \"how close are we to the "
            "board,\" not for walk-forward MAE.\n"
        )
    return (
        "## Did the pred table land?\n\n"
        f"`NFL_PROD_DB.ML.{spec.pred_table}` should now exist (created on first write).\n\n"
        "- **`rows`** — full slate we scored, including unplayed.\n"
        "- **`labeled`** — rows where we know the answer (completed games).\n"
        f"{close}"
        "- **`version_name`** — the registry version this write came from.\n\n"
        "A zero-row table means `write_pandas` did not run or pointed at another schema."
    )


def _intro(spec: ModelSpec) -> str:
    task = (
        "a **probability** that the player scores a rushing or receiving TD"
        if spec.task == "classification"
        else f"a **number**: `{spec.label_column}`"
    )
    family = (
        "one row per game from `FEAT_GAME_MATCHUP`"
        if spec.family == "game"
        else (
            "one row per player-game. Inputs come from rolling rates + weather "
            "products; the label is joined from the CORE box score so we never "
            "train on the current game's yards"
        )
    )
    return (
        f"# {spec.name}\n\n"
        f"{spec.comment}\n\n"
        "This notebook is the full v1 loop: look at the data, **train** a model, "
        "**save** it in Snowflake, **predict** every row, then **measure** how "
        "wrong we were on 2025. Run cells in order. If you only want the whole "
        "loop in one shot, skip to `cook` at the bottom — but the first time, "
        "walk through.\n\n"
        f"**What we predict:** {task}.\n"
        f"**Grain:** {family}.\n"
        f"**Split:** train on 2023–24 regular season + playoffs; test on 2025. "
        "That is walk-forward (time order), not a random shuffle.\n\n"
        "**Words you will see:**\n\n"
        "- **X / features** — columns the model is allowed to use. Never `close_*` "
        "(betting lines) and never `label_*` (the answer).\n"
        "- **y / label** — the answer for completed games. Null on unplayed games.\n"
        "- **Fit** — learn patterns from 2023–24.\n"
        "- **Score** — write a prediction for every row, including next week's slate.\n"
        "- **Register** — store the fitted model in `NFL_PROD_DB.ML` so Snowflake "
        "can run it later.\n\n"
        "Keep the repo `ml/` folder in this Workspace. Run the install cell after "
        "a service restart. Do not promote a version just because it exists. Do "
        "not add FEATURES or ML tables to the Cortex agents."
    )


def model_notebook(spec: ModelSpec) -> list[dict]:
    sql_cells = _game_sql(spec) if spec.family == "game" else _player_sql(spec)
    return [
        _md(_intro(spec)),
        *_install_cells(),
        *sql_cells,
        *_import_cells(spec.name),
        _md(_inspect_md(spec)),
        _code("inspect(session, SPEC.name)"),
        _md(_fit_md(spec)),
        _code("model, metrics = fit(session, SPEC.name)\nmetrics"),
        _md(
            "## Save the run and register the model in Snowflake\n\n"
            "Two writes, one cell:\n\n"
            "1. **`log_experiment`** — stores the hyperparameters and the 2025 metrics "
            "on an experiment named after this model. If tracking is unavailable, we "
            "print the error and continue. Metrics still exist in the cell output.\n"
            "2. **`register` / `log_model`** — uploads the fitted sklearn object to "
            f"`NFL_PROD_DB.ML.{spec.name}`. Snowflake mints a `version_name` "
            "(often a random animal). We pin `pip_requirements=[\"scikit-learn\"]` and "
            "`target_platforms` to Snowpark Container Services so this cannot silently "
            "become a warehouse Python UDF.\n\n"
            "Copy `version_name`. The next cells need it. Registering is **not** "
            "promoting — nobody should treat this as production because the object exists."
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
        _md(
            "## Confirm the model object exists\n\n"
            f"`SHOW MODELS` lists registry entries. You should see `{spec.name}`. "
            "Aliases like default / first / last are Snowflake bookkeeping. This is "
            "only a listing — it does not mean the model is good."
        ),
        _code(
            "%%sql -r models\n"
            f"SHOW MODELS LIKE '{spec.name}' IN SCHEMA NFL_PROD_DB.ML"
        ),
        _md(
            "## Confirm Snowflake exposed a predict function\n\n"
            "A registered model publishes functions (usually `PREDICT`). The "
            "`{{version_name}}` token is this notebook's interpolation of the Python "
            "variable from the cell above — run that cell first. Empty output means "
            "the version string did not bind."
        ),
        _code(
            "%%sql -r model_fns\n"
            f"SHOW FUNCTIONS IN MODEL NFL_PROD_DB.ML.{spec.name} VERSION {{{{version_name}}}}"
        ),
        _md(
            "## Predict every row and write the pred table\n\n"
            "Scoring is \"run the fitted model on X for the **full slate**.\" "
            "Completed games get a prediction **and** a label so we can measure error. "
            "Unplayed games get a prediction and a null label — that is next week's "
            f"number.\n\n"
            f"Writes `NFL_PROD_DB.ML.{spec.pred_table}` (create-or-replace). "
            f"The prediction column is `{spec.pred_column}`"
            + (
                " (a probability between 0 and 1)."
                if spec.task == "classification"
                else " (same units as the label)."
            )
            + " `preds.head(5)` is a peek, not the evaluation."
        ),
        _code("preds = score_local(session, model, version_name, SPEC.name)\npreds.head(5)"),
        _md(_pred_summary_md(spec)),
        _code(_pred_summary_sql(spec)),
        _md(_walkforward_md(spec)),
        _code(_walkforward_sql(spec)),
        _md(
            "## Optional: score again on the ML compute pool\n\n"
            "Everything above used the **notebook kernel**. `score_batch` asks Snowflake "
            "to run the **registered** version on `ML_DEV_POOL` (`CPU_X64_S`, not "
            "`DLT_POOL`) and drop files on the inference stage. Use this to prove the "
            "registry object works in a container. Skip it if you only needed the pred "
            "table — it takes several minutes and starts a pool node.\n\n"
            "This is not required to finish v1."
        ),
        _code("score_batch(session, version_name, SPEC.name)"),
        _md(
            "## One-cell path (same pipeline, no pool)\n\n"
            "`cook` is inspect → fit → log experiment → register → `score_local`. "
            "It does **not** call `score_batch`. Use this when an agent is driving the "
            "notebook and you already understand the steps above. Running both the "
            "step-by-step cells **and** `cook` will train twice and overwrite the pred "
            "table — pick one path per session."
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
            "Each notebook in `ml/notebooks/v1/` is one model. They all share the same "
            "pipeline: look at FEATURES, train on 2023–24, test on 2025, register in "
            "`NFL_PROD_DB.ML`, write a pred table.\n\n"
            "**Regression** predicts a number (points, yards, receptions). "
            "**Classification** (anytime TD only) predicts a probability.\n\n"
            "Do not promote a version because it exists. Do not add FEATURES or ML to "
            "the Cortex agents. Do not loop all 14 cooks in one cell on the first pass.\n\n"
            "| Model | Family | Task | Label | Notebook |\n"
            "|---|---|---|---|---|\n"
            f"{rows}\n\n"
            "Deferred: first TD (needs play-level order), CLV vs close (2023–25 closes "
            "missing), `feat_player_prop_train` as a later FEATURES grain."
        ),
        *_install_cells(),
        *_import_cells("NFL_GAME_TOTAL"),
        _md(
            "## List every v1 recipe\n\n"
            "`SPECS` is the registry in Python: name, family, task, label column, "
            "and which notebook owns it. This cell does not train anything. Skim it "
            "to see the fleet before you open a per-model notebook."
        ),
        _code(
            "from weekend_warriors_ml.specs import SPECS\n"
            "\n"
            "for name, spec in SPECS.items():\n"
            '    print(name, spec.family, spec.task, spec.label_column, spec.notebook)'
        ),
        _md(
            "## Cook one model end to end\n\n"
            "`cook` runs inspect → fit → register → write the pred table. Change "
            "`MODEL` to any name from the table above. Start with `NFL_GAME_TOTAL` "
            "(already registered once) or a new game model.\n\n"
            "This can take several minutes and **overwrites** that model's pred table. "
            "Do not put a `for` loop over all 14 names until you have watched one "
            "succeed. Skip `score_batch` unless you meant to start `ML_DEV_POOL`."
        ),
        _code('MODEL = "NFL_GAME_TOTAL"\n' "cook(session, MODEL)"),
    ]


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    _write("00_nfl_models.ipynb", index_notebook())
    for spec in SPECS.values():
        _write(spec.notebook, model_notebook(spec))


if __name__ == "__main__":
    main()
