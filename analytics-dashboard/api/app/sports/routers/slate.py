from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import slate

router = APIRouter(tags=["slate"])

WithSchedule = Annotated[SportProfile, Depends(require(C.SCHEDULE))]


@router.get("/slate", response_model=slate.SlatePayload)
def get_slate(
    profile: WithSchedule,
    season: Annotated[int | None, Query(description="defaults to the sport's current season")] = None,
    season_type: Annotated[str | None, Query(description="Preseason, Regular Season, Postseason")] = None,
    week: Annotated[int | None, Query(description="defaults to the week in progress or next up")] = None,
    vendor: Annotated[str | None, Query(description="book for the line; defaults per sport")] = None,
) -> slate.SlatePayload:
    """One week of games, one card per game, with the chosen book's closing line."""
    payload = slate.load(
        profile, season=season, season_type_name=season_type, week=week, vendor=vendor
    )
    if payload is None:
        detail = f"{profile.label} has no games for season {season or profile.default_season}"
        if week is not None or season_type is not None:
            detail += f" {season_type or ''} week {week}".rstrip()
        raise HTTPException(status_code=404, detail=detail)
    return payload
