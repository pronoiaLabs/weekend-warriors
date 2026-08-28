"""The Pulse's trending zone: Sleeper's latest add/drop boards.

One select on the trending mart, which already keeps only the freshest fetch
per direction. Adds first, then drops, each in board order.
"""

import datetime as dt

from pydantic import BaseModel

from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile


class TrendingRow(BaseModel):
    app_trending_players_key: str
    player_key: str
    player_id: int | None = None
    sleeper_player_id: str | None = None
    player_name: str
    position: str | None = None
    position_name: str | None = None
    position_group: str | None = None
    headshot_url: str | None = None
    team_key: str | None = None
    team_label: str | None = None
    team_name: str | None = None
    direction: str
    move_count_24h: int
    board_rank: int | None = None
    lookback_hours: int | None = None
    fetched_at: dt.datetime
    trend_date: dt.date
    state_season: int | None = None
    state_week: int | None = None
    next_game_key: str | None = None
    next_game_datetime_et: dt.datetime | None = None
    next_opponent_team_key: str | None = None
    next_opponent_label: str | None = None
    next_game_is_home: bool | None = None


COLUMNS: tuple[str, ...] = tuple(TrendingRow.model_fields)


def load(profile: SportProfile) -> tuple[list[TrendingRow], str]:
    rows, sql = source.select(
        profile,
        C.TRENDING_PLAYERS,
        COLUMNS,
        where="1 = 1",
        params={},
        matches=lambda r: True,
        order=("direction", "board_rank"),
        tag="trending",
    )
    return [TrendingRow(**r) for r in rows], sql
