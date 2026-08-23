"""FastAPI app for the analytics dashboard.

Handlers are plain `def`, not `async def`, on purpose: the database drivers
block, and FastAPI runs sync handlers on its threadpool. The SPA catch-all is
mounted last so every API route wins; unknown /api paths stay 404s.
"""

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse

from app import config
from app.sports.payloads import HealthPayload
from app.sports.registry import PROFILES
from app.sports.router import router as sports_router


def create_app() -> FastAPI:
    app = FastAPI(title="analytics-dashboard", docs_url="/api/docs", openapi_url="/api/openapi.json")

    @app.get("/api/health", response_model=HealthPayload)
    def health() -> HealthPayload:
        return HealthPayload(
            ok=True,
            data=config.data_mode(),
            backend=config.backend(),
            role=config.role(),
            sports=sorted(PROFILES),
            as_of=config.now(),
        )

    app.include_router(sports_router)

    static_dir = _static_dir()
    if static_dir is not None:
        _mount_spa(app, static_dir)

    return app


def _static_dir() -> Path | None:
    """The built front end, or None when it has not been built.

    Resolved relative to this package (api/app -> ../../web/dist);
    ANALYTICS_DASHBOARD_STATIC overrides it for a container.
    """
    override = os.environ.get("ANALYTICS_DASHBOARD_STATIC")
    candidate = Path(override) if override else Path(__file__).resolve().parents[2] / "web" / "dist"
    return candidate if (candidate / "index.html").is_file() else None


def _mount_spa(app: FastAPI, static_dir: Path) -> None:
    @app.get("/{path:path}", include_in_schema=False)
    def spa(path: str) -> FileResponse:
        if path.startswith("api/"):
            raise HTTPException(status_code=404)
        file = static_dir / path
        if path and file.is_file():
            return FileResponse(file)
        return FileResponse(static_dir / "index.html")


app = create_app()
