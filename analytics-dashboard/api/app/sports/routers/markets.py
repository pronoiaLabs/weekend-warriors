from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import markets

router = APIRouter(tags=["markets"])

WithLines = Annotated[SportProfile, Depends(require(C.LINE_HISTORY))]
WithGameMarkets = Annotated[SportProfile, Depends(require(C.LINE_HISTORY, C.PROP_LINE_HISTORY))]

VendorQ = Annotated[str | None, Query(description="book for the lines; defaults per sport")]


@router.get("/markets", response_model=markets.MarketsPayload)
def get_markets(
    profile: WithLines,
    season: Annotated[
        int | None, Query(description="defaults to the sport's current season")
    ] = None,
    season_type: Annotated[
        str | None, Query(description="Preseason, Regular Season, Postseason")
    ] = None,
    week: Annotated[
        int | None, Query(description="defaults to the week in progress or next up")
    ] = None,
    vendor: VendorQ = None,
) -> markets.MarketsPayload:
    """One week's pregame line movement at one book: every snapshot where the
    line moved, in kickoff and snapshot order."""
    payload = markets.board(
        profile, season=season, season_type_name=season_type, week=week, vendor=vendor
    )
    if payload is None:
        detail = f"{profile.label} has no lines for season {season or profile.default_season}"
        if week is not None or season_type is not None:
            detail += f" {season_type or ''} week {week}".rstrip()
        raise HTTPException(status_code=404, detail=detail)
    return payload


@router.get("/markets/{game_key}", response_model=markets.GameMarketsPayload)
def get_game_markets(
    profile: WithGameMarkets, game_key: str, vendor: VendorQ = None
) -> markets.GameMarketsPayload:
    """Every book's line path for one game, and the chosen book's prop paths."""
    payload = markets.game(profile, game_key=game_key, vendor=vendor)
    if payload is None:
        raise HTTPException(
            status_code=404, detail=f"{profile.label} has no lines for game {game_key}"
        )
    return payload
