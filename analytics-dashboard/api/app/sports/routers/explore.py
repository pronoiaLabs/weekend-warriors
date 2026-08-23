from typing import Annotated

from fastapi import APIRouter, HTTPException, Query

from app.sports.registry import Profile
from app.sports.tiles import explore

router = APIRouter(tags=["explore"])


@router.get("/explore", response_model=explore.CatalogPayload)
def get_catalog(profile: Profile) -> explore.CatalogPayload:
    """The sheets this sport has, each with its columns typed for a grid. A
    sport without explore tables gets an empty list, not a 404."""
    return explore.catalog(profile)


@router.get("/explore/{sheet}", response_model=explore.SheetPayload)
def get_sheet(
    profile: Profile,
    sheet: str,
    where: Annotated[
        list[str] | None,
        Query(description="equality filters as column:value; repeat for several"),
    ] = None,
    order: Annotated[str | None, Query(description="column to sort by; row_id when absent")] = None,
    desc: Annotated[bool, Query()] = False,
    limit: Annotated[int, Query(ge=1, le=explore.MAX_LIMIT)] = explore.DEFAULT_LIMIT,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> explore.SheetPayload:
    """One page of a sheet: the table's columns, equality filters on any of
    them, one sort column, and has_more for the next page."""
    spec = explore.BY_ID.get(sheet)
    if spec is None or not profile.has(spec.cap):
        raise HTTPException(status_code=404, detail=f"{profile.label} has no sheet {sheet!r}")
    pairs: list[tuple[str, str]] = []
    for item in where or []:
        column, sep, value = item.partition(":")
        if not sep or not column:
            raise HTTPException(status_code=400, detail=f"where expects column:value, got {item!r}")
        pairs.append((column, value))
    try:
        return explore.rows(
            profile, spec, where=pairs, order=order, desc=desc, limit=limit, offset=offset
        )
    except explore.BadRequest as err:
        raise HTTPException(status_code=400, detail=str(err)) from None
