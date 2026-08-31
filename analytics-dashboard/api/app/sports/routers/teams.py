from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query

from app import config
from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.registry import require
from app.sports.tiles import branding, teams

router = APIRouter(tags=["teams"])

WithStandings = Annotated[SportProfile, Depends(require(C.TEAM_STANDINGS))]
WithBranding = Annotated[SportProfile, Depends(require(C.TEAM_BRANDING))]
WithTeam = Annotated[
    SportProfile,
    Depends(require(C.TEAM_STANDINGS, C.TEAM_WEEKS, C.TEAM_ALLOWED, C.TEAM_ATS, C.TEAM_SITUATION)),
]

SeasonQ = Annotated[int | None, Query(description="defaults to the sport's current season")]
SeasonTypeQ = Annotated[
    str | None,
    Query(description="Preseason, Regular Season, Postseason; defaults to the one in progress"),
]


@router.get("/teams", response_model=teams.StandingsPayload)
def get_standings(
    profile: WithStandings,
    season: SeasonQ = None,
    season_type: SeasonTypeQ = None,
    split: Annotated[Literal["all", "home", "away"], Query()] = "all",
) -> teams.StandingsPayload:
    """The standings for one season type and split, ranked overall."""
    payload = teams.standings(profile, season=season, season_type_name=season_type, split=split)
    if payload is None:
        raise HTTPException(
            status_code=404,
            detail=_no_games(profile, season, season_type),
        )
    return payload


# Declared before /teams/{team} so the literal path wins over the segment.
@router.get("/teams/branding", response_model=branding.BrandingPayload)
def get_branding(profile: WithBranding) -> branding.BrandingPayload:
    """Every team's colors, logos and wordmark. Fetch once, join by team_key."""
    rows, sql = branding.load(profile)
    return branding.BrandingPayload(
        sport=profile.key,
        season=profile.default_season,
        as_of=config.now(),
        rows=rows,
        query=sql,
    )


@router.get("/teams/{team}", response_model=teams.TeamPayload)
def get_team(
    profile: WithTeam,
    team: str,
    season: SeasonQ = None,
    season_type: SeasonTypeQ = None,
    vendor: Annotated[str | None, Query(description="book for the lines; defaults per sport")] = None,
) -> teams.TeamPayload:
    """One team's season: standings splits, every game with the chosen book's
    closing line, what its defense allows by position, and its record against
    the number at every book."""
    payload = teams.team(
        profile, team_label=team, season=season, season_type_name=season_type, vendor=vendor
    )
    if payload is None:
        raise HTTPException(
            status_code=404,
            detail=_no_games(profile, season, season_type, team=team.upper()),
        )
    return payload


def _no_games(
    profile: SportProfile, season: int | None, season_type: str | None, team: str | None = None
) -> str:
    detail = f"{profile.label} has no games"
    if team is not None:
        detail += f" for team {team}"
    detail += f" in season {season or profile.default_season}"
    if season_type is not None:
        detail += f" {season_type}"
    return detail
