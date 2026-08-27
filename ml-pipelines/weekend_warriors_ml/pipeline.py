"""Walk-forward fit, registry log, local score, optional run_batch. Spec-driven."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor
from sklearn.metrics import (
    accuracy_score,
    brier_score_loss,
    log_loss,
    mean_absolute_error,
    roc_auc_score,
    root_mean_squared_error,
)
from snowflake.snowpark import Session

from weekend_warriors_ml.specs import (
    COMPUTE_POOL,
    ELIGIBLE_SEASON_TYPES,
    MATCHUP_TABLE,
    PLAYER_OFFENSE_FACT,
    PLAYER_ROLLING_TABLE,
    PLAYER_WEATHER_TABLE,
    REGISTRY_DB,
    REGISTRY_SCHEMA,
    TEST_SEASON,
    TRAIN_SEASONS,
    ModelSpec,
    assert_feature_contract,
    get_spec,
)

_WEATHER_COLS = frozenset(
    {
        "is_weather_relevant",
        "weather_temp_f",
        "weather_wind_mph",
        "weather_precip_in",
        "elevation_m",
        "pass_volume_in_wind",
        "targets_in_wind",
        "rush_share_in_wind",
        "pass_volume_in_cold",
        "ball_security_in_precip",
    }
)

PLAYER_LABEL_EXPR = {
    "label_passing_yards": "IFF(r.is_completed, o.passing_yards, NULL)",
    "label_rushing_yards": "IFF(r.is_completed, o.rushing_yards, NULL)",
    "label_receiving_yards": "IFF(r.is_completed, o.receiving_yards, NULL)",
    "label_receptions": "IFF(r.is_completed, o.receptions, NULL)",
    "label_passing_tds": "IFF(r.is_completed, o.passing_touchdowns, NULL)",
    "label_anytime_td": (
        "IFF(r.is_completed, "
        "IFF(COALESCE(o.rushing_touchdowns, 0) + COALESCE(o.receiving_touchdowns, 0) >= 1, 1, 0), "
        "NULL)"
    ),
}


def _lower_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out.columns = [c.lower() for c in out.columns]
    return out


def _to_numeric_features(df: pd.DataFrame, spec: ModelSpec) -> pd.DataFrame:
    x = df.loc[:, list(spec.feature_columns)].copy()
    for col in x.columns:
        if x[col].dtype == bool or str(x[col].dtype) == "boolean":
            x[col] = x[col].astype("float64")
        elif not pd.api.types.is_numeric_dtype(x[col]):
            x[col] = pd.to_numeric(x[col], errors="coerce")
    return x


def _game_sql(spec: ModelSpec) -> str:
    needed = list(
        dict.fromkeys(
            [
                *spec.id_columns,
                *spec.feature_columns,
                spec.label_column,
                *([spec.comparator_column] if spec.comparator_column else []),
            ]
        )
    )
    return f"SELECT {', '.join(needed)} FROM {MATCHUP_TABLE}"


def _player_sql(spec: ModelSpec) -> str:
    try:
        label_expr = PLAYER_LABEL_EXPR[spec.label_column]
    except KeyError as exc:
        raise KeyError(f"no CORE label expression for {spec.label_column}") from exc
    select_cols = [f"r.{c}" for c in spec.id_columns]
    for col in spec.feature_columns:
        alias = f"w.{col}" if col in _WEATHER_COLS else f"r.{col}"
        select_cols.append(f"{alias} AS {col}")
    select_cols.append(f"{label_expr} AS {spec.label_column}")
    return (
        f"SELECT {', '.join(select_cols)} "
        f"FROM {PLAYER_ROLLING_TABLE} r "
        f"INNER JOIN {PLAYER_WEATHER_TABLE} w "
        f"ON r.player_game_key = w.player_game_key "
        f"LEFT JOIN {PLAYER_OFFENSE_FACT} o "
        f"ON r.player_game_key = o.player_game_key"
    )


def load_frame(session: Session, spec: ModelSpec) -> pd.DataFrame:
    sql = _game_sql(spec) if spec.family == "game" else _player_sql(spec)
    return _lower_columns(session.sql(sql).to_pandas())


def eligible(df: pd.DataFrame, spec: ModelSpec) -> pd.DataFrame:
    mask = (
        df["season_type"].isin(ELIGIBLE_SEASON_TYPES)
        & df["is_completed"].astype(bool)
        & df[spec.label_column].notna()
    )
    if spec.min_feature is not None:
        mask = mask & (pd.to_numeric(df[spec.min_feature], errors="coerce").fillna(0) > 0)
    return df[mask].copy()


def inspect(session: Session, model_name: str = "NFL_GAME_TOTAL") -> dict[str, object]:
    spec = get_spec(model_name)
    df = load_frame(session, spec)
    elig = eligible(df, spec)
    summary: dict[str, object] = {
        "model": spec.name,
        "family": spec.family,
        "task": spec.task,
        "rows": len(df),
        "eligible_rs_post": len(elig),
        "by_season": {int(k): int(v) for k, v in elig.groupby("season").size().to_dict().items()},
        "label_null": int(df[spec.label_column].isna().sum()),
        "n_features": len(spec.feature_columns),
        "min_feature": spec.min_feature,
    }
    if spec.comparator_column and spec.comparator_column in df.columns:
        summary["close_nonnull"] = int(df[spec.comparator_column].notna().sum())
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


def _estimator(spec: ModelSpec) -> Any:
    kwargs = {"max_depth": 6, "learning_rate": 0.05, "max_iter": 200, "random_state": 42}
    if spec.task == "classification":
        return HistGradientBoostingClassifier(**kwargs)
    return HistGradientBoostingRegressor(**kwargs)


def _predict(model: Any, x: pd.DataFrame, spec: ModelSpec) -> np.ndarray:
    if spec.task == "classification":
        return model.predict_proba(x)[:, 1]
    return model.predict(x)


def _metrics(
    spec: ModelSpec,
    y_train: pd.Series,
    y_test: pd.Series,
    pred: np.ndarray,
    n_train: int,
    n_test: int,
) -> dict[str, float]:
    if spec.task == "classification":
        y_test_i = y_test.astype(int)
        baseline_rate = float(y_train.mean())
        baseline = np.full(len(y_test_i), baseline_rate, dtype=float)
        pred_cls = (pred >= 0.5).astype(int)
        return {
            "n_train": float(n_train),
            "n_test": float(n_test),
            "log_loss": float(log_loss(y_test_i, pred)),
            "roc_auc": float(roc_auc_score(y_test_i, pred)),
            "brier": float(brier_score_loss(y_test_i, pred)),
            "accuracy": float(accuracy_score(y_test_i, pred_cls)),
            "log_loss_rate_baseline": float(log_loss(y_test_i, baseline)),
            "brier_rate_baseline": float(brier_score_loss(y_test_i, baseline)),
            "train_rate": float(y_train.mean()),
            "test_rate": float(y_test.mean()),
        }
    baseline = np.full_like(y_test, fill_value=float(y_train.mean()), dtype=float)
    return {
        "n_train": float(n_train),
        "n_test": float(n_test),
        "mae": float(mean_absolute_error(y_test, pred)),
        "rmse": float(root_mean_squared_error(y_test, pred)),
        "mae_mean_baseline": float(mean_absolute_error(y_test, baseline)),
        "rmse_mean_baseline": float(root_mean_squared_error(y_test, baseline)),
        "train_mean": float(y_train.mean()),
        "test_mean": float(y_test.mean()),
    }


def fit(
    session: Session, model_name: str = "NFL_GAME_TOTAL"
) -> tuple[Any, dict[str, float]]:
    spec = get_spec(model_name)
    assert_feature_contract(spec.feature_columns)
    train, test = _split(eligible(load_frame(session, spec), spec))
    x_train = _to_numeric_features(train, spec)
    x_test = _to_numeric_features(test, spec)
    y_dtype = int if spec.task == "classification" else "float64"
    y_train = train[spec.label_column].astype(y_dtype)
    y_test = test[spec.label_column].astype(y_dtype)

    model = _estimator(spec)
    model.fit(x_train, y_train)
    pred = _predict(model, x_test, spec)
    metrics = _metrics(spec, y_train, y_test, pred, len(train), len(test))
    print(json.dumps(metrics, indent=2))
    return model, metrics


def score_local(
    session: Session,
    model: Any,
    version_name: str,
    model_name: str = "NFL_GAME_TOTAL",
) -> pd.DataFrame:
    spec = get_spec(model_name)
    df = load_frame(session, spec)
    pred = _predict(model, _to_numeric_features(df, spec), spec)
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    payload: dict[str, object] = {col: df[col] for col in spec.id_columns}
    payload.update(
        {
            "model_name": spec.name,
            "version_name": version_name,
            "scored_at": now,
            spec.pred_column: pred,
            spec.label_column: df[spec.label_column],
        }
    )
    if spec.comparator_column and spec.comparator_column in df.columns:
        payload[spec.comparator_column] = df[spec.comparator_column]
    out = pd.DataFrame(payload)
    session.write_pandas(
        out.reset_index(drop=True),
        table_name=spec.pred_table,
        database=REGISTRY_DB,
        schema=REGISTRY_SCHEMA,
        auto_create_table=True,
        overwrite=True,
        quote_identifiers=False,
    )
    print(f"Wrote {len(out)} rows to {REGISTRY_DB}.{REGISTRY_SCHEMA}.{spec.pred_table}")
    _print_comparators(out, spec)
    return out


def _print_comparators(out: pd.DataFrame, spec: ModelSpec) -> None:
    test = out[
        (out["season"] == TEST_SEASON)
        & out["season_type"].isin(ELIGIBLE_SEASON_TYPES)
        & out[spec.label_column].notna()
    ]
    if test.empty:
        return
    y = test[spec.label_column]
    p = test[spec.pred_column]
    if spec.task == "classification":
        print("2025 RS+post Brier:", float(brier_score_loss(y.astype(int), p)))
    else:
        print("2025 RS+post MAE vs labels:", float(mean_absolute_error(y, p)))
    if spec.comparator_column and spec.comparator_column in out.columns:
        closable = out[out[spec.comparator_column].notna() & out[spec.pred_column].notna()]
        if not closable.empty:
            print(
                f"pred vs {spec.comparator_column} MAE (rows with a close):",
                float(mean_absolute_error(closable[spec.comparator_column], closable[spec.pred_column])),
            )


def log_experiment(
    session: Session,
    metrics: dict[str, float],
    model_name: str = "NFL_GAME_TOTAL",
) -> None:
    from snowflake.ml.experiment import ExperimentTracking

    spec = get_spec(model_name)
    session.use_database(REGISTRY_DB)
    session.use_schema(REGISTRY_SCHEMA)
    exp = ExperimentTracking(
        session=session,
        database_name=REGISTRY_DB,
        schema_name=REGISTRY_SCHEMA,
    )
    exp.set_experiment(spec.name)
    estimator = (
        "HistGradientBoostingClassifier"
        if spec.task == "classification"
        else "HistGradientBoostingRegressor"
    )
    with exp.start_run("hgb_walkforward_2025"):
        exp.log_params(
            {
                "model": estimator,
                "max_depth": 6,
                "learning_rate": 0.05,
                "max_iter": 200,
                "train_seasons": ",".join(str(s) for s in TRAIN_SEASONS),
                "test_season": TEST_SEASON,
                "n_features": len(spec.feature_columns),
                "label": spec.label_column,
            }
        )
        exp.log_metrics(metrics)


def register(
    session: Session,
    model: Any,
    model_name: str = "NFL_GAME_TOTAL",
) -> str:
    from snowflake.ml.registry import Registry

    spec = get_spec(model_name)
    assert_feature_contract(spec.feature_columns)
    train, _ = _split(eligible(load_frame(session, spec), spec))
    sample = session.create_dataframe(_to_numeric_features(train, spec).head(5))

    session.use_database(REGISTRY_DB)
    session.use_schema(REGISTRY_SCHEMA)
    reg = Registry(
        session=session,
        database_name=REGISTRY_DB,
        schema_name=REGISTRY_SCHEMA,
    )
    mv = reg.log_model(
        model,
        model_name=spec.name,
        sample_input_data=sample,
        pip_requirements=["scikit-learn"],
        target_platforms=["SNOWPARK_CONTAINER_SERVICES"],
        comment=spec.comment,
    )
    version = mv.version_name
    print(f"Registered {spec.name} version {version}")
    rows = session.sql(
        f"SHOW MODELS LIKE '{spec.name}' IN SCHEMA {REGISTRY_DB}.{REGISTRY_SCHEMA}"
    ).collect()
    print(rows)
    funcs = session.sql(
        f"SHOW FUNCTIONS IN MODEL {REGISTRY_DB}.{REGISTRY_SCHEMA}.{spec.name} "
        f"VERSION {version}"
    ).collect()
    print(funcs)
    return version


def score_batch(
    session: Session,
    version: str,
    model_name: str = "NFL_GAME_TOTAL",
) -> None:
    from snowflake.ml.model.batch import JobSpec, OutputSpec, SaveMode
    from snowflake.ml.registry import Registry

    spec = get_spec(model_name)
    _, test = _split(eligible(load_frame(session, spec), spec))
    x = session.create_dataframe(_to_numeric_features(test, spec))
    session.use_database(REGISTRY_DB)
    session.use_schema(REGISTRY_SCHEMA)
    reg = Registry(
        session=session,
        database_name=REGISTRY_DB,
        schema_name=REGISTRY_SCHEMA,
    )
    mv = reg.get_model(spec.name).version(version)
    print(mv.show_functions())
    job = mv.run_batch(
        X=x,
        compute_pool=COMPUTE_POOL,
        output_spec=OutputSpec(
            stage_location=spec.inference_stage,
            mode=SaveMode.OVERWRITE,
        ),
        job_spec=JobSpec(),
    )
    print("Submitted run_batch; waiting...")
    job.wait()
    print(f"run_batch status: {job.status}")


def cook(
    session: Session,
    model_name: str = "NFL_GAME_TOTAL",
    *,
    batch: bool = False,
) -> None:
    inspect(session, model_name)
    model, metrics = fit(session, model_name)
    try:
        log_experiment(session, metrics, model_name)
    except Exception as exc:  # noqa: BLE001 — tracking must not block register
        print(f"Experiment tracking skipped: {exc}")
    version = register(session, model, model_name)
    score_local(session, model, version, model_name)
    if batch:
        score_batch(session, version, model_name)
