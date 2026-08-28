"""Unit tests for the APP copy watermark. No network."""

from __future__ import annotations

import sys
from types import SimpleNamespace
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from pipelines.batch.app_copy_watermark import (  # noqa: E402
    changed_tables,
    current_table_signatures,
    latest_build_id,
    listed_table_names,
    stored_content_hashes,
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
        ("nfl", "app_game_slate", "build-1", 10, None),
        ("nfl", "app_news_mentions", "build-1", 3, None),
    ]


def test_watermark_skips_tables_this_run_did_not_load() -> None:
    writes: list[tuple] = []
    write_app_copy_watermark(
        _spec(),
        {"app_game_slate": 1553, "_dlt_pipeline_state": 1},
        fetch_build_id=lambda _sport: "build-1",
        upsert=lambda sql, params: writes.append(params),
    )
    assert writes == [("nfl", "app_game_slate", "build-1", 1553, None)]


def test_watermark_stores_content_hash_for_loaded_tables() -> None:
    writes: list[tuple] = []
    write_app_copy_watermark(
        _spec(),
        {"app_news_mentions": 99},
        fetch_build_id=lambda _sport: "build-2",
        upsert=lambda sql, params: writes.append(params),
        content_hashes={
            "app_game_slate": "old",
            "app_news_mentions": "hash-news",
        },
        source_row_counts={"app_news_mentions": 3},
    )
    assert writes == [("nfl", "app_news_mentions", "build-2", 3, "hash-news")]


def test_watermark_records_a_selected_empty_table() -> None:
    spec = _spec()
    spec.config["tables"] = ["app_team_ats"]
    writes: list[tuple] = []

    write_app_copy_watermark(
        spec,
        {},
        fetch_build_id=lambda _sport: "build-2",
        upsert=lambda sql, params: writes.append(params),
        content_hashes={"app_team_ats": "empty-hash"},
        source_row_counts={"app_team_ats": 0},
    )

    assert writes == [("nfl", "app_team_ats", "build-2", 0, "empty-hash")]


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


def test_listed_table_names_accepts_mapping_entries() -> None:
    spec = _spec()
    spec.config["tables"] = [
        "app_game_slate",
        {"name": "app_news_mentions", "mode": "replace"},
    ]
    assert listed_table_names(spec) == ["app_game_slate", "app_news_mentions"]


def test_current_table_signatures_use_qualified_hash_agg_and_count() -> None:
    queries: list[str] = []

    def fetch(sql: str) -> tuple[int, int]:
        queries.append(sql)
        return (len(queries) * 10, len(queries) * 100)

    signatures = current_table_signatures(_spec(), fetch_signature=fetch)
    assert signatures == {
        "app_game_slate": ("10", 100),
        "app_news_mentions": ("20", 200),
    }
    assert queries == [
        "SELECT HASH_AGG(*), COUNT(*) FROM NFL_PROD_DB.APP.app_game_slate",
        "SELECT HASH_AGG(*), COUNT(*) FROM NFL_PROD_DB.APP.app_news_mentions",
    ]


def test_stored_content_hashes_drops_nulls_and_normalizes_names() -> None:
    calls: list[tuple[str, tuple]] = []

    def fetch(sql: str, params: tuple) -> list[tuple[str, str | None]]:
        calls.append((sql, params))
        return [("APP_GAME_SLATE", "hash-1"), ("app_news_mentions", None)]

    assert stored_content_hashes(_spec(), fetch=fetch) == {"app_game_slate": "hash-1"}
    assert calls[0][1] == ("nfl",)


def test_changed_tables_copies_missing_or_different_hashes() -> None:
    current = {
        "app_game_slate": "same",
        "app_news_mentions": "new",
    }
    stored = {
        "app_game_slate": "same",
        "app_news_mentions": "old",
    }
    assert changed_tables(_spec(), current, stored) == ["app_news_mentions"]
    assert changed_tables(_spec(), current, {}) == [
        "app_game_slate",
        "app_news_mentions",
    ]
    assert changed_tables(_spec(), current, current) == []


class _FakeSource:
    def __init__(self) -> None:
        self.selected: tuple[str, ...] = ()

    def with_resources(self, *names: str):
        self.selected = names
        return self


class _FakePipeline:
    def __init__(self, row_counts: dict[str, int]) -> None:
        self.run_calls: list[tuple[object, dict]] = []
        self.last_trace = SimpleNamespace(
            last_normalize_info=SimpleNamespace(row_counts=row_counts)
        )

    def run(self, source, **kwargs):
        self.run_calls.append((source, kwargs))
        return SimpleNamespace(
            loads_ids=["load-1"],
            raise_on_failed_jobs=lambda: None,
        )


def _copy_spec() -> PipelineSpec:
    return PipelineSpec(
        name="nfl_app_to_postgres",
        source="snowflake_app",
        destination="postgres",
        database="NFL",
        dataset_name="app_copy",
        write_disposition="replace",
        config={
            "tables": ["app_game_slate", "app_news_mentions"],
            "loader_file_format": "csv",
            "skip_unchanged": True,
        },
    )


def test_run_pipeline_skips_load_when_every_hash_matches(monkeypatch) -> None:
    from pipelines.batch import app_copy_watermark, run

    source = _FakeSource()
    pipeline = _FakePipeline({})
    recorded: list[dict] = []
    signatures = {
        "app_game_slate": ("a", 10),
        "app_news_mentions": ("b", 3),
    }
    current = {table: values[0] for table, values in signatures.items()}

    monkeypatch.delenv("DLT_FORCE_FULL_COPY", raising=False)
    monkeypatch.setattr(run.dlt, "pipeline", lambda **_kwargs: pipeline)
    monkeypatch.setattr(run, "build_source", lambda _spec: source)
    monkeypatch.setattr(run, "_check_secrets", lambda _spec: None)
    monkeypatch.setattr(run, "record_run", lambda _spec, **kwargs: recorded.append(kwargs))
    monkeypatch.setattr(
        app_copy_watermark,
        "current_table_signatures",
        lambda _spec, **_kwargs: signatures,
    )
    monkeypatch.setattr(app_copy_watermark, "stored_content_hashes", lambda _spec: current)

    run.run_pipeline(_copy_spec())

    assert pipeline.run_calls == []
    assert recorded == [
        {
            "status": "ok",
            "load_id": None,
            "row_counts": {},
            "resources": None,
            "params": None,
        }
    ]


def test_run_pipeline_forwards_csv_and_watermarks_changed_tables(monkeypatch) -> None:
    from pipelines.batch import app_copy_watermark, run

    source = _FakeSource()
    # dlt 1.29's CSV writer reports cells, not rows. The signature count is 3
    # and must replace this incorrect normalizer value before watermarking.
    pipeline = _FakePipeline({"app_news_mentions": 99})
    watermarks: list[tuple[dict, dict]] = []
    signatures = {
        "app_game_slate": ("same", 10),
        "app_news_mentions": ("new", 3),
    }
    current = {table: values[0] for table, values in signatures.items()}

    monkeypatch.delenv("DLT_FORCE_FULL_COPY", raising=False)
    monkeypatch.setattr(run.dlt, "pipeline", lambda **_kwargs: pipeline)
    monkeypatch.setattr(run, "build_source", lambda _spec: source)
    monkeypatch.setattr(run, "_check_secrets", lambda _spec: None)
    monkeypatch.setattr(run, "_check_merge_keys", lambda _spec, _source: None)
    monkeypatch.setattr(run, "record_run", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(
        app_copy_watermark,
        "current_table_signatures",
        lambda _spec, **_kwargs: signatures,
    )
    monkeypatch.setattr(
        app_copy_watermark,
        "stored_content_hashes",
        lambda _spec: {"app_game_slate": "same", "app_news_mentions": "old"},
    )
    monkeypatch.setattr(
        app_copy_watermark,
        "write_app_copy_watermark",
        lambda _spec, rows, **kwargs: watermarks.append((rows, kwargs)),
    )

    run.run_pipeline(_copy_spec())

    assert source.selected == ("app_news_mentions",)
    assert pipeline.run_calls[0][1] == {
        "write_disposition": "replace",
        "loader_file_format": "csv",
    }
    assert watermarks == [
        (
            {"app_news_mentions": 3},
            {
                "content_hashes": current,
                "source_row_counts": {"app_news_mentions": 3},
            },
        )
    ]


def test_force_full_copy_bypasses_matching_hashes(monkeypatch) -> None:
    from pipelines.batch import app_copy_watermark, run

    source = _FakeSource()
    pipeline = _FakePipeline(
        {"app_game_slate": 10, "app_news_mentions": 3}
    )
    signatures = {
        "app_game_slate": ("same-a", 10),
        "app_news_mentions": ("same-b", 3),
    }

    monkeypatch.setenv("DLT_FORCE_FULL_COPY", "1")
    monkeypatch.setattr(run.dlt, "pipeline", lambda **_kwargs: pipeline)
    monkeypatch.setattr(run, "build_source", lambda _spec: source)
    monkeypatch.setattr(run, "_check_secrets", lambda _spec: None)
    monkeypatch.setattr(run, "_check_merge_keys", lambda _spec, _source: None)
    monkeypatch.setattr(run, "record_run", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(
        app_copy_watermark,
        "current_table_signatures",
        lambda _spec, **_kwargs: signatures,
    )
    monkeypatch.setattr(
        app_copy_watermark,
        "stored_content_hashes",
        lambda _spec: (_ for _ in ()).throw(AssertionError("must not read stored hashes")),
    )
    monkeypatch.setattr(
        app_copy_watermark,
        "write_app_copy_watermark",
        lambda *_args, **_kwargs: None,
    )

    run.run_pipeline(_copy_spec())

    assert source.selected == ("app_game_slate", "app_news_mentions")
    assert len(pipeline.run_calls) == 1
