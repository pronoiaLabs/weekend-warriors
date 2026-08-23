"""Unit tests for the APP-schema Snowflake source. No network."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

pytest.importorskip("dlt")

from pipelines.batch.snowflake_app_source import qualify, snowflake_app  # noqa: E402


def test_qualify_rejects_non_identifiers() -> None:
    with pytest.raises(ValueError, match="table"):
        qualify("NFL_PROD_DB", "APP", "app_game_slate; DROP TABLE x")
    with pytest.raises(ValueError, match="database"):
        qualify("NFL-PROD", "APP", "app_game_slate")


def test_qualify_joins_three_idents() -> None:
    assert qualify("NFL_PROD_DB", "APP", "app_game_slate") == (
        "NFL_PROD_DB.APP.app_game_slate"
    )


def test_source_reads_only_listed_tables() -> None:
    executed: list[str] = []

    class _Cursor:
        def execute(self, sql: str) -> None:
            executed.append(sql)

        def __iter__(self):
            return iter([{"COL": 1}])

    class _Conn:
        def cursor(self, *_args, **_kwargs):
            return _Cursor()

        def close(self) -> None:
            return None

    source = snowflake_app(
        name="nfl_app_to_postgres",
        tables=["app_game_slate", "app_news_mentions"],
        database="NFL_PROD_DB",
        schema="APP",
        connect=lambda: _Conn(),
    )
    assert set(source.resources) == {"app_game_slate", "app_news_mentions"}
    rows = list(source.resources["app_game_slate"])
    assert rows == [{"col": 1}]
    assert executed == ["SELECT * FROM NFL_PROD_DB.APP.app_game_slate"]
    assert not any("INFORMATION_SCHEMA" in sql for sql in executed)


def test_empty_tables_rejected() -> None:
    with pytest.raises(ValueError, match="tables"):
        snowflake_app(name="x", tables=[], database="NFL_PROD_DB")
