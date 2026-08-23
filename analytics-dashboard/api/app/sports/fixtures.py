"""Recorded rows and schemas for fixture mode and for the contract tests.

  fixtures/app/<sport>/<table>.json   rows captured from a dev build by
                                      scripts/capture_fixtures.py: {"table",
                                      "captured_from", "where", "rows"}, the rows in
                                      the shape db.query returns (lowercase keys)
  fixtures/app/schema/<table>.json    DESCRIBE TABLE of the mart, the column
                                      contract a profile's tables are tested against
"""

import json
from functools import cache
from pathlib import Path
from typing import Any

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "app"


@cache
def rows(sport_key: str, table: str) -> list[dict[str, Any]]:
    path = FIXTURES / sport_key / f"{table}.json"
    if not path.is_file():
        return []
    return json.loads(path.read_text())["rows"]


@cache
def schema(table: str) -> dict[str, Any] | None:
    path = FIXTURES / "schema" / f"{table}.json"
    if not path.is_file():
        return None
    return json.loads(path.read_text())


def columns(table: str) -> set[str]:
    spec = schema(table)
    return {c["name"] for c in spec["columns"]} if spec else set()
