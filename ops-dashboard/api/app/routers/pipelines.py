"""The pipelines: the standings index and one pipeline's window."""

import datetime as dt
from typing import Any

from fastapi import APIRouter, HTTPException, Query

from app import assemble, config, datasource
from app.routers.common import check_sport, traced

router = APIRouter(tags=["pipelines"])


@router.get("/api/pipelines")
def pipelines_index(sport: str = Query("all")) -> dict[str, Any]:
    wanted = check_sport(sport)
    now = config.now()
    pipes = [p for p in datasource.pipelines() if wanted is None or p["sport"] == wanted]
    # Explicit bounds rather than a now-anchored day count: runs_between
    # applies the SAME window in fixture mode, which a days argument did
    # not. The trailing minute keeps a run started this instant in scope.
    start = now - dt.timedelta(days=assemble.WINDOW_DAYS)
    end = now + dt.timedelta(minutes=1)
    return traced(assemble.pipelines_index(pipes, datasource.runs_between(start, end, wanted), now))


@router.get("/api/pipelines/{sport}/{name}")
def pipeline(sport: str, name: str, limit: int = Query(8, ge=1, le=50)) -> dict[str, Any]:
    check_sport(sport)
    pipe = next(
        (p for p in datasource.pipelines() if p["sport"] == sport and p["name"] == name),
        None,
    )
    if pipe is None:
        raise HTTPException(status_code=404, detail=f"unknown pipeline {sport}/{name}")
    history = datasource.pipeline_history(sport, name, assemble.WINDOW_DAYS)
    return traced(assemble.pipeline_detail(pipe, history, config.now(), limit))
