"""Unit tests for the APP copy watermark. No network."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from pipelines.batch.app_copy_watermark import (  # noqa: E402
    latest_build_id,
    write_app_copy_watermark,
)
from pipelines.batch.models import PipelineSpec  # noqa: E402


def _spec() -> PipelineSpec:
    return PipelineSpec(
        name="nfl_app_to_postgres",
        source="snowflake_app",
        database="NFL",
        config={"tables": ["app_game_slate", "app_news_mentions"]},
    )


def test_latest_build_id_fails_when_empty() -> None:
    with pytest.raises(RuntimeError, match="no DLT_DB.OPS.DBT_BUILDS"):
        latest_build_id("nfl", execute=lambda _sql: None)


def test_watermark_upserts_each_listed_table() -> None:
    writes: list[tuple] = []
    write_app_copy_watermark(
        _spec(),
        {"app_game_slate": 10, "app_news_mentions": 3},
        fetch_build_id=lambda sport: "build-1" if sport == "nfl" else "nope",
        upsert=lambda sql, params: writes.append(params),
    )
    assert writes == [
        ("nfl", "app_game_slate", "build-1", 10),
        ("nfl", "app_news_mentions", "build-1", 3),
    ]


def test_watermark_skips_tables_this_run_did_not_load() -> None:
    writes: list[tuple] = []
    write_app_copy_watermark(
        _spec(),
        {"app_game_slate": 1553, "_dlt_pipeline_state": 1},
        fetch_build_id=lambda _sport: "build-1",
        upsert=lambda sql, params: writes.append(params),
    )
    assert writes == [("nfl", "app_game_slate", "build-1", 1553)]


def test_watermark_fails_when_build_lookup_fails() -> None:
    with pytest.raises(RuntimeError, match="no source build"):
        write_app_copy_watermark(
            _spec(),
            {"app_game_slate": 1},
            fetch_build_id=lambda _sport: (_ for _ in ()).throw(
                RuntimeError("no source build")
            ),
            upsert=lambda *_a, **_k: None,
        )
