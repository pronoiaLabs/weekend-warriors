"""The sports this API serves, and the two FastAPI dependencies that resolve them.

get_profile turns the {sport} path segment into a profile or a 404; require(cap)
does the same and additionally 404s when the sport lacks the capability, with a
message that names it. Routes declare what they need and never branch on the
sport's name.
"""

from collections.abc import Callable
from typing import Annotated

from fastapi import Depends, HTTPException

from app.sports.capabilities import Capability
from app.sports.profile import SportProfile
from app.sports.profiles.ncaaf import NCAAF
from app.sports.profiles.nfl import NFL

PROFILES: dict[str, SportProfile] = {p.key: p for p in (NFL, NCAAF)}


def get_profile(sport: str) -> SportProfile:
    try:
        return PROFILES[sport.lower()]
    except KeyError:
        raise HTTPException(status_code=404, detail=f"unknown sport {sport!r}") from None


# The annotated form routes use: `profile: Profile` resolves the {sport} segment.
Profile = Annotated[SportProfile, Depends(get_profile)]


def require(*caps: Capability) -> Callable[..., SportProfile]:
    """A route that reads several marts names them all; the first one missing is
    the one the 404 reports."""

    def dep(profile: Profile) -> SportProfile:
        for cap in caps:
            if not profile.has(cap):
                raise HTTPException(
                    status_code=404,
                    detail=f"{profile.label} has no {cap.value} data",
                )
        return profile

    return dep
