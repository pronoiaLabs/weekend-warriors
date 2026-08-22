"""Walk-forward game-total fit, registry log, local score, optional run_batch."""

from __future__ import annotations

import json
from datetime import datetime, timezone

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import mean_absolute_error, root_mean_squared_error
from snowflake.snowpark import Session

from weekend_warriors_ml.features import (
    COMPARATOR_COLUMN,
    COMPUTE_POOL,
    ELIGIBLE_SEASON_TYPES,
    FEATURE_COLUMNS,
    ID_COLUMNS,
    INFERENCE_STAGE,
    LABEL_COLUMN,
    MATCHUP_TABLE,
    MODEL_NAME,
    PRED_TABLE,
    REGISTRY_DB,
    REGISTRY_SCHEMA,
    TEST_SEASON,
    TRAIN_SEASONS,
    assert_feature_contract,
)


def _lower_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out.columns = [c.lower() for c in out.columns]
    return out


def _to_numeric_features(df: pd.DataFrame) -> pd.DataFrame:
    x = df.loc[:, list(FEATURE_COLUMNS)].copy()
    for col in x.columns:
        if x[col].dtype == bool or str(x[col].dtype) == "boolean":
            x[col] = x[col].astype("float64")
        elif not pd.api.types.is_numeric_dtype(x[col]):
            x[col] = pd.to_numeric(x[col], errors="coerce")
    return x


def load_matchup(session: Session) -> pd.DataFrame:
    needed = list(
        dict.fromkeys(
            [
                *ID_COLUMNS,
                *FEATURE_COLUMNS,
                LABEL_COLUMN,
                COMPARATOR_COLUMN,
            ]
        )
    )
    quoted = ", ".join(needed)
    pdf = session.sql(f"SELECT {quoted} FROM {MATCHUP_TABLE}").to_pandas()
    return _lower_columns(pdf)


def eligible(df: pd.DataFrame) -> pd.DataFrame:
    return df[
        df["season_type"].isin(ELIGIBLE_SEASON_TYPES)
        & df["is_completed"].astype(bool)
        & df[LABEL_COLUMN].notna()
    ].copy()


def inspect(session: Session) -> dict[str, object]:
    df = load_matchup(session)
    elig = eligible(df)
    summary = {
        "rows": int(len(df)),
        "eligible_rs_post": int(len(elig)),
        "by_season": elig.groupby("season").size().to_dict(),
        "label_null": int(df[LABEL_COLUMN].isna().sum()),
        "close_nonnull": int(df[COMPARATOR_COLUMN].notna().sum()),
        "n_features": len(FEATURE_COLUMNS),
    }
    print(json.dumps(summary, indent=2, default=str))
    return summary


def _split(elig: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    train = elig[elig["season"].isin(TRAIN_SEASONS)]
    test = elig[elig["season"] == TEST_SEASON]
    if train.empty or test.empty:
        raise RuntimeError(
            f"Empty split: train={len(train)} seasons={TRAIN_SEASONS} "
            f"test={len(test)} season={TEST_SEASON}"
        )
    return train, test


def fit(session: Session) -> tuple[HistGradientBoostingRegressor, dict[str, float]]:
    assert_feature_contract()
    train, test = _split(eligible(load_matchup(session)))
    x_train = _to_numeric_features(train)
    x_test = _to_numeric_features(test)
    y_train = train[LABEL_COLUMN].astype("float64")
    y_test = test[LABEL_COLUMN].astype("float64")

    model = HistGradientBoostingRegressor(
        max_depth=6,
        learning_rate=0.05,
        max_iter=200,
        random_state=42,
    )
    model.fit(x_train, y_train)

    pred = model.predict(x_test)
    baseline = np.full_like(y_test, fill_value=float(y_train.mean()), dtype=float)
    metrics = {
        "n_train": float(len(train)),
        "n_test": float(len(test)),
        "mae": float(mean_absolute_error(y_test, pred)),
        "rmse": float(root_mean_squared_error(y_test, pred)),
        "mae_mean_baseline": float(mean_absolute_error(y_test, baseline)),
        "rmse_mean_baseline": float(root_mean_squared_error(y_test, baseline)),
        "train_mean_total": float(y_train.mean()),
        "test_mean_total": float(y_test.mean()),
    }
    print(json.dumps(metrics, indent=2))
    return model, metrics


def score_local(
    session: Session,
    model: HistGradientBoostingRegressor,
    version_name: str,
) -> pd.DataFrame:
    df = load_matchup(session)
    x = _to_numeric_features(df)
    pred = model.predict(x)
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    out = pd.DataFrame(
        {
            "game_key": df["game_key"],
            "season": df["season"],
            "week": df["week"],
            "season_type": df["season_type"],
            "is_completed": df["is_completed"],
            "model_name": MODEL_NAME,
            "version_name": version_name,
            "scored_at": now,
            "pred_total": pred,
            "label_total": df[LABEL_COLUMN],
            "close_total": df[COMPARATOR_COLUMN],
        }
    )
    session.write_pandas(
        out.reset_index(drop=True),
        table_name="PRED_GAME_TOTAL",
        database=REGISTRY_DB,
        schema=REGISTRY_SCHEMA,
        auto_create_table=True,
        overwrite=True,
        quote_identifiers=False,
    )
    print(f"Wrote {len(out)} rows to {PRED_TABLE}")
    _print_comparators(out)
    return out


def _print_comparators(out: pd.DataFrame) -> None:
    test = out[
        (out["season"] == TEST_SEASON)
        & out["season_type"].isin(ELIGIBLE_SEASON_TYPES)
        & out["label_total"].notna()
    ]
    if not test.empty:
        print(
            "2025 RS+post MAE vs labels:",
            float(mean_absolute_error(test["label_total"], test["pred_total"])),
        )
    closable = out[out["close_total"].notna() & out["pred_total"].notna()]
    if not closable.empty:
        print(
            "pred vs close_total MAE (rows with a close):",
            float(mean_absolute_error(closable["close_total"], closable["pred_total"])),
        )


def log_experiment(session: Session, metrics: dict[str, float]) -> None:
    from snowflake.ml.experiment import ExperimentTracking

    session.use_database(REGISTRY_DB)
    session.use_schema(REGISTRY_SCHEMA)
    exp = ExperimentTracking(
        session=session,
        database_name=REGISTRY_DB,
        schema_name=REGISTRY_SCHEMA,
    )
    exp.set_experiment(MODEL_NAME)
    with exp.start_run("hgb_walkforward_2025"):
        exp.log_params(
            {
                "model": "HistGradientBoostingRegressor",
                "max_depth": 6,
                "learning_rate": 0.05,
                "max_iter": 200,
                "train_seasons": ",".join(str(s) for s in TRAIN_SEASONS),
                "test_season": TEST_SEASON,
                "n_features": len(FEATURE_COLUMNS),
            }
        )
        exp.log_metrics(metrics)


def register(
    session: Session,
    model: HistGradientBoostingRegressor,
) -> str:
    from snowflake.ml.registry import Registry

    assert_feature_contract()
    train, _ = _split(eligible(load_matchup(session)))
    sample_pdf = _to_numeric_features(train).head(5)
    sample = session.create_dataframe(sample_pdf)

    session.use_database(REGISTRY_DB)
    session.use_schema(REGISTRY_SCHEMA)
    reg = Registry(
        session=session,
        database_name=REGISTRY_DB,
        schema_name=REGISTRY_SCHEMA,
    )
    mv = reg.log_model(
        model,
        model_name=MODEL_NAME,
        sample_input_data=sample,
        pip_requirements=["scikit-learn"],
        target_platforms=["SNOWPARK_CONTAINER_SERVICES"],
        comment=(
            "Game total; X from FEAT_GAME_MATCHUP rates (l5+std). "
            "No close_*, no label_*. Train 2023-24, walk-forward 2025."
        ),
    )
    version = mv.version_name
    print(f"Registered {MODEL_NAME} version {version}")
    rows = session.sql(
        f"SHOW MODELS LIKE '{MODEL_NAME}' IN SCHEMA {REGISTRY_DB}.{REGISTRY_SCHEMA}"
    ).collect()
    print(rows)
    funcs = session.sql(
        f"SHOW FUNCTIONS IN MODEL {REGISTRY_DB}.{REGISTRY_SCHEMA}.{MODEL_NAME} "
        f"VERSION {version}"
    ).collect()
    print(funcs)
    return version


def score_batch(session: Session, version: str) -> None:
    from snowflake.ml.model.batch import JobSpec, OutputSpec, SaveMode
    from snowflake.ml.registry import Registry

    train, test = _split(eligible(load_matchup(session)))
    del train
    x = session.create_dataframe(_to_numeric_features(test))
    session.use_database(REGISTRY_DB)
    session.use_schema(REGISTRY_SCHEMA)
    reg = Registry(
        session=session,
        database_name=REGISTRY_DB,
        schema_name=REGISTRY_SCHEMA,
    )
    mv = reg.get_model(MODEL_NAME).version(version)
    print(mv.show_functions())
    job = mv.run_batch(
        X=x,
        compute_pool=COMPUTE_POOL,
        output_spec=OutputSpec(
            stage_location=INFERENCE_STAGE,
            mode=SaveMode.OVERWRITE,
        ),
        job_spec=JobSpec(),
    )
    print("Submitted run_batch; waiting...")
    job.wait()
    print(f"run_batch status: {job.status}")


def cook(session: Session, *, batch: bool) -> None:
    inspect(session)
    model, metrics = fit(session)
    try:
        log_experiment(session, metrics)
    except Exception as exc:  # noqa: BLE001 — tracking must not block register
        print(f"Experiment tracking skipped: {exc}")
    version = register(session, model)
    score_local(session, model, version)
    if batch:
        score_batch(session, version)
