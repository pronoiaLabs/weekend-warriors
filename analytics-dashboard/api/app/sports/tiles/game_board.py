"""The game page: one game's slate row and its prop board split by side.

Two selects. The game's slate rows (every vendor) collapse to the requested
book's line exactly as the board does; the prop board rows for the game come back
for every vendor so the page can switch books and stat families without another
round trip. Rows are split into the away and home columns here; nothing else is
computed, the mart already carries form, line, gap, hit rate and opponent rank.
"""

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field, field_validator

from app import config, db
from app.sports import source
from app.sports.capabilities import Capability
from app.sports.profile import SportProfile
from app.sports.tiles import slate

CAP = Capability.GAME_PROP_BOARD


class PropRow(BaseModel):
    app_game_prop_board_key: str
    game_key: str
    season: int
    week: int
    season_type_name: str
    game_datetime_et: dt.datetime
    is_completed: bool
    player_key: str
    player_id: int | None = None
    player_name: str
    position: str | None = None
    position_name: str | None = None
    position_group: str | None = None
    team_key: str | None = None
    team_label: str | None = None
    team_name: str | None = None
    is_home: bool | None = None
    opponent_team_key: str | None = None
    opponent_label: str | None = None
    opponent_name: str | None = None
    vendor: str
    prop_type: str
    market_type: str
    stat_key: str | None = None
    stat_label: str | None = None
    line_value: float | None = None
    opening_line_value: float | None = None
    line_movement: float | None = None
    over_odds: float | None = None
    under_odds: float | None = None
    market_odds: float | None = None
    opening_over_odds: float | None = None
    opening_under_odds: float | None = None
    opening_market_odds: float | None = None
    line_selected_at: dt.datetime | None = None
    trailing_games: int | None = None
    trailing_avg: float | None = None
    stat_last3: list[float] | None = None
    trailing_over_line: int | None = None
    trailing_hit_rate: float | None = None
    gap_to_line: float | None = None
    games_played_to_date: int | None = None
    stat_avg_to_date: float | None = None
    games_over_line_to_date: int | None = None
    hit_rate_over_line: float | None = None
    # Sleeper's latest pre-kickoff projection for this prop's stat; coverage
    # follows Sleeper's calendar (its clock serves the league's current week)
    projection_value: float | None = None
    projection_vs_line: float | None = None
    has_projection: bool = False
    projection_captured_at: dt.datetime | None = None
    # usage form: trailing three games strictly before kickoff
    usage_trailing3_games: int = 0
    target_share_trailing3: float | None = None
    air_yards_share_trailing3: float | None = None
    snap_pct_trailing3: float | None = None
    opponent_allowed_stat_key: str | None = None
    opponent_allowed_per_game: float | None = None
    opponent_allowed_rank: int | None = None
    opponent_allowed_teams_ranked: int | None = None
    opponent_allowed_season: int | None = None
    news_headline: str | None = None
    news_context: str | None = None
    news_feed: str | None = None
    news_published_at: dt.datetime | None = None
    actual_value: float | None = None
    outcome: str | None = None

    @field_validator("stat_last3", mode="before")
    @classmethod
    def _parse_array(cls, value: Any) -> Any:
        return db.parse_variant(value)


COLUMNS: tuple[str, ...] = tuple(PropRow.model_fields)


class GamePayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    game: slate.SlateRow
    vendors: list[str] = Field(description="books with a game line or any prop for this game")
    away: list[PropRow]
    home: list[PropRow]
    query: str | None = None


def load(profile: SportProfile, game_key: str, *, vendor: str | None) -> GamePayload | None:
    """One game and its board. None when the slate has no such game."""
    book = vendor if vendor is not None else profile.default_vendor
    game_rows, game_sql = source.select(
        profile,
        slate.CAP,
        slate.COLUMNS,
        where="game_key = %(game_key)s",
        params={"game_key": game_key},
        matches=lambda r: r["game_key"] == game_key,
        order=("vendor",),
        tag="game",
    )
    if not game_rows:
        return None
    game = slate.collapse(game_rows, book)[0]

    props: list[dict[str, Any]] = []
    props_sql = ""
    if profile.has(CAP):
        props, props_sql = source.select(
            profile,
            CAP,
            COLUMNS,
            where="game_key = %(game_key)s",
            params={"game_key": game_key},
            matches=lambda r: r["game_key"] == game_key,
            order=("is_home", "player_name", "prop_type", "vendor"),
            tag="game_board",
        )
    rows = [PropRow(**p) for p in props]
    vendors = sorted(set(game.vendors_available) | {p.vendor for p in rows})
    return GamePayload(
        sport=profile.key,
        season=game.season,
        as_of=config.now(),
        game=game,
        vendors=vendors,
        away=[p for p in rows if not p.is_home],
        home=[p for p in rows if p.is_home],
        query=game_sql + ("\n\n" + props_sql if props_sql else ""),
    )
