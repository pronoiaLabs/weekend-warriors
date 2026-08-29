from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import players

router = APIRouter(tags=["players"])

WithLeaders = Annotated[SportProfile, Depends(require(C.PLAYER_LEADERS))]
WithPlayer = Annotated[
    SportProfile,
    Depends(
        require(C.PLAYER_LEADERS, C.PLAYER_WEEKS, C.PLAYER_WEEK_STATS, C.PLAYER_PROFILE)
    ),
]
WithUsage = Annotated[
    SportProfile, Depends(require(C.PLAYER_LEADERS, C.PLAYER_SITUATION_USAGE))
]
WithProps = Annotated[SportProfile, Depends(require(C.PLAYER_LEADERS, C.GAME_PROP_BOARD))]

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


@router.get("/players/{player_key}/usage", response_model=players.PlayerUsagePayload)
def get_player_usage(
    profile: WithUsage,
    player_key: str,
    season: Annotated[int | None, Query(description="defaults to the player's latest")] = None,
    season_type: SeasonTypeQ = None,
) -> players.PlayerUsagePayload:
    """Where the player's targets come from: situational usage by down, field
    zone and game script, with the qualified league baseline for his position.
    Empty rows are honest -- preseason has no play-by-play."""
    payload = players.usage(
        profile, player_key=player_key, season=season, season_type_name=season_type
    )
    if payload is None:
        detail = f"{profile.label} has no player {player_key} with games"
        if season is not None:
            detail += f" in season {season}"
        raise HTTPException(status_code=404, detail=detail)
    return payload


@router.get("/players/{player_key}/props", response_model=players.PlayerPropsPayload)
def get_player_props(
    profile: WithProps,
    player_key: str,
    season: Annotated[int | None, Query(description="defaults to the player's latest")] = None,
    vendor: Annotated[
        str | None, Query(description="book; the sport's default when absent")
    ] = None,
    stat_key: Annotated[
        str | None, Query(description="prop stat; the position's headline stat when absent")
    ] = None,
) -> players.PlayerPropsPayload:
    """The market's history on this player: closing line vs actual per game at
    one book, split into completed and pending. Empty lists are honest -- the
    odds feed starts in 2026."""
    payload = players.props(
        profile, player_key=player_key, season=season, vendor=vendor, stat_key=stat_key
    )
    if payload is None:
        detail = f"{profile.label} has no player {player_key} with games"
        raise HTTPException(status_code=404, detail=detail)
    return payload
