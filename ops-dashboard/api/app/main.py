"""FastAPI app for the ops dashboard."""

import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse

from app import datasource


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
        known = datasource.list_sports()
        wanted = None if sport == "all" else sport
        if wanted is not None and wanted not in known:
            raise HTTPException(status_code=404, detail=f"unknown sport {sport!r}")
        return {"sports": known, "runs": datasource.recent_runs(wanted, limit)}

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
