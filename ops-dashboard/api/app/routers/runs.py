"""Runs: the recent list, one run, and its evidence (logs, metrics, row counts)."""

from typing import Any

from fastapi import APIRouter, Query

from app import assemble, datasource
from app.routers.common import check_sport, find_run, traced

router = APIRouter(tags=["runs"])

# The two headline dot strips. Everything else appears in the summary table:
# collect everything, filter downstream.
_STRIP_METRICS = {"container.cpu.usage": "cpu", "container.memory.usage": "memory"}


def shape_metrics(run: dict[str, Any], samples: list[dict[str, Any]]) -> dict[str, Any]:
    strips: dict[str, Any] = {
        "cpu": {"points": [], "limit": run.get("cpu_cores_limit"), "unit": "core"},
        "memory": {"points": [], "limit": run.get("mem_bytes_requested"), "unit": "byte"},
    }
    summary: dict[str, dict[str, Any]] = {}
    for s in samples:
        name = s["metric_name"]
        agg = summary.setdefault(
            name,
            {
                "samples": 0,
                "max": None,
                "unit": s.get("metric_unit"),
                "group": s.get("metric_group"),
            },
        )
        agg["samples"] += 1
        value = s.get("metric_value")
        if value is not None and (agg["max"] is None or value > agg["max"]):
            agg["max"] = value
        strip_key = _STRIP_METRICS.get(name)
        if strip_key:
            strips[strip_key]["points"].append({"at": s["event_ts"], "value": value})
    return {
        "query_id": run.get("query_id"),
        "metric_samples": run.get("metric_samples"),
        "cpu_samples": run.get("cpu_samples"),
        "mem_samples": run.get("mem_samples"),
        "telemetry_available": run.get("telemetry_available"),
        "container_never_started": run.get("container_never_started"),
        "node_instance_family": next(
            (s.get("node_instance_family") for s in samples if s.get("node_instance_family")), None
        ),
        "strips": strips,
        "metrics": summary,
    }


@router.get("/api/runs")
def runs(sport: str = Query("all"), limit: int = Query(50, ge=1, le=500)) -> dict[str, Any]:
    wanted = check_sport(sport)
    return traced(
        {"sports": datasource.list_sports(), "runs": datasource.recent_runs(wanted, limit)}
    )


@router.get("/api/runs/{query_id}")
def run(query_id: str) -> dict[str, Any]:
    found = find_run(query_id)
    history = datasource.runs_before(
        found["sport"], found["pipeline"], found["run_started_at"], assemble.WINDOW_DAYS
    )
    return traced(assemble.run_detail(found, history))


@router.get("/api/runs/{query_id}/logs")
def run_logs(
    query_id: str,
    severity: str | None = Query(None),
    limit: int = Query(200, ge=1, le=2000),
) -> dict[str, Any]:
    found = find_run(query_id)
    return traced(
        {
            "query_id": query_id,
            "total_log_lines": found.get("log_lines"),
            "error_lines": found.get("error_lines"),
            "warning_lines": found.get("warning_lines"),
            "lines": datasource.logs(query_id, severity, limit),
        }
    )


@router.get("/api/runs/{query_id}/metrics")
def run_metrics(query_id: str) -> dict[str, Any]:
    found = find_run(query_id)
    return traced(shape_metrics(found, datasource.metrics(query_id)))


@router.get("/api/runs/{query_id}/rowcounts")
def run_rowcounts(query_id: str) -> dict[str, Any]:
    found = find_run(query_id)
    history = datasource.runs_before(
        found["sport"], found["pipeline"], found["run_started_at"], assemble.WINDOW_DAYS
    )
    detail = assemble.run_detail(found, history)
    return traced(
        {
            "query_id": query_id,
            "rows_loaded": found.get("rows_loaded"),
            "row_counts": found.get("row_counts"),
            "prev_row_counts": detail["prev_row_counts"],
        }
    )
