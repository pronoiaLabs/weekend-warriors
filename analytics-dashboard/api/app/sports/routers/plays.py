from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import plays

router = APIRouter(tags=["plays"])

WithPlays = Annotated[SportProfile, Depends(require(C.PLAY_LOG, C.PLAYER_SITUATION_USAGE))]

BucketQ = Annotated[str | None, Query(description="warehouse vocabulary, e.g. 3rd_4th, red_zone")]


@router.get("/plays", response_model=plays.PlaysPayload)
def get_plays(
    profile: WithPlays,
    season: Annotated[int | None, Query(description="defaults to the sport's current season")] = None,
    week: Annotated[int | None, Query()] = None,
    game_key: Annotated[str | None, Query(description="one game; an anchor")] = None,
    player_key: Annotated[
        str | None, Query(description="matches any role (passer, rusher, receiver); an anchor")
    ] = None,
    team: Annotated[str | None, Query(description="possession team label (KC); an anchor")] = None,
    down_bucket: BucketQ = None,
    distance_bucket: BucketQ = None,
    field_zone: BucketQ = None,
    script: BucketQ = None,
    play_family: BucketQ = None,
    shotgun: Annotated[bool | None, Query()] = None,
    no_huddle: Annotated[bool | None, Query()] = None,
    two_minute: Annotated[bool | None, Query()] = None,
) -> plays.PlaysPayload:
    """The play feed, drive-grouped by the page. Anchored: at least one of
    game_key, player_key or team must bind, which keeps every response one
    shot -- there is no paging."""
    if game_key is None and player_key is None and team is None:
        raise HTTPException(
            status_code=400,
            detail="anchor the feed with at least one of game_key, player_key or team",
        )
    payload = plays.load(
        profile,
        season=season,
        week=week,
        game_key=game_key,
        player_key=player_key,
        team=team,
        down_bucket=down_bucket,
        distance_bucket=distance_bucket,
        field_zone=field_zone,
        script=script,
        play_family=play_family,
        shotgun=shotgun,
        no_huddle=no_huddle,
        two_minute=two_minute,
    )
    if payload is None:
        raise HTTPException(
            status_code=404, detail=f"{profile.label} has no plays for game {game_key}"
        )
    return payload
