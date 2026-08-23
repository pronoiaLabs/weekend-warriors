"""Record fixtures from DLT_DB.OPS through app.db.query, so they have exactly the
shape the live datasource functions return.

    cd ops-dashboard/api
    uv run python scripts/capture_fixtures.py schema     # DESCRIBE of every object the
                                                         # datasource reads -> fixtures/schema/
    uv run python scripts/capture_fixtures.py rows       # a fresh snapshot of every row
                                                         # fixture (see SNAPSHOT below)

`schema` is safe to rerun any time: it changes nothing the tests pin. `rows`
replaces the frozen snapshot the endpoint tests assert against (dates, counts,
query ids), so rerun it only when you mean to re-pin tests/conftest.py's
SNAPSHOT_NOW and the values in tests/test_*.py to the new era.
"""

import datetime as dt
import decimal
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import datasource, db

FIXTURES = datasource.FIXTURES

# the rows snapshot: how far back, and how many builds and runs
SNAPSHOT = {"run_days": 14, "runs": 400, "builds": 50, "logs_runs": 1, "metrics_runs": 1}


def _default(value: object) -> object:
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, dt.datetime | dt.date):
        return datasource._iso_utc(value) if isinstance(value, dt.datetime) else value.isoformat()
    raise TypeError(f"unserialisable {type(value).__name__}")


def _write(name: str, payload: Any) -> None:
    out = FIXTURES / f"{name}.json"
    out.write_text(json.dumps(payload, default=_default, indent=2) + "\n")
    size = out.stat().st_size // 1024
    print(f"{out.relative_to(FIXTURES.parents[1])}: {size} KiB")


def schema() -> None:
    (FIXTURES / "schema").mkdir(exist_ok=True)
    for name, (fqn, _) in datasource.OBJECTS.items():
        rows = db.query(f"DESCRIBE TABLE {fqn}", ttl=0, tag={"tile": "capture"})
        spec = {
            "object": fqn,
            "columns": [
                {"name": r["name"].lower(), "type": r["type"], "nullable": r["null?"] == "Y"}
                for r in rows
            ],
        }
        _write(f"schema/{name}", spec)


def rows() -> None:
    now = dt.datetime.now(dt.UTC)
    start = now - dt.timedelta(days=SNAPSHOT["run_days"])
    runs = datasource.runs_between(start, now + dt.timedelta(minutes=1), None)[: SNAPSHOT["runs"]]
    _write("runs", {"captured_at": now.isoformat(), "runs": runs})
    _write(
        "registry",
        db.query(datasource.registry_sql(), ttl=0, tag={"tile": "capture"}),
    )
    builds = datasource.dbt_builds(None, SNAPSHOT["builds"])
    _write("dbt_builds", builds)
    loads: dict[str, list[dict[str, Any]]] = {}
    queries: dict[str, list[dict[str, Any]]] = {}
    operators: dict[str, list[dict[str, Any]]] = {}
    for b in builds:
        if not b.get("build_id"):
            continue
        loads.setdefault(b["sport"], []).extend(
            datasource.dbt_build_loads(b["sport"], b.get("started_at"), b.get("completed_time"))
        )
        qs = datasource.dbt_queries(b["build_id"], 100)
        queries[b["build_id"]] = qs
        for q in qs[:3]:
            if q.get("stats_captured"):
                operators[q["query_id"]] = datasource.dbt_operators(q["query_id"])
    _write("dbt_loads", loads)
    _write("dbt_queries", queries)
    _write("dbt_operators", operators)
    _write(
        "headlines",
        db.query(
            f"SELECT {datasource._cols(datasource.HEADLINE_COLUMNS)} FROM {datasource._from('headlines')} "
            "WHERE DAY >= %(since)s ORDER BY DAY, SEQ",
            {"since": start.date().isoformat()},
            ttl=0,
            tag={"tile": "capture"},
        ),
    )
    # logs and metrics for the most recent failed run and the most recent success
    picked: list[dict[str, Any]] = []
    for state in ("FAILED", "SUCCEEDED"):
        hit = next((r for r in runs if (r.get("task_state") or "").upper() == state), None)
        if hit:
            picked.append(hit)
    for r in picked:
        _write(f"logs_{r['query_id']}", datasource.logs(r["query_id"], None, 2000))
        _write(f"metrics_{r['query_id']}", datasource.metrics(r["query_id"]))


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "schema"
    {"schema": schema, "rows": rows}[what]()
