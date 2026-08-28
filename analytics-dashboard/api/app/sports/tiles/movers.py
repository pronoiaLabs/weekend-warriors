"""The Pulse's market movers: biggest line moves since open, games and props.

One select on the movers mart bound to a week and a book, ordered by the size
of the move; the split into games and props happens here by the mart's `kind`
column (pure shaping, like the slate's collapse). The mart pre-ranks by
abs(delta) within (season, season_type, week, vendor, kind), so a generous
mover_rank bound keeps the select small before the per-kind caps apply.
"""

import datetime as dt

from pydantic import BaseModel, Field

from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile

DEFAULT_GAMES = 6
DEFAULT_PROPS = 8


class MoverRow(BaseModel):
    app_market_movers_key: str
    kind: str
    game_key: str
    game_id: int
    season: int
    week: int
    season_type: int
    season_type_name: str
    game_date: dt.date
    game_datetime_et: dt.datetime
    vendor: str
    market: str
    home_team_key: str | None = None
    home_team_label: str | None = None
    away_team_key: str | None = None
    away_team_label: str | None = None
    player_key: str | None = None
    player_id: int | None = None
    player_name: str | None = None
    position: str | None = None
    headshot_url: str | None = None
    team_key: str | None = None
    team_label: str | None = None
    stat_label: str | None = None
    open_line: float
    latest_line: float
    delta: float
    abs_delta: float
    open_at: dt.datetime | None = None
    moved_at: dt.datetime | None = None
    snapshots: int | None = None
    mover_rank: int


COLUMNS: tuple[str, ...] = tuple(MoverRow.model_fields)


class MoversSection(BaseModel):
    games: list[MoverRow] = Field(default_factory=list)
    props: list[MoverRow] = Field(default_factory=list)


def load(
    profile: SportProfile,
    *,
    season: int,
    season_type_name: str,
    week: int,
    vendor: str,
    games_limit: int = DEFAULT_GAMES,
    props_limit: int = DEFAULT_PROPS,
) -> tuple[MoversSection, str]:
    params: dict[str, object] = {
        "season": season,
        "season_type_name": season_type_name,
        "week": week,
        "vendor": vendor,
        # generous per-kind bound; the caps below do the final trim
        "max_rank": max(games_limit, props_limit),
    }
    rows, sql = source.select(
        profile,
        C.MARKET_MOVERS,
        COLUMNS,
        where=(
            "season = %(season)s and season_type_name = %(season_type_name)s"
            " and week = %(week)s and vendor = %(vendor)s"
            " and mover_rank <= %(max_rank)s"
        ),
        params=params,
        matches=lambda r: (
            r["season"] == season
            and r["season_type_name"] == season_type_name
            and r["week"] == week
            and r["vendor"] == vendor
            and r["mover_rank"] <= params["max_rank"]
        ),
        order=("abs_delta desc", "app_market_movers_key"),
        tag="movers",
    )
    section = MoversSection()
    for r in rows:
        row = MoverRow(**r)
        if row.kind == "game" and len(section.games) < games_limit:
            section.games.append(row)
        elif row.kind == "prop" and len(section.props) < props_limit:
            section.props.append(row)
    return section, sql
