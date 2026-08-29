import csv
import io
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Query, Response

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
    q: Annotated[
        str | None,
        Query(description="free-text where: `column op value` joined by and (ops = != > < >= <=)"),
    ] = None,
    order: Annotated[str | None, Query(description="column to sort by; row_id when absent")] = None,
    desc: Annotated[bool, Query()] = False,
    limit: Annotated[int, Query(ge=1, le=explore.MAX_LIMIT)] = explore.DEFAULT_LIMIT,
    offset: Annotated[int, Query(ge=0)] = 0,
    format: Annotated[Literal["json", "csv"], Query()] = "json",
) -> explore.SheetPayload:
    """One page of a sheet: the table's columns, equality filters and the
    free-text where bar (both AND together), one sort column, and has_more
    for the next page. format=csv streams the same page as a file."""
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
        payload = explore.rows(
            profile, spec, where=pairs, q=q, order=order, desc=desc, limit=limit, offset=offset
        )
    except explore.BadRequest as err:
        raise HTTPException(status_code=400, detail=str(err)) from None
    if format == "csv":
        # a Response bypasses response_model, so one route serves both shapes
        names = [c.name for c in payload.columns]
        out = io.StringIO()
        writer = csv.writer(out)
        writer.writerow(names)
        for row in payload.rows:
            writer.writerow([row.get(n) for n in names])
        return Response(  # type: ignore[return-value]
            content=out.getvalue(),
            media_type="text/csv",
            headers={
                "Content-Disposition": f'attachment; filename="{profile.key}_{sheet}.csv"'
            },
        )
    return payload
