"""Unit tests for the APP-schema Snowflake source. No network."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_ROOT = Path(__file__).parent.parent.resolve()
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

pytest.importorskip("dlt")

from pipelines.batch.snowflake_app_source import (  # noqa: E402
    adapt_copied_value,
    dlt_data_type,
    qualify,
    snowflake_app,
)


def test_qualify_rejects_non_identifiers() -> None:
    with pytest.raises(ValueError, match="table"):
        qualify("NFL_PROD_DB", "APP", "app_game_slate; DROP TABLE x")
    with pytest.raises(ValueError, match="database"):
        qualify("NFL-PROD", "APP", "app_game_slate")


def test_qualify_joins_three_idents() -> None:
    assert qualify("NFL_PROD_DB", "APP", "app_game_slate") == (
        "NFL_PROD_DB.APP.app_game_slate"
    )


def test_dlt_data_type_maps_snowflake_describe() -> None:
    assert dlt_data_type("NUMBER(19,0)") == "bigint"
    assert dlt_data_type("NUMBER(18,2)") == "double"
    assert dlt_data_type("FLOAT") == "double"
    assert dlt_data_type("BOOLEAN") == "bool"
    assert dlt_data_type("DATE") == "date"
    assert dlt_data_type("TIMESTAMP_NTZ(9)") == "timestamp"
    assert dlt_data_type("VARIANT") == "text"
    assert dlt_data_type("ARRAY") == "json"
    assert dlt_data_type("OBJECT") == "json"
    assert dlt_data_type("VARCHAR(16777216)") == "text"


def test_adapt_copied_value_keeps_variant_strings_as_text() -> None:
    # PIPELINE_REGISTRY.write_disposition: VARIANT string, not a JSON object.
    assert adapt_copied_value("replace", "text") == "replace"
    assert adapt_copied_value('"replace"', "text") == '"replace"'
    assert adapt_copied_value({"database": "DLT_DB"}, "text") == '{"database": "DLT_DB"}'
    assert adapt_copied_value(["a", 1], "text") == '["a", 1]'
    assert adapt_copied_value(None, "text") is None


def test_adapt_copied_value_wraps_non_json_for_jsonb() -> None:
    assert adapt_copied_value("replace", "json") == '"replace"'
    assert adapt_copied_value('{"a": 1}', "json") == '{"a": 1}'
    assert adapt_copied_value({"a": 1}, "json") == {"a": 1}


def test_source_reads_only_listed_tables() -> None:
    executed: list[str] = []

    class _Cursor:
        def execute(self, sql: str) -> None:
            executed.append(sql)
            self._sql = sql

        def fetchall(self) -> list[dict[str, str]]:
            return [{"name": "COL", "type": "NUMBER(19,0)", "null?": "Y"}]

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
    assert source.resources["app_game_slate"].compute_table_schema()["columns"]["col"][
        "data_type"
    ] == "bigint"
    rows = list(source.resources["app_game_slate"])
    assert rows == [{"col": 1}]
    assert executed[0] == "DESCRIBE TABLE NFL_PROD_DB.APP.app_game_slate"
    assert executed[-1] == "SELECT * FROM NFL_PROD_DB.APP.app_game_slate"
    assert not any("INFORMATION_SCHEMA" in sql for sql in executed)


def test_source_adapts_variant_cells() -> None:
    class _Cursor:
        def execute(self, sql: str) -> None:
            self._sql = sql

        def fetchall(self) -> list[dict[str, str]]:
            return [
                {"name": "NAME", "type": "VARCHAR", "null?": "N"},
                {"name": "WRITE_DISPOSITION", "type": "VARIANT", "null?": "Y"},
                {"name": "CONFIG", "type": "VARIANT", "null?": "Y"},
            ]

        def __iter__(self):
            return iter(
                [
                    {
                        "NAME": "obs_to_postgres",
                        "WRITE_DISPOSITION": "replace",
                        "CONFIG": {"database": "DLT_DB"},
                    }
                ]
            )

    class _Conn:
        def cursor(self, *_args, **_kwargs):
            return _Cursor()

        def close(self) -> None:
            return None

    source = snowflake_app(
        name="obs_to_postgres",
        tables=["pipeline_registry"],
        database="DLT_DB",
        schema="OPS",
        connect=lambda: _Conn(),
    )
    schema = source.resources["pipeline_registry"].compute_table_schema()["columns"]
    assert schema["write_disposition"]["data_type"] == "text"
    assert schema["config"]["data_type"] == "text"
    assert list(source.resources["pipeline_registry"]) == [
        {
            "name": "obs_to_postgres",
            "write_disposition": "replace",
            "config": '{"database": "DLT_DB"}',
        }
    ]


def test_empty_tables_rejected() -> None:
    with pytest.raises(ValueError, match="tables"):
        snowflake_app(name="x", tables=[], database="NFL_PROD_DB")
