from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import pulse

router = APIRouter(tags=["pulse"])

# The composite names every mart it reads; the first one missing is the 404.
WithPulse = Annotated[
    SportProfile,
    Depends(require(C.SCHEDULE, C.NEWS, C.STATUS_BOARD, C.TRENDING_PLAYERS, C.MARKET_MOVERS)),
]


@router.get("/pulse", response_model=pulse.PulsePayload)
def get_pulse(
    profile: WithPulse,
    days: Annotated[
        int, Query(ge=1, le=pulse.MAX_DAYS, description="news window in days")
    ] = pulse.DEFAULT_DAYS,
    season: Annotated[int | None, Query(description="defaults to the sport's current season")] = None,
    season_type: Annotated[str | None, Query(description="Preseason, Regular Season, Postseason")] = None,
    week: Annotated[int | None, Query(description="defaults to the week in progress or next up")] = None,
    vendor: Annotated[str | None, Query(description="book for the lines; defaults per sport")] = None,
) -> pulse.PulsePayload:
    """The catch-up digest: news, status, trending, movers, and the week's slate."""
    payload = pulse.load(
        profile, days=days, season=season, season_type_name=season_type, week=week, vendor=vendor
    )
    if payload is None:
        detail = f"{profile.label} has no games for season {season or profile.default_season}"
        raise HTTPException(status_code=404, detail=detail)
    return payload
