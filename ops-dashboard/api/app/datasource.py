"""The seam between routes and data.

OPS_DASHBOARD_DATA selects the implementation: "live" (default) queries the
configured backend, "fixtures" serves recorded JSON from app/fixtures/ and
never opens a connection. Live default is Postgres app.observability.
Routes call these functions and know nothing about which is active, which is what
lets tests and offline dev run with zero network.

Every function builds its statement once, then branches: live runs it, fixtures
apply the same predicate to the recorded rows. Both record the statement on the
request's trace, so a page shows the SQL it would have run whichever mode served
it. The column lists are explicit rather than SELECT *: they are the contract
the schema fixtures are tested against.
"""

import json
from contextvars import ContextVar
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from app import config

FIXTURES = Path(__file__).parent / "fixtures"

# ---- the request trace: every statement a request built, rendered for display

_TRACE: ContextVar[list[str] | None] = ContextVar("ops_trace", default=None)


def begin_trace() -> None:
    _TRACE.set([])


def record(sql: str, params: dict[str, Any] | None = None) -> None:
    """Append a rendered statement to the request's trace, if one is open."""
    trace = _TRACE.get()
    if trace is None:
        return
    from app import db

    rendered = db.render(sql, params)
    if rendered not in trace:
        trace.append(rendered)


def trace_sql() -> str | None:
    trace = _TRACE.get()
    return "\n\n".join(trace) if trace else None


def _fixture(name: str) -> Any:
    return json.loads((FIXTURES / f"{name}.json").read_text())


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


# ---- column contracts, one per object the dashboard reads

RUN_COLUMNS: tuple[str, ...] = (
    "sport", "pipeline", "task_name", "query_id", "service_name", "compute_pool",
    "run_started_at", "run_ended_at", "duration_s", "container_span_s", "startup_overhead_s",
    "task_state", "dlt_status", "outcome_disagrees", "dlt_record_missing", "rows_loaded",
    "row_counts", "load_id", "resources", "error_text", "exit_status", "log_lines",
    "error_lines", "warning_lines", "unparsed_lines", "metric_samples", "cpu_cores_max",
    "cpu_samples", "cpu_cores_limit", "mem_bytes_max", "mem_samples", "mem_bytes_requested",
    "restarts", "telemetry_available", "container_never_started",
)  # fmt: skip
REGISTRY_COLUMNS: tuple[str, ...] = (
    "name", "schedule", "target_database", "enabled", "updated_at", "source",
)  # fmt: skip
LOG_COLUMNS: tuple[str, ...] = (
    "event_ts", "severity", "logger_name", "container_name", "log_format", "message",
)  # fmt: skip
METRIC_COLUMNS: tuple[str, ...] = (
    "event_ts", "metric_name", "metric_value", "metric_unit", "metric_group",
    "node_instance_family",
)  # fmt: skip
BUILD_COLUMNS: tuple[str, ...] = (
    "sport", "task_name", "run_query_id", "build_id", "state", "error_message", "args",
    "environment", "project_fqn", "drained_loads", "exec_query_id", "scheduled_time",
    "started_at", "completed_time", "duration_s", "n_queries", "n_failed_queries",
    "n_node_queries", "sum_elapsed_ms", "max_elapsed_ms", "sum_bytes_scanned",
    "sum_rows_produced",
)  # fmt: skip
LOAD_COLUMNS: tuple[str, ...] = ("load_id", "pipeline", "status", "inserted_at", "drained_at")
QUERY_COLUMNS: tuple[str, ...] = (
    "query_id", "node", "query_type", "execution_status", "error_message", "start_time",
    "end_time", "total_elapsed_time", "compilation_time", "execution_time",
    "queued_overload_time", "bytes_scanned", "rows_produced", "rows_inserted",
    "warehouse_name", "stats_captured",
)  # fmt: skip
OPERATOR_COLUMNS: tuple[str, ...] = (
    "step_id", "operator_id", "parent_operators", "operator_type", "operator_statistics",
    "execution_time_breakdown", "operator_attributes",
)  # fmt: skip
HEADLINE_COLUMNS: tuple[str, ...] = (
    "generated_at", "day", "seq", "severity", "kind", "entity", "headline", "detail", "model",
)  # fmt: skip

# object name -> (Snowflake FQN, columns); the contract test reads this
OBJECTS: dict[str, tuple[str, tuple[str, ...]]] = {
    "pipeline_runs": ("DLT_DB.OPS.PIPELINE_RUNS", RUN_COLUMNS),
    "pipeline_registry": ("DLT_DB.OPS.PIPELINE_REGISTRY", REGISTRY_COLUMNS),
    "v_log_lines": ("DLT_DB.OPS.V_LOG_LINES", LOG_COLUMNS),
    "v_metrics": ("DLT_DB.OPS.V_METRICS", METRIC_COLUMNS),
    "v_dbt_runs": ("DLT_DB.OPS.V_DBT_RUNS", BUILD_COLUMNS),
    "dbt_trigger_loads": ("NFL_PROD_DB.OPS.DBT_TRIGGER_LOADS", LOAD_COLUMNS),
    "dbt_query_log": ("DLT_DB.OPS.DBT_QUERY_LOG", QUERY_COLUMNS),
    "dbt_query_operator_stats": ("DLT_DB.OPS.DBT_QUERY_OPERATOR_STATS", OPERATOR_COLUMNS),
    "headlines": ("DLT_DB.OPS.HEADLINES", HEADLINE_COLUMNS),
}

# obs_to_postgres copies the tables the views sit on, not the views.
# dbt_trigger_loads is per-sport in <SPORT>_PROD_DB.OPS and is not copied.
PG_OBJECTS: dict[str, str] = {
    "pipeline_runs": "pipeline_runs",
    "pipeline_registry": "pipeline_registry",
    "v_log_lines": "log_lines",
    "v_metrics": "metric_samples",
    "v_dbt_runs": "dbt_runs",
    "dbt_query_log": "dbt_query_log",
    "dbt_query_operator_stats": "dbt_query_operator_stats",
    "headlines": "headlines",
}


def object_fqn(name: str) -> str | None:
    """Live store FQN, or None when this object is not on the postgres copy."""
    snow, _ = OBJECTS[name]
    if not config.is_postgres():
        return snow
    table = PG_OBJECTS.get(name)
    if table is None:
        return None
    return f"{config.obs_schema()}.{table}"


def _from(name: str) -> str:
    fqn = object_fqn(name)
    if fqn is None:
        raise RuntimeError(f"{name} is not in app.observability")
    return fqn


def _cols(columns: tuple[str, ...]) -> str:
    return ", ".join(c.upper() for c in columns)


def _since_days(bind: str) -> str:
    """Timestamp *bind* days ago. DATEADD is Snowflake-only."""
    if config.is_postgres():
        return f"(now() - make_interval(days => %({bind})s))"
    return f"DATEADD('day', -%({bind})s, CURRENT_TIMESTAMP())"


def describe_sql(name: str) -> tuple[str, dict[str, Any]] | None:
    """Statement that lists an object's columns, or None if it is not on this store."""
    fqn = object_fqn(name)
    if fqn is None:
        return None
    if config.is_snowflake():
        return f"DESCRIBE TABLE {fqn}", {}
    schema, table = fqn.split(".", 1)
    sql = (
        "select column_name as name, data_type as type\n"
        "from information_schema.columns\n"
        "where table_schema = %(schema)s and table_name = %(table)s\n"
        "order by ordinal_position"
    )
    return sql, {"schema": schema, "table": table}


def _run_rows(fixture: str = "runs") -> list[dict[str, Any]]:
    return _fixture(fixture)["runs"]


# ---- registry


def list_sports() -> list[str]:
    if config.is_fixtures():
        record(registry_sql())
        rows = _fixture("registry")
        return sorted({r["target_database"] for r in rows if r.get("schedule") is not None})
    from app import registry

    return registry.sports()


def registry_sql() -> str:
    return (
        f"SELECT {_cols(REGISTRY_COLUMNS)} FROM {_from('pipeline_registry')} "
        "WHERE SCHEDULE IS NOT NULL ORDER BY TARGET_DATABASE, NAME"
    )


def first_runs_sql() -> str:
    return (
        f"SELECT PIPELINE, MIN(RUN_STARTED_AT) AS FIRST_RUN_AT "
        f"FROM {_from('pipeline_runs')} GROUP BY PIPELINE"
    )


def first_runs() -> dict[str, str]:
    """Pipeline -> ISO time of its earliest recorded run, over the whole table."""
    if config.is_fixtures():
        record(first_runs_sql())
        first: dict[str, str] = {}
        for r in _run_rows():
            at = r["run_started_at"]
            if r["pipeline"] not in first or at < first[r["pipeline"]]:
                first[r["pipeline"]] = at
        return first
    from app import db

    rows = db.query(first_runs_sql(), tag={"tile": "first_runs"})
    return {r["pipeline"]: _iso_utc(r["first_run_at"]) for r in rows if r.get("first_run_at")}


def live_from(updated_at: str | None, first_run_at: str | None) -> str | None:
    """When a pipeline's schedule starts to count, as an ISO time.

    A cron expanded over a day produces slots the Task may not have existed
    for. The registry row's `updated_at` is the last sync, which for a
    pipeline that has never run is the deploy that created it; the earliest
    run ever is the other witness. The earlier of the two is the floor: slots
    before it are not no-shows, they are before the Task existed. An old
    pipeline floors at its first run long ago and is unaffected.
    """
    candidates = [t for t in (updated_at, first_run_at) if t]
    return min(candidates) if candidates else None


def pipelines() -> list[dict[str, Any]]:
    """Registry pipelines as dicts: name, sport, schedule, enabled, live_from."""
    if config.is_fixtures():
        record(registry_sql())
        first = first_runs()
        return [
            {
                "name": r["name"],
                "sport": r["target_database"],
                "schedule": r["schedule"],
                "enabled": r["enabled"],
                "source": r.get("source"),
                "live_from": live_from(r.get("updated_at"), first.get(r["name"])),
            }
            for r in _fixture("registry")
            if r.get("schedule") is not None
        ]
    from app import registry

    first = registry.first_runs()
    return [
        {
            "name": p.name,
            "sport": p.sport,
            "schedule": p.schedule,
            "enabled": p.enabled,
            "source": p.source,
            "live_from": live_from(p.updated_at, first.get(p.name)),
        }
        for p in registry.load_registry()
    ]


# ---- pipeline runs


def _normalize(row: dict[str, Any]) -> dict[str, Any]:
    from app import db

    row["row_counts"] = db.parse_variant(row.get("row_counts"))
    row["resources"] = db.parse_variant(row.get("resources"))
    for key in ("run_started_at", "run_ended_at"):
        row[key] = _iso_utc(row.get(key))
    return row


def _runs(sql: str, params: dict[str, Any], tag: str) -> list[dict[str, Any]]:
    from app import db

    return [_normalize(r) for r in db.query(sql, params, tag={"tile": tag})]


def recent_runs(sport: str | None, limit: int) -> list[dict[str, Any]]:
    """Recent runs newest first, each row tagged with its sport."""
    # One table for every sport (SPORT holds the uppercase registry stem), so
    # sport scoping is a bind, not a UNION of per-sport views.
    sql = f"SELECT {_cols(RUN_COLUMNS)} FROM {_from('pipeline_runs')} "
    params: dict[str, Any] = {"limit": limit}
    if sport:
        sql += "WHERE SPORT = %(sport)s "
        params["sport"] = sport
    sql += "ORDER BY RUN_STARTED_AT DESC LIMIT %(limit)s"
    if config.is_fixtures():
        record(sql, params)
        runs = _run_rows()
        if sport:
            runs = [r for r in runs if r["sport"] == sport]
        return runs[:limit]
    return _runs(sql, params, "runs")


def run_by_query_id(query_id: str) -> dict[str, Any] | None:
    sql = f"SELECT {_cols(RUN_COLUMNS)} FROM {_from('pipeline_runs')} WHERE QUERY_ID = %(qid)s"
    params = {"qid": query_id}
    if config.is_fixtures():
        record(sql, params)
        return next((r for r in _run_rows() if r["query_id"] == query_id), None)
    rows = _runs(sql, params, "run")
    return rows[0] if rows else None


def pipeline_history(sport: str, name: str, days: int) -> list[dict[str, Any]]:
    sql = (
        f"SELECT {_cols(RUN_COLUMNS)} FROM {_from('pipeline_runs')} "
        "WHERE SPORT = %(sport)s AND PIPELINE = %(name)s "
        f"AND RUN_STARTED_AT >= {_since_days('days')} "
        "ORDER BY RUN_STARTED_AT DESC"
    )
    params = {"sport": sport, "name": name, "days": days}
    if config.is_fixtures():
        record(sql, params)
        return [r for r in _run_rows() if r["sport"] == sport and r["pipeline"] == name]
    return _runs(sql, params, "pipeline")


def runs_before(sport: str, name: str, before_iso: str, limit: int) -> list[dict[str, Any]]:
    """Prior runs of one pipeline, for the run-detail context strip."""
    sql = (
        f"SELECT {_cols(RUN_COLUMNS)} FROM {_from('pipeline_runs')} "
        "WHERE SPORT = %(sport)s AND PIPELINE = %(name)s AND RUN_STARTED_AT <= %(before)s "
        "ORDER BY RUN_STARTED_AT DESC LIMIT %(limit)s"
    )
    params = {
        "sport": sport,
        "name": name,
        "before": before_iso.replace("Z", ""),
        "limit": limit + 1,
    }
    if config.is_fixtures():
        record(sql, params)
        runs = [
            r
            for r in _run_rows()
            if r["sport"] == sport and r["pipeline"] == name and r["run_started_at"] <= before_iso
        ]
        return runs[: limit + 1]
    return _runs(sql, params, "run_history")


def runs_between(start: datetime, end: datetime, sport: str | None) -> list[dict[str, Any]]:
    """Runs with start <= RUN_STARTED_AT < end, newest first.

    Bounds are explicit UTC datetimes rather than a now-anchored day count so
    the slate can be rewound to any day, and so fixture mode applies the SAME
    window as live. Bound strings carry milliseconds so the lexicographic
    compare against the fixtures' .SSSZ timestamps is exact at day edges.
    """
    start_iso = start.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000") + "Z"
    end_iso = end.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000") + "Z"
    sql = (
        f"SELECT {_cols(RUN_COLUMNS)} FROM {_from('pipeline_runs')} "
        "WHERE RUN_STARTED_AT >= %(start)s AND RUN_STARTED_AT < %(end)s "
    )
    params: dict[str, Any] = {"start": start_iso.replace("Z", ""), "end": end_iso.replace("Z", "")}
    if sport:
        sql += "AND SPORT = %(sport)s "
        params["sport"] = sport
    sql += "ORDER BY RUN_STARTED_AT DESC"
    if config.is_fixtures():
        record(sql, params)
        runs = [r for r in _run_rows() if start_iso <= r["run_started_at"] < end_iso]
        if sport:
            runs = [r for r in runs if r["sport"] == sport]
        return sorted(runs, key=lambda r: r["run_started_at"], reverse=True)
    return _runs(sql, params, "runs_window")


# ---- logs and metrics


def logs(query_id: str, severity: str | None, limit: int) -> list[dict[str, Any]]:
    sql = f"SELECT {_cols(LOG_COLUMNS)} FROM {_from('v_log_lines')} WHERE QUERY_ID = %(qid)s "
    params: dict[str, Any] = {"qid": query_id, "limit": limit}
    if severity:
        sql += "AND SEVERITY = %(sev)s "
        params["sev"] = severity
    sql += "ORDER BY EVENT_TS LIMIT %(limit)s"
    if config.is_fixtures():
        record(sql, params)
        path = FIXTURES / f"logs_{query_id}.json"
        rows = _fixture(f"logs_{query_id}") if path.exists() else []
        if severity:
            rows = [r for r in rows if r.get("severity") == severity]
        return rows[:limit]
    from app import db

    rows = db.query(sql, params, tag={"tile": "logs"})
    for row in rows:
        row["event_ts"] = _iso_utc(row.get("event_ts"))
    return rows


def metrics(query_id: str) -> list[dict[str, Any]]:
    sql = (
        f"SELECT {_cols(METRIC_COLUMNS)} FROM {_from('v_metrics')} "
        "WHERE QUERY_ID = %(qid)s ORDER BY EVENT_TS"
    )
    params = {"qid": query_id}
    if config.is_fixtures():
        record(sql, params)
        path = FIXTURES / f"metrics_{query_id}.json"
        return _fixture(f"metrics_{query_id}") if path.exists() else []
    from app import db

    rows = db.query(sql, params, tag={"tile": "metrics"})
    for row in rows:
        row["event_ts"] = _iso_utc(row.get("event_ts"))
    return rows


# ---- dbt builds


def _normalize_build(row: dict[str, Any]) -> dict[str, Any]:
    for key in ("scheduled_time", "started_at", "completed_time"):
        row[key] = _iso_utc(row.get(key))
    return row


def dbt_builds(sport: str | None, limit: int) -> list[dict[str, Any]]:
    """Event-driven dbt build attempts, newest first. V_DBT_RUNS spells sport
    lowercase ('nfl'), unlike the registry stems ('NFL'); the route lowercases
    before calling, so nothing here re-maps."""
    sql = f"SELECT {_cols(BUILD_COLUMNS)} FROM {_from('v_dbt_runs')} "
    params: dict[str, Any] = {"limit": limit}
    if sport:
        sql += "WHERE SPORT = %(sport)s "
        params["sport"] = sport
    sql += "ORDER BY STARTED_AT DESC LIMIT %(limit)s"
    if config.is_fixtures():
        record(sql, params)
        rows = _fixture("dbt_builds")
        if sport:
            rows = [r for r in rows if r["sport"] == sport]
        return rows[:limit]
    from app import db

    return [_normalize_build(r) for r in db.query(sql, params, tag={"tile": "dbt_builds"})]


def dbt_build_by_id(build_id: str) -> dict[str, Any] | None:
    """One build attempt. BUILD_ID is null for runs that died before the proc
    recorded one, so those rows are unreachable here by construction."""
    sql = (
        f"SELECT {_cols(BUILD_COLUMNS)} FROM {_from('v_dbt_runs')} WHERE BUILD_ID = %(bid)s "
        "ORDER BY STARTED_AT DESC LIMIT 1"
    )
    params = {"bid": build_id}
    if config.is_fixtures():
        record(sql, params)
        return next((r for r in _fixture("dbt_builds") if r.get("build_id") == build_id), None)
    from app import db

    rows = db.query(sql, params, tag={"tile": "dbt_build"})
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
    if config.is_postgres():
        # Per-sport table, not in the observability copy.
        return []
    start = _shift_iso(started_at, -120)
    # sport comes from a V_DBT_RUNS row, never from the request path, so the
    # database name below is view-derived rather than caller-supplied.
    sql = (
        f"SELECT {_cols(LOAD_COLUMNS)} FROM {sport.upper()}_PROD_DB.OPS.DBT_TRIGGER_LOADS "
        "WHERE DRAINED_AT >= %(start)s::TIMESTAMP_LTZ "
        "AND DRAINED_AT <= %(end)s::TIMESTAMP_LTZ ORDER BY DRAINED_AT"
    )
    params = {"start": start.replace("Z", ""), "end": completed_time.replace("Z", "")}
    if config.is_fixtures():
        record(sql, params)
        rows = _fixture("dbt_loads").get(sport, [])
        return [r for r in rows if start <= (r.get("drained_at") or "") <= completed_time]
    from app import db

    rows = db.query(sql, params, tag={"tile": "dbt_loads"})
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
    sql = (
        f"SELECT {_cols(QUERY_COLUMNS)} FROM {_from('dbt_query_log')} WHERE BUILD_ID = %(bid)s "
        "ORDER BY TOTAL_ELAPSED_TIME DESC LIMIT %(limit)s"
    )
    params = {"bid": build_id, "limit": limit}
    if config.is_fixtures():
        record(sql, params)
        return _fixture("dbt_queries").get(build_id, [])[:limit]
    from app import db

    rows = db.query(sql, params, tag={"tile": "dbt_queries"})
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
    sql = (
        f"SELECT {_cols(OPERATOR_COLUMNS)} FROM {_from('dbt_query_operator_stats')} "
        "WHERE QUERY_ID = %(qid)s ORDER BY STEP_ID, OPERATOR_ID"
    )
    params = {"qid": query_id}
    if config.is_fixtures():
        record(sql, params)
        return _fixture("dbt_operators").get(query_id, [])
    from app import db

    rows = db.query(sql, params, tag={"tile": "dbt_operators"})
    for row in rows:
        # ARRAY and VARIANT both arrive as JSON text; the payload must carry
        # real structures so the UI can walk the operator tree.
        for key in _OPERATOR_VARIANTS:
            row[key] = db.parse_variant(row.get(key))
    return rows


# ---- the AI wire


def headlines_for_day(day: date) -> list[dict[str, Any]]:
    """The AI wire: rows of the newest DAY at or before *day*, in SEQ order.

    Upstream is best-effort (SP_HEADLINES swallows its own failures), so days
    with no rows are a normal state, not an error. The fallback lives HERE, in
    one place with identical semantics in both modes, so fixture and live can
    never drift: newest day <= requested, else nothing.
    """
    sql = (
        f"SELECT {_cols(HEADLINE_COLUMNS)} FROM {_from('headlines')} "
        f"WHERE DAY = (SELECT MAX(DAY) FROM {_from('headlines')} WHERE DAY <= %(day)s) "
        "ORDER BY SEQ"
    )
    params = {"day": day.isoformat()}
    if config.is_fixtures():
        record(sql, params)
        rows = [r for r in _fixture("headlines") if r["day"] <= day.isoformat()]
        if not rows:
            return []
        served = max(r["day"] for r in rows)
        return sorted((r for r in rows if r["day"] == served), key=lambda r: r["seq"])
    from app import db

    rows = db.query(sql, params, tag={"tile": "headlines"})
    for row in rows:
        row["generated_at"] = _iso_utc(row.get("generated_at"))
        d = row.get("day")
        row["day"] = d.isoformat() if hasattr(d, "isoformat") else d
    return rows
