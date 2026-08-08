"""FastAPI app for the ops dashboard."""

import datetime as dt
import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse

from app import assemble, datasource


def _now() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


def _check_sport(sport: str) -> str | None:
    if sport == "all":
        return None
    if sport not in datasource.list_sports():
        raise HTTPException(status_code=404, detail=f"unknown sport {sport!r}")
    return sport


def _find_run(query_id: str) -> dict[str, Any]:
    found = datasource.run_by_query_id(query_id)
    if found is None:
        raise HTTPException(status_code=404, detail=f"unknown run {query_id!r}")
    return found


# The two headline dot strips. Everything else appears in the summary table:
# collect everything, filter downstream.
_STRIP_METRICS = {"container.cpu.usage": "cpu", "container.memory.usage": "memory"}


def _shape_metrics(run: dict[str, Any], samples: list[dict[str, Any]]) -> dict[str, Any]:
    strips: dict[str, Any] = {
        "cpu": {"points": [], "limit": run.get("cpu_cores_limit"), "unit": "core"},
        "memory": {"points": [], "limit": run.get("mem_bytes_requested"), "unit": "byte"},
    }
    summary: dict[str, dict[str, Any]] = {}
    for s in samples:
        name = s["metric_name"]
        agg = summary.setdefault(
            name,
            {"samples": 0, "max": None, "unit": s.get("metric_unit"), "group": s.get("metric_group")},
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


def create_app() -> FastAPI:
    app = FastAPI(title="ops-dashboard")

    @app.get("/api/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "service": "ops-dashboard"}

    # Endpoints are sync on purpose: the Snowflake connector is blocking, and
    # FastAPI runs `def` routes on a threadpool instead of stalling the loop.
    @app.get("/api/runs")
    def runs(
        sport: str = Query("all"),
        limit: int = Query(50, ge=1, le=500),
    ) -> dict[str, Any]:
        wanted = _check_sport(sport)
        return {"sports": datasource.list_sports(), "runs": datasource.recent_runs(wanted, limit)}

    @app.get("/api/sports")
    def sports() -> dict[str, Any]:
        pipes = datasource.pipelines()
        return {
            "sports": [
                {"sport": s, "pipelines": sum(1 for p in pipes if p["sport"] == s)}
                for s in sorted({p["sport"] for p in pipes})
            ]
        }

    @app.get("/api/overview")
    def overview(sport: str = Query("all"), date: str | None = Query(None)) -> dict[str, Any]:
        wanted = _check_sport(sport)
        now = _now()
        day = dt.date.fromisoformat(date) if date else now.date()
        pipes = [p for p in datasource.pipelines() if wanted is None or p["sport"] == wanted]
        runs_window = datasource.runs_window(assemble.WINDOW_DAYS, wanted)
        return assemble.overview(pipes, runs_window, now, day)

    @app.get("/api/incidents")
    def incidents(
        sport: str = Query("all"),
        days: int = Query(7, ge=1, le=assemble.WINDOW_DAYS),
        kind: str = Query("all"),
    ) -> dict[str, Any]:
        wanted = _check_sport(sport)
        pipes = [p for p in datasource.pipelines() if wanted is None or p["sport"] == wanted]
        payload = assemble.incidents(pipes, datasource.runs_window(days, wanted), _now(), days)
        if kind != "all":
            payload["incidents"] = [e for e in payload["incidents"] if e["kind"] == kind]
        return payload

    @app.get("/api/pipelines/{sport}/{name}")
    def pipeline(sport: str, name: str, limit: int = Query(8, ge=1, le=50)) -> dict[str, Any]:
        _check_sport(sport)
        pipe = next(
            (p for p in datasource.pipelines() if p["sport"] == sport and p["name"] == name),
            None,
        )
        if pipe is None:
            raise HTTPException(status_code=404, detail=f"unknown pipeline {sport}/{name}")
        history = datasource.pipeline_history(sport, name, assemble.WINDOW_DAYS)
        return assemble.pipeline_detail(pipe, history, _now(), limit)

    @app.get("/api/runs/{query_id}")
    def run(query_id: str) -> dict[str, Any]:
        found = _find_run(query_id)
        history = datasource.runs_before(
            found["sport"], found["pipeline"], found["run_started_at"], assemble.WINDOW_DAYS
        )
        return assemble.run_detail(found, history)

    @app.get("/api/runs/{query_id}/logs")
    def run_logs(
        query_id: str,
        severity: str | None = Query(None),
        limit: int = Query(200, ge=1, le=2000),
    ) -> dict[str, Any]:
        found = _find_run(query_id)
        return {
            "query_id": query_id,
            "total_log_lines": found.get("log_lines"),
            "error_lines": found.get("error_lines"),
            "warning_lines": found.get("warning_lines"),
            "lines": datasource.logs(query_id, severity, limit),
        }

    @app.get("/api/runs/{query_id}/metrics")
    def run_metrics(query_id: str) -> dict[str, Any]:
        found = _find_run(query_id)
        samples = datasource.metrics(query_id)
        return _shape_metrics(found, samples)

    @app.get("/api/runs/{query_id}/rowcounts")
    def run_rowcounts(query_id: str) -> dict[str, Any]:
        found = _find_run(query_id)
        history = datasource.runs_before(
            found["sport"], found["pipeline"], found["run_started_at"], assemble.WINDOW_DAYS
        )
        detail = assemble.run_detail(found, history)
        return {
            "query_id": query_id,
            "rows_loaded": found.get("rows_loaded"),
            "row_counts": found.get("row_counts"),
            "prev_row_counts": detail["prev_row_counts"],
        }

    static_dir = _static_dir()
    if static_dir is not None:
        _mount_spa(app, static_dir)

    return app


def _static_dir() -> Path | None:
    """The built front end, or None when it has not been built.

    Resolved relative to this package (api/app -> ../../web/dist) so it works
    regardless of the working directory; OPS_DASHBOARD_STATIC overrides it for
    the SPCS container, where the two live elsewhere.
    """
    override = os.environ.get("OPS_DASHBOARD_STATIC")
    candidate = Path(override) if override else Path(__file__).resolve().parents[2] / "web" / "dist"
    return candidate if (candidate / "index.html").is_file() else None


def _mount_spa(app: FastAPI, static_dir: Path) -> None:
    # A catch-all registered after the API routes: real files are served as-is,
    # anything else gets index.html so client-side routes survive a hard reload.
    # Unknown /api paths must stay 404s rather than return HTML.
    @app.get("/{path:path}", include_in_schema=False)
    def spa(path: str) -> FileResponse:
        if path.startswith("api/"):
            raise HTTPException(status_code=404)
        file = static_dir / path
        if path and file.is_file():
            return FileResponse(file)
        return FileResponse(static_dir / "index.html")


app = create_app()
