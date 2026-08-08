"""The seam between routes and data.

OPS_DASHBOARD_DATA selects the implementation: "live" (default) queries Snowflake,
"fixtures" serves recorded JSON from app/fixtures/ and never imports the connector.
Routes call these functions and know nothing about which is active, which is what
lets tests and offline dev run with zero network.
"""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Any

_FIXTURES = Path(__file__).parent / "fixtures"


def _mode() -> str:
    return os.environ.get("OPS_DASHBOARD_DATA", "live")


def _fixture(name: str) -> Any:
    return json.loads((_FIXTURES / f"{name}.json").read_text())


def _iso_utc(value: Any) -> Any:
    """datetime -> ISO-8601 with a trailing Z. The session is already UTC."""
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    return value


def list_sports() -> list[str]:
    if _mode() == "fixtures":
        rows = _fixture("registry")
        return sorted(
            {
                r["target_database"]
                for r in rows
                if r.get("schedule") is not None
            }
        )
    from app import registry

    return registry.sports()


def recent_runs(sport: str | None, limit: int) -> list[dict[str, Any]]:
    """Recent runs newest first, each row tagged with its sport."""
    if _mode() == "fixtures":
        runs = _fixture("runs")["runs"]
        if sport:
            runs = [r for r in runs if r["sport"] == sport]
        return runs[:limit]

    from app import db, registry

    wanted = [sport] if sport else registry.sports()
    # Sport names are validated against the registry by the route, so the
    # identifier interpolation below only ever sees registry-derived values.
    branches = [
        f"SELECT '{s}' AS SPORT, * FROM {registry.runs_view(s)}" for s in wanted
    ]
    sql = (
        "SELECT * FROM (" + " UNION ALL ".join(branches) + ") "
        "ORDER BY RUN_STARTED_AT DESC LIMIT %(limit)s"
    )
    rows = db.query(sql, {"limit": limit})
    return [_normalize(row) for row in rows]


def _normalize(row: dict[str, Any]) -> dict[str, Any]:
    from app import db

    row["row_counts"] = db.parse_variant(row.get("row_counts"))
    row["resources"] = db.parse_variant(row.get("resources"))
    for key in ("run_started_at", "run_ended_at"):
        row[key] = _iso_utc(row.get(key))
    return row


def pipelines() -> list[dict[str, Any]]:
    """Registry pipelines as dicts: name, sport, schedule, enabled."""
    if _mode() == "fixtures":
        return [
            {
                "name": r["name"],
                "sport": r["target_database"],
                "schedule": r["schedule"],
                "enabled": r["enabled"],
            }
            for r in _fixture("registry")
            if r.get("schedule") is not None
        ]
    from app import registry

    return [
        {"name": p.name, "sport": p.sport, "schedule": p.schedule, "enabled": p.enabled}
        for p in registry.load_registry()
    ]


def runs_window(days: int, sport: str | None = None) -> list[dict[str, Any]]:
    """All runs in the last `days` days, every column, tagged with sport."""
    if _mode() == "fixtures":
        runs = _fixture("runs")["runs"]
        return [r for r in runs if sport is None or r["sport"] == sport]

    from app import db, registry

    wanted = [sport] if sport else registry.sports()
    branches = [f"SELECT '{s}' AS SPORT, * FROM {registry.runs_view(s)}" for s in wanted]
    sql = (
        "SELECT * FROM (" + " UNION ALL ".join(branches) + ") "
        "WHERE RUN_STARTED_AT >= DATEADD('day', -%(days)s, CURRENT_TIMESTAMP()) "
        "ORDER BY RUN_STARTED_AT DESC"
    )
    return [_normalize(r) for r in db.query(sql, {"days": days})]


def run_by_query_id(query_id: str) -> dict[str, Any] | None:
    if _mode() == "fixtures":
        runs = _fixture("runs")["runs"]
        return next((r for r in runs if r["query_id"] == query_id), None)

    from app import db, registry

    branches = [
        f"SELECT '{s}' AS SPORT, * FROM {registry.runs_view(s)} WHERE QUERY_ID = %(qid)s"
        for s in registry.sports()
    ]
    rows = db.query(" UNION ALL ".join(branches), {"qid": query_id})
    return _normalize(rows[0]) if rows else None


def pipeline_history(sport: str, name: str, days: int) -> list[dict[str, Any]]:
    if _mode() == "fixtures":
        runs = _fixture("runs")["runs"]
        return [r for r in runs if r["sport"] == sport and r["pipeline"] == name]

    from app import db, registry

    sql = (
        f"SELECT '{sport}' AS SPORT, * FROM {registry.runs_view(sport)} "
        "WHERE PIPELINE = %(name)s "
        "AND RUN_STARTED_AT >= DATEADD('day', -%(days)s, CURRENT_TIMESTAMP()) "
        "ORDER BY RUN_STARTED_AT DESC"
    )
    return [_normalize(r) for r in db.query(sql, {"name": name, "days": days})]


def runs_before(sport: str, name: str, before_iso: str, limit: int) -> list[dict[str, Any]]:
    """Prior runs of one pipeline, for the run-detail context strip."""
    if _mode() == "fixtures":
        runs = [
            r
            for r in _fixture("runs")["runs"]
            if r["sport"] == sport and r["pipeline"] == name and r["run_started_at"] <= before_iso
        ]
        return runs[: limit + 1]

    from app import db, registry

    sql = (
        f"SELECT '{sport}' AS SPORT, * FROM {registry.runs_view(sport)} "
        "WHERE PIPELINE = %(name)s AND RUN_STARTED_AT <= %(before)s "
        "ORDER BY RUN_STARTED_AT DESC LIMIT %(limit)s"
    )
    rows = db.query(sql, {"name": name, "before": before_iso.replace("Z", ""), "limit": limit + 1})
    return [_normalize(r) for r in rows]


def logs(query_id: str, severity: str | None, limit: int) -> list[dict[str, Any]]:
    if _mode() == "fixtures":
        rows = _fixture(f"logs_{query_id}") if (_FIXTURES / f"logs_{query_id}.json").exists() else []
        if severity:
            rows = [r for r in rows if r.get("severity") == severity]
        return rows[:limit]

    from app import db

    sql = (
        "SELECT EVENT_TS, SEVERITY, LOGGER_NAME, CONTAINER_NAME, LOG_FORMAT, MESSAGE "
        "FROM DLT_DB.OPS.V_LOG_LINES WHERE QUERY_ID = %(qid)s "
    )
    params: dict[str, Any] = {"qid": query_id, "limit": limit}
    if severity:
        sql += "AND SEVERITY = %(sev)s "
        params["sev"] = severity
    sql += "ORDER BY EVENT_TS LIMIT %(limit)s"
    rows = db.query(sql, params)
    for row in rows:
        row["event_ts"] = _iso_utc(row.get("event_ts"))
    return rows


def metrics(query_id: str) -> list[dict[str, Any]]:
    if _mode() == "fixtures":
        f = _FIXTURES / f"metrics_{query_id}.json"
        return _fixture(f"metrics_{query_id}") if f.exists() else []

    from app import db

    rows = db.query(
        "SELECT EVENT_TS, METRIC_NAME, METRIC_VALUE, METRIC_UNIT, METRIC_GROUP, "
        "NODE_INSTANCE_FAMILY FROM DLT_DB.OPS.V_METRICS "
        "WHERE QUERY_ID = %(qid)s ORDER BY EVENT_TS",
        {"qid": query_id},
    )
    for row in rows:
        row["event_ts"] = _iso_utc(row.get("event_ts"))
    return rows
