"""The dashboard: one day of the schedule as a scoreboard, and the AI wire."""

import datetime as dt
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, HTTPException, Query

from app import assemble, config, datasource, schedule
from app.routers.common import check_sport, parse_day, traced

router = APIRouter(tags=["slate"])


def _zone(name: str | None) -> dt.tzinfo:
    if not name or name.upper() == "UTC":
        return dt.UTC
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=422, detail=f"unknown timezone {name!r}") from exc


@router.get("/api/slate")
def slate(
    sport: str = Query("all"),
    date: str | None = Query(None),
    tz: str | None = Query(None, description="IANA zone the day is cut in; UTC when absent"),
) -> dict[str, Any]:
    """One calendar day of the viewer's zone: `date` is a local date, today by
    default, and the cron slots are the UTC fire times that fall inside it."""
    wanted = check_sport(sport)
    now = config.now()
    zone = _zone(tz)
    day = parse_day(date, now.astimezone(zone))
    pipes = [p for p in datasource.pipelines() if wanted is None or p["sport"] == wanted]
    # Window: the strip needs +/-3 days of runs; prev-run context on the
    # oldest strip day needs WINDOW_DAYS of lookback behind it.
    radius = 3
    start, _ = schedule.day_bounds(day - dt.timedelta(days=radius + assemble.WINDOW_DAYS), zone)
    _, end = schedule.day_bounds(day + dt.timedelta(days=radius), zone)
    runs = datasource.runs_between(start, end, wanted)
    builds = datasource.dbt_builds(wanted.lower() if wanted else None, 50)
    return traced(assemble.slate(pipes, runs, builds, now, day, radius, zone))


@router.get("/api/headlines")
def headlines(date: str | None = Query(None)) -> dict[str, Any]:
    # Sport-agnostic on purpose: the wire is one editorial voice over the
    # whole platform, and HEADLINES.ENTITY is free text, not a sport key.
    day = parse_day(date, config.now())
    return traced(assemble.headlines(datasource.headlines_for_day(day), day))
