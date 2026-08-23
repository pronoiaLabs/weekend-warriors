"""FastAPI app for the ops dashboard: the routers, a per-request SQL trace, and
the built front end mounted last so client-side routes survive a hard reload."""

from collections.abc import Awaitable, Callable
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse

from app import config, datasource
from app.routers import dbt, health, pipelines, runs, slate, sports


def create_app() -> FastAPI:
    app = FastAPI(title="ops-dashboard")

    @app.middleware("http")
    async def open_trace(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        # one trace per request; contextvars follow the handler onto the threadpool
        datasource.begin_trace()
        return await call_next(request)

    for module in (health, sports, slate, pipelines, runs, dbt):
        app.include_router(module.router)

    static_dir = config.static_dir()
    if static_dir is not None:
        _mount_spa(app, static_dir)

    return app


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
