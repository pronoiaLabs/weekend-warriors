from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import news

router = APIRouter(tags=["news"])

WithNews = Annotated[SportProfile, Depends(require(C.NEWS))]


@router.get("/news", response_model=news.NewsPayload)
def get_news(
    profile: WithNews,
    days: Annotated[
        int, Query(ge=1, le=news.MAX_DAYS, description="window before the clock, in days")
    ] = news.DEFAULT_DAYS,
    team: Annotated[
        str | None, Query(description="team label (KC); every team when absent")
    ] = None,
) -> news.NewsPayload:
    """Player mentions published in the window, newest first, with each
    player's next game attached."""
    return news.load(profile, days=days, team=team)
