"""dbt builds are a separate spine from the dlt runs: TASK_HISTORY for the
DBT_BUILD_% tasks, joined to the build record the proc writes. They share no
view, no sport casing and no query id with /api/runs."""

from typing import Any

from fastapi import APIRouter, HTTPException, Query

from app import datasource
from app.routers.common import check_dbt_sport, find_build, traced

router = APIRouter(tags=["dbt"])


@router.get("/api/dbt/builds")
def dbt_builds(sport: str = Query("all"), limit: int = Query(50, ge=1, le=200)) -> dict[str, Any]:
    wanted = check_dbt_sport(sport)
    return traced({"builds": datasource.dbt_builds(wanted, limit)})


@router.get("/api/dbt/builds/{build_id}")
def dbt_build(build_id: str) -> dict[str, Any]:
    found = find_build(build_id)
    loads = datasource.dbt_build_loads(
        found["sport"], found.get("started_at"), found.get("completed_time")
    )
    return traced({"build": found, "loads": loads})


@router.get("/api/dbt/builds/{build_id}/queries")
def dbt_build_queries(build_id: str, limit: int = Query(100, ge=1, le=500)) -> dict[str, Any]:
    # Validate the build first: an unknown id would otherwise read as a
    # build that ran no queries.
    find_build(build_id)
    return traced({"queries": datasource.dbt_queries(build_id, limit)})


@router.get("/api/dbt/queries/{query_id}/operators")
def dbt_query_operators(query_id: str) -> dict[str, Any]:
    rows = datasource.dbt_operators(query_id)
    if not rows:
        raise HTTPException(status_code=404, detail=f"no operator stats for {query_id!r}")
    return traced({"query_id": query_id, "operators": rows})
