"""The seam between routes and data.

OPS_DASHBOARD_DATA selects the implementation: "live" (default) queries Snowflake,
"fixtures" serves recorded JSON from app/fixtures/ and never imports the connector.
Routes call these functions and know nothing about which is active, which is what
lets tests and offline dev run with zero network.
"""

import json
import os
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

_FIXTURES = Path(__file__).parent / "fixtures"


def _mode() -> str:
    return os.environ.get("OPS_DASHBOARD_DATA", "live")


def _fixture(name: str) -> Any:
    return json.loads((_FIXTURES / f"{name}.json").read_text())


def _iso_utc(value: Any) -> Any:
    """datetime -> ISO-8601 with a trailing Z.

    TIMESTAMP_LTZ arrives in the session zone, which db.py pins to UTC, so the
    shift is a no-op there. TIMESTAMP_TZ does not: it keeps whatever offset the
    writer had, and the dbt tables mix -07:00 and +00:00 rows in one column, so
    formatting without converting would stamp a Z on local wall time. Naive
    values (TIMESTAMP_NTZ) are left alone; the writers store UTC in them.
    """
    if isinstance(value, datetime):
        if value.tzinfo is not None:
            value = value.astimezone(UTC)
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

    from app import db

    # One table for every sport (DLT_DB.OPS.PIPELINE_RUNS, SPORT column holds
    # the uppercase registry stem), so sport scoping is a bind, not a UNION of
    # per-sport views.
    sql = "SELECT * FROM DLT_DB.OPS.PIPELINE_RUNS "
    params: dict[str, Any] = {"limit": limit}
    if sport:
        sql += "WHERE SPORT = %(sport)s "
        params["sport"] = sport
    sql += "ORDER BY RUN_STARTED_AT DESC LIMIT %(limit)s"
    rows = db.query(sql, params)
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

    from app import db

    sql = (
        "SELECT * FROM DLT_DB.OPS.PIPELINE_RUNS "
        "WHERE RUN_STARTED_AT >= DATEADD('day', -%(days)s, CURRENT_TIMESTAMP()) "
    )
    params: dict[str, Any] = {"days": days}
    if sport:
        sql += "AND SPORT = %(sport)s "
        params["sport"] = sport
    sql += "ORDER BY RUN_STARTED_AT DESC"
    return [_normalize(r) for r in db.query(sql, params)]


def run_by_query_id(query_id: str) -> dict[str, Any] | None:
    if _mode() == "fixtures":
        runs = _fixture("runs")["runs"]
        return next((r for r in runs if r["query_id"] == query_id), None)

    from app import db

    rows = db.query(
        "SELECT * FROM DLT_DB.OPS.PIPELINE_RUNS WHERE QUERY_ID = %(qid)s",
        {"qid": query_id},
    )
    return _normalize(rows[0]) if rows else None


def pipeline_history(sport: str, name: str, days: int) -> list[dict[str, Any]]:
    if _mode() == "fixtures":
        runs = _fixture("runs")["runs"]
        return [r for r in runs if r["sport"] == sport and r["pipeline"] == name]

    from app import db

    sql = (
        "SELECT * FROM DLT_DB.OPS.PIPELINE_RUNS "
        "WHERE SPORT = %(sport)s AND PIPELINE = %(name)s "
        "AND RUN_STARTED_AT >= DATEADD('day', -%(days)s, CURRENT_TIMESTAMP()) "
        "ORDER BY RUN_STARTED_AT DESC"
    )
    return [_normalize(r) for r in db.query(sql, {"sport": sport, "name": name, "days": days})]


def runs_before(sport: str, name: str, before_iso: str, limit: int) -> list[dict[str, Any]]:
    """Prior runs of one pipeline, for the run-detail context strip."""
    if _mode() == "fixtures":
        runs = [
            r
            for r in _fixture("runs")["runs"]
            if r["sport"] == sport and r["pipeline"] == name and r["run_started_at"] <= before_iso
        ]
        return runs[: limit + 1]

    from app import db

    sql = (
        "SELECT * FROM DLT_DB.OPS.PIPELINE_RUNS "
        "WHERE SPORT = %(sport)s AND PIPELINE = %(name)s AND RUN_STARTED_AT <= %(before)s "
        "ORDER BY RUN_STARTED_AT DESC LIMIT %(limit)s"
    )
    rows = db.query(
        sql,
        {"sport": sport, "name": name, "before": before_iso.replace("Z", ""), "limit": limit + 1},
    )
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


def dbt_builds(sport: str | None, limit: int) -> list[dict[str, Any]]:
    """Event-driven dbt build attempts, newest first.

    V_DBT_RUNS spells sport lowercase ('nfl'), unlike the registry-derived
    database stems ('NFL') the dlt endpoints use; the route lowercases before
    calling, so nothing here re-maps.
    """
    if _mode() == "fixtures":
        rows = _fixture("dbt_builds")
        if sport:
            rows = [r for r in rows if r["sport"] == sport]
        return rows[:limit]

    from app import db

    sql = "SELECT * FROM DLT_DB.OPS.V_DBT_RUNS "
    params: dict[str, Any] = {"limit": limit}
    if sport:
        sql += "WHERE SPORT = %(sport)s "
        params["sport"] = sport
    sql += "ORDER BY STARTED_AT DESC LIMIT %(limit)s"
    return [_normalize_build(r) for r in db.query(sql, params)]


def _normalize_build(row: dict[str, Any]) -> dict[str, Any]:
    for key in ("scheduled_time", "started_at", "completed_time"):
        row[key] = _iso_utc(row.get(key))
    return row


def dbt_build_by_id(build_id: str) -> dict[str, Any] | None:
    """One build attempt. BUILD_ID is null for runs that died before the proc
    recorded one, so those rows are unreachable here by construction."""
    if _mode() == "fixtures":
        rows = _fixture("dbt_builds")
        return next((r for r in rows if r.get("build_id") == build_id), None)

    from app import db

    rows = db.query(
        "SELECT * FROM DLT_DB.OPS.V_DBT_RUNS WHERE BUILD_ID = %(bid)s "
        "ORDER BY STARTED_AT DESC LIMIT 1",
        {"bid": build_id},
    )
    return _normalize_build(rows[0]) if rows else None


def dbt_build_loads(sport: str, started_at: Any, completed_time: Any) -> list[dict[str, Any]]:
    """The dlt loads a build drained, from the sport's DBT_TRIGGER_LOADS.

    DBT_TRIGGER_LOADS carries no build_id: the proc drains the stream into it
    before it knows one, so the only link is time. The 120s lead-in absorbs the
    gap between task start and the drain DML. A build with no completion time
    has no closed window, hence no loads rather than a guess.
    """
    if not started_at or not completed_time:
        return []
    start = _shift_iso(started_at, -120)

    if _mode() == "fixtures":
        rows = _fixture("dbt_loads").get(sport, [])
        return [r for r in rows if start <= (r.get("drained_at") or "") <= completed_time]

    from app import db

    # sport comes from a V_DBT_RUNS row, never from the request path, so the
    # database name below is view-derived rather than caller-supplied.
    sql = (
        f"SELECT LOAD_ID, PIPELINE, STATUS, INSERTED_AT, DRAINED_AT "
        f"FROM {sport.upper()}_PROD_DB.OPS.DBT_TRIGGER_LOADS "
        "WHERE DRAINED_AT >= %(start)s::TIMESTAMP_LTZ "
        "AND DRAINED_AT <= %(end)s::TIMESTAMP_LTZ "
        "ORDER BY DRAINED_AT"
    )
    rows = db.query(sql, {"start": start.replace("Z", ""), "end": completed_time.replace("Z", "")})
    for row in rows:
        row["inserted_at"] = _iso_utc(row.get("inserted_at"))
        row["drained_at"] = _iso_utc(row.get("drained_at"))
    return rows


def _shift_iso(value: str, seconds: int) -> str:
    moved = datetime.fromisoformat(value) + timedelta(seconds=seconds)
    return moved.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def dbt_queries(build_id: str, limit: int) -> list[dict[str, Any]]:
    """Per-node queries of one build, slowest first: the point of the page is
    which node cost the time, so the limit truncates the tail, not the head."""
    if _mode() == "fixtures":
        return _fixture("dbt_queries").get(build_id, [])[:limit]

    from app import db

    rows = db.query(
        "SELECT QUERY_ID, NODE, QUERY_TYPE, EXECUTION_STATUS, ERROR_MESSAGE, START_TIME, "
        "END_TIME, TOTAL_ELAPSED_TIME, COMPILATION_TIME, EXECUTION_TIME, QUEUED_OVERLOAD_TIME, "
        "BYTES_SCANNED, ROWS_PRODUCED, ROWS_INSERTED, WAREHOUSE_NAME, STATS_CAPTURED "
        "FROM DLT_DB.OPS.DBT_QUERY_LOG WHERE BUILD_ID = %(bid)s "
        "ORDER BY TOTAL_ELAPSED_TIME DESC LIMIT %(limit)s",
        {"bid": build_id, "limit": limit},
    )
    for row in rows:
        row["start_time"] = _iso_utc(row.get("start_time"))
        row["end_time"] = _iso_utc(row.get("end_time"))
    return rows


_OPERATOR_VARIANTS = (
    "parent_operators",
    "operator_statistics",
    "execution_time_breakdown",
    "operator_attributes",
)


def dbt_operators(query_id: str) -> list[dict[str, Any]]:
    """Query-profile operator tree for one query. Only queries the harvester
    profiled have rows; STATS_CAPTURED on the query row says which."""
    if _mode() == "fixtures":
        return _fixture("dbt_operators").get(query_id, [])

    from app import db

    rows = db.query(
        "SELECT STEP_ID, OPERATOR_ID, PARENT_OPERATORS, OPERATOR_TYPE, OPERATOR_STATISTICS, "
        "EXECUTION_TIME_BREAKDOWN, OPERATOR_ATTRIBUTES "
        "FROM DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS WHERE QUERY_ID = %(qid)s "
        "ORDER BY STEP_ID, OPERATOR_ID",
        {"qid": query_id},
    )
    for row in rows:
        # ARRAY and VARIANT both arrive as JSON text; the payload must carry
        # real structures so the UI can walk the operator tree.
        for key in _OPERATOR_VARIANTS:
            row[key] = db.parse_variant(row.get(key))
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


def headlines_for_day(day: date) -> list[dict[str, Any]]:
    """The AI wire: rows of the newest DAY at or before *day*, in SEQ order.

    Upstream is best-effort (SP_HEADLINES swallows its own failures), so days
    with no rows are a normal state, not an error. The fallback lives HERE, in
    one place with identical semantics in both modes, so fixture and live can
    never drift: newest day <= requested, else nothing.
    """
    if _mode() == "fixtures":
        rows = [r for r in _fixture("headlines") if r["day"] <= day.isoformat()]
        if not rows:
            return []
        served = max(r["day"] for r in rows)
        return sorted((r for r in rows if r["day"] == served), key=lambda r: r["seq"])

    from app import db

    sql = (
        "SELECT GENERATED_AT, DAY, SEQ, SEVERITY, KIND, ENTITY, HEADLINE, DETAIL, MODEL "
        "FROM DLT_DB.OPS.HEADLINES "
        "WHERE DAY = (SELECT MAX(DAY) FROM DLT_DB.OPS.HEADLINES WHERE DAY <= %(day)s) "
        "ORDER BY SEQ"
    )
    rows = db.query(sql, {"day": day.isoformat()})
    for row in rows:
        row["generated_at"] = _iso_utc(row.get("generated_at"))
        d = row.get("day")
        row["day"] = d.isoformat() if hasattr(d, "isoformat") else d
    return rows


def runs_between(start: datetime, end: datetime, sport: str | None) -> list[dict[str, Any]]:
    """Runs with start <= RUN_STARTED_AT < end, newest first.

    Bounds are explicit UTC datetimes rather than a now-anchored window so the
    slate can be rewound to any day. Fixture mode applies the SAME bounds:
    runs_window's fixture path ignores its days argument entirely, a trap this
    function exists to avoid. Bound strings carry milliseconds so the
    lexicographic compare against the fixtures' .SSSZ timestamps is exact at
    day edges.
    """
    start_iso = start.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000") + "Z"
    end_iso = end.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000") + "Z"

    if _mode() == "fixtures":
        runs = [r for r in _fixture("runs")["runs"] if start_iso <= r["run_started_at"] < end_iso]
        if sport:
            runs = [r for r in runs if r["sport"] == sport]
        return sorted(runs, key=lambda r: r["run_started_at"], reverse=True)

    from app import db

    sql = (
        "SELECT * FROM DLT_DB.OPS.PIPELINE_RUNS "
        "WHERE RUN_STARTED_AT >= %(start)s AND RUN_STARTED_AT < %(end)s "
    )
    params: dict[str, Any] = {
        "start": start_iso.replace("Z", ""),
        "end": end_iso.replace("Z", ""),
    }
    if sport:
        sql += "AND SPORT = %(sport)s "
        params["sport"] = sport
    sql += "ORDER BY RUN_STARTED_AT DESC"
    return [_normalize(r) for r in db.query(sql, params)]
