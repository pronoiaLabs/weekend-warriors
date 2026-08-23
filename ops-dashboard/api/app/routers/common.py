"""Lookups and validations the routers share. Endpoints are sync on purpose: the
Snowflake connector is blocking, and FastAPI runs `def` routes on a threadpool
instead of stalling the loop."""

import datetime as dt
from typing import Any

from fastapi import HTTPException

from app import datasource


def check_sport(sport: str) -> str | None:
    if sport == "all":
        return None
    if sport not in datasource.list_sports():
        raise HTTPException(status_code=404, detail=f"unknown sport {sport!r}")
    return sport


def check_dbt_sport(sport: str) -> str | None:
    """V_DBT_RUNS spells sport lowercase; the registry spells it as the database
    stem. Same validation, one case fold, so an unknown sport is still a 404
    rather than a silently empty list."""
    if sport == "all":
        return None
    if sport.upper() not in datasource.list_sports():
        raise HTTPException(status_code=404, detail=f"unknown sport {sport!r}")
    return sport.lower()


def find_run(query_id: str) -> dict[str, Any]:
    found = datasource.run_by_query_id(query_id)
    if found is None:
        raise HTTPException(status_code=404, detail=f"unknown run {query_id!r}")
    return found


def find_build(build_id: str) -> dict[str, Any]:
    found = datasource.dbt_build_by_id(build_id)
    if found is None:
        raise HTTPException(status_code=404, detail=f"unknown build {build_id!r}")
    return found


def parse_day(date: str | None, now: dt.datetime) -> dt.date:
    try:
        return dt.date.fromisoformat(date) if date else now.date()
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=f"invalid date {date!r}") from exc


def traced(payload: dict[str, Any]) -> dict[str, Any]:
    """The payload plus the SQL this request built, for the page's expander."""
    return {**payload, "query": datasource.trace_sql()}
