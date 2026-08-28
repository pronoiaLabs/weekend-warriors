"""Team branding: the 32 teams' colors, logos and wordmarks, fetched once.

One select on the branding mart, cached hard (the table changes when a team
rebrands, which is to say almost never). The client joins rows by team_key,
which every mart carries, so no other tile needs logo columns.
"""

from pydantic import BaseModel

from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.payloads import Envelope
from app.sports.profile import SportProfile


class BrandingRow(BaseModel):
    app_team_branding_key: str
    team_key: str
    team_id: int
    team_label: str
    team_name: str
    team_nickname: str | None = None
    conference: str | None = None
    division: str | None = None
    nflverse_abbr: str | None = None
    color_primary: str | None = None
    color_secondary: str | None = None
    logo_url: str | None = None
    logo_squared_url: str | None = None
    wordmark_url: str | None = None


COLUMNS: tuple[str, ...] = tuple(BrandingRow.model_fields)


class BrandingPayload(Envelope[BrandingRow]):
    pass


def load(profile: SportProfile) -> tuple[list[BrandingRow], str]:
    rows, sql = source.select(
        profile,
        C.TEAM_BRANDING,
        COLUMNS,
        where="1 = 1",
        params={},
        matches=lambda r: True,
        order=("team_label",),
        tag="branding",
        ttl=3600,
    )
    return [BrandingRow(**r) for r in rows], sql
