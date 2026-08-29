from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import game_board, situations

router = APIRouter(tags=["games"])

WithSchedule = Annotated[SportProfile, Depends(require(C.SCHEDULE))]
WithSituations = Annotated[SportProfile, Depends(require(C.SCHEDULE, C.TEAM_SITUATION))]


@router.get("/games/{game_key}", response_model=game_board.GamePayload)
def get_game(
    profile: WithSchedule,
    game_key: str,
    vendor: Annotated[str | None, Query(description="book for the game line; defaults per sport")] = None,
) -> game_board.GamePayload:
    """One game: its slate row with the chosen book's line, and the prop board
    for every book, split into the away and home columns."""
    payload = game_board.load(profile, game_key, vendor=vendor)
    if payload is None:
        raise HTTPException(status_code=404, detail=f"no game {game_key!r} on the {profile.label} slate")
    return payload


@router.get("/games/{game_key}/situations", response_model=situations.GameSituationsPayload)
def get_game_situations(
    profile: WithSituations,
    game_key: str,
) -> situations.GameSituationsPayload:
    """Both teams' situation splits (down, distance, field zone, script, play
    family), each unit's own numbers beside what it allows, season-level. A
    postseason game reads the regular-season splits; preseason is empty."""
    payload = situations.load(profile, game_key)
    if payload is None:
        raise HTTPException(status_code=404, detail=f"no game {game_key!r} on the {profile.label} slate")
    return payload
