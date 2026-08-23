from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import players

router = APIRouter(tags=["players"])

WithLeaders = Annotated[SportProfile, Depends(require(C.PLAYER_LEADERS))]
WithPlayer = Annotated[
    SportProfile, Depends(require(C.PLAYER_LEADERS, C.PLAYER_WEEKS, C.PLAYER_WEEK_STATS))
]

SeasonQ = Annotated[int | None, Query(description="defaults to the sport's current season")]
SeasonTypeQ = Annotated[
    str | None,
    Query(description="Preseason, Regular Season, Postseason; defaults to the one in progress"),
]


@router.get("/players", response_model=players.LeadersPayload)
def get_leaders(
    profile: WithLeaders,
    season: SeasonQ = None,
    season_type: SeasonTypeQ = None,
    position: Annotated[
        str | None, Query(description="QB, RB, WR, TE ...; all when absent")
    ] = None,
    team: Annotated[str | None, Query(description="team label (KC); the roster when given")] = None,
) -> players.LeadersPayload:
    """Season totals, rates and ranks within the position for every player with
    a game in the season type; narrowed to a position or a team when asked."""
    payload = players.leaders(
        profile, season=season, season_type_name=season_type, position=position, team=team
    )
    if payload is None:
        detail = f"{profile.label} has no player games in season {season or profile.default_season}"
        if season_type is not None:
            detail += f" {season_type}"
        raise HTTPException(status_code=404, detail=detail)
    return payload


@router.get("/players/{player_key}", response_model=players.PlayerPayload)
def get_player(
    profile: WithPlayer,
    player_key: str,
    season: Annotated[int | None, Query(description="defaults to the player's latest")] = None,
    season_type: SeasonTypeQ = None,
) -> players.PlayerPayload:
    """One player's season: his career rows, the chosen season's games, and the
    long stat rows with trailing and prior-season comparisons."""
    payload = players.player(
        profile, player_key=player_key, season=season, season_type_name=season_type
    )
    if payload is None:
        detail = f"{profile.label} has no player {player_key} with games"
        if season is not None:
            detail += f" in season {season}"
        if season_type is not None:
            detail += f" {season_type}"
        raise HTTPException(status_code=404, detail=detail)
    return payload
