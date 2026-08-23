"""Every column the datasource selects exists on the object it reads. The
fixture form checks the recorded DESCRIBE in fixtures/schema/; the live form
describes the real objects and is the early warning for a view change."""

import json
import os
from pathlib import Path

import pytest

from app import datasource

SCHEMA = Path(__file__).resolve().parents[1] / "app" / "fixtures" / "schema"


def _recorded(name: str) -> set[str] | None:
    path = SCHEMA / f"{name}.json"
    if not path.is_file():
        return None
    return {c["name"].lower() for c in json.loads(path.read_text())["columns"]}


@pytest.mark.parametrize("name", sorted(datasource.OBJECTS))
def test_selected_columns_exist_in_recorded_schema(name: str) -> None:
    fqn, columns = datasource.OBJECTS[name]
    recorded = _recorded(name)
    assert recorded is not None, f"no fixtures/schema/{name}.json for {fqn}"
    missing = set(columns) - recorded
    assert not missing, f"{fqn} schema fixture lacks {sorted(missing)}"


@pytest.mark.live
@pytest.mark.parametrize("name", sorted(datasource.OBJECTS))
def test_selected_columns_exist_live(name: str) -> None:
    assert os.environ.get("OPS_DASHBOARD_LIVE") == "1"
    from app import db

    described = datasource.describe_sql(name)
    if described is None:
        pytest.skip(f"{name} is not on the postgres copy")
    sql, params = described
    _, columns = datasource.OBJECTS[name]
    rows = db.query(sql, params, ttl=0, tag={"tile": "contract"})
    live = {r["name"].lower() for r in rows}
    missing = set(columns) - live
    assert not missing, f"{datasource.object_fqn(name)} lacks {sorted(missing)}"
