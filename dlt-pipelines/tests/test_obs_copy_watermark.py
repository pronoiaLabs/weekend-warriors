"""Unit tests for the observability copy watermark. No network."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from pipelines.batch.models import PipelineSpec  # noqa: E402
from pipelines.batch.obs_copy_watermark import (  # noqa: E402
    is_obs_copy,
    write_obs_copy_watermark,
)


def _obs_spec() -> PipelineSpec:
    return PipelineSpec(
        name="obs_to_postgres",
        source="snowflake_app",
        database="NFL",
        dataset_name="observability",
        config={
            "database": "DLT_DB",
            "schema": "OPS",
            "tables": ["pipeline_runs", "task_runs"],
        },
    )


def _app_spec() -> PipelineSpec:
    return PipelineSpec(
        name="nfl_app_to_postgres",
        source="snowflake_app",
        database="NFL",
        dataset_name="app_copy",
        config={"schema": "APP", "tables": ["app_game_slate"]},
    )


def test_is_obs_copy_detects_dataset_and_ops_schema() -> None:
    assert is_obs_copy(_obs_spec())
    assert not is_obs_copy(_app_spec())
    ops_only = PipelineSpec(
        name="x",
        source="snowflake_app",
        dataset_name="something_else",
        config={"schema": "OPS", "tables": ["pipeline_runs"]},
    )
    assert is_obs_copy(ops_only)


def test_obs_watermark_upserts_each_listed_table() -> None:
    writes: list[tuple] = []
    write_obs_copy_watermark(
        _obs_spec(),
        {"pipeline_runs": 10, "task_runs": 3},
        source_ref="2026-08-23T15:00:00+00:00",
        upsert=lambda sql, params: writes.append(params),
    )
    assert writes == [
        ("pipeline_runs", 10, "2026-08-23T15:00:00+00:00"),
        ("task_runs", 3, "2026-08-23T15:00:00+00:00"),
    ]


def test_obs_watermark_skips_tables_this_run_did_not_load() -> None:
    writes: list[tuple] = []
    write_obs_copy_watermark(
        _obs_spec(),
        {"pipeline_runs": 42, "_dlt_pipeline_state": 1},
        source_ref="ref-1",
        upsert=lambda sql, params: writes.append(params),
    )
    assert writes == [("pipeline_runs", 42, "ref-1")]


def test_obs_watermark_quiet_incremental_run_is_a_noop() -> None:
    # An incremental copy that found no new rows loads nothing: clean no-op,
    # previous stamps kept. Before incremental this case meant breakage; now
    # it is every quiet hour (2026-08-28).
    writes: list[tuple] = []
    write_obs_copy_watermark(
        _obs_spec(),
        {"_dlt_pipeline_state": 1},
        upsert=lambda sql, params: writes.append(params),
    )
    assert writes == []


def test_obs_watermark_fails_on_unlisted_tables_only() -> None:
    # row_counts naming ONLY tables the registry does not list is still a
    # refusal: something loaded, and it was not what this pipeline owns.
    with pytest.raises(RuntimeError, match="no listed OPS tables"):
        write_obs_copy_watermark(
            _obs_spec(),
            {"some_other_table": 5},
            upsert=lambda *_a, **_k: None,
        )


def test_obs_watermark_does_not_require_a_dbt_build() -> None:
    """Regression: APP watermark looks up DBT_BUILDS; obs must not."""
    writes: list[tuple] = []
    write_obs_copy_watermark(
        _obs_spec(),
        {"pipeline_runs": 1, "task_runs": 1},
        source_ref="stamp",
        upsert=lambda sql, params: writes.append(params),
    )
    assert all(len(params) == 3 for params in writes)
    assert all(params[2] == "stamp" for params in writes)
