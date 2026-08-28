"""The Pulse's status board: designations and live status changes, one row per
player, with the practice line and the depth-chart next-man-up.

One select on the status mart; it is current-state and small (players currently
worth watching), so no bound filters. Ordering puts the hard designations first
(designation_order: Out, Doubtful, Questionable, then live-only rows), freshest
filing first within each.
"""

import datetime as dt

from pydantic import BaseModel

from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile


class StatusRow(BaseModel):
    app_status_board_key: str
    player_key: str
    player_id: int | None = None
    player_name: str
    position: str | None = None
    position_name: str | None = None
    position_group: str | None = None
    headshot_url: str | None = None
    sleeper_player_id: str | None = None
    team_key: str | None = None
    team_label: str | None = None
    team_name: str | None = None
    status_source: str
    designation: str | None = None
    designation_order: int
    injury: str | None = None
    injury_detail: str | None = None
    practice_status: str | None = None
    practice_wed: str | None = None
    practice_thu: str | None = None
    practice_fri: str | None = None
    report_modified_at: dt.datetime | None = None
    live_injury_status: str | None = None
    live_practice_participation: str | None = None
    depth_chart_position: str | None = None
    depth_chart_order: int | None = None
    news_updated_at: dt.datetime | None = None
    backup_player_key: str | None = None
    backup_player_name: str | None = None
    backup_depth_rank: int | None = None
    ripple_note: str | None = None
    game_key: str | None = None
    game_datetime_et: dt.datetime | None = None
    season: int | None = None
    week: int | None = None
    season_type_name: str | None = None
    opponent_team_key: str | None = None
    opponent_label: str | None = None
    is_home: bool | None = None


COLUMNS: tuple[str, ...] = tuple(StatusRow.model_fields)


def load(profile: SportProfile) -> tuple[list[StatusRow], str]:
    rows, sql = source.select(
        profile,
        C.STATUS_BOARD,
        COLUMNS,
        where="1 = 1",
        params={},
        matches=lambda r: True,
        order=("designation_order", "report_modified_at desc", "player_key"),
        tag="status_board",
    )
    return [StatusRow(**r) for r in rows], sql
