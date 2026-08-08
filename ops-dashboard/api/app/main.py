"""FastAPI app for the ops dashboard.

Phase 0: a health endpoint and an optional SPA mount. Snowflake-backed
endpoints arrive in later phases.
"""

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse


def create_app() -> FastAPI:
    app = FastAPI(title="ops-dashboard")

    @app.get("/api/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "service": "ops-dashboard"}

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
