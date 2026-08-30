"""The game page: one game's slate row, its prop board split by side, and the
overview's availability and defense-allowed zones.

Up to four selects, each gated on the sport having the mart. The game's slate
rows (every vendor) collapse to the requested book's line exactly as the board
does; the prop board rows for the game come back for every vendor so the page
can switch books and stat families without another round trip; availability is
the status board bound on game_key; allowed is both defenses' position x stat
rows for the game's season, the prior season standing in until this one has
games. Rows are split into the away and home columns here; nothing else is
computed, the marts already carry form, line, gap, hit rate and ranks.
"""

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field, field_validator

from app import config, db
from app.sports import source
from app.sports.capabilities import Capability
from app.sports.profile import SportProfile
from app.sports.tiles import slate, status_board, teams

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
    # the overview's zones, each present only when the sport has the mart:
    # per-player designations for this game (the status board bound on game_key)
    availability: list[status_board.StatusRow] = Field(default_factory=list)
    # what each side's defense allows by position and stat; the season the rows
    # describe rides on them (falls back to the prior season until this one has games)
    allowed: list[teams.AllowedRow] = Field(default_factory=list)
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

    availability: list[status_board.StatusRow] = []
    avail_sql = ""
    if profile.has(status_board.C.STATUS_BOARD):
        avail_rows, avail_sql = source.select(
            profile,
            status_board.C.STATUS_BOARD,
            status_board.COLUMNS,
            where="game_key = %(game_key)s",
            params={"game_key": game_key},
            matches=lambda r: r["game_key"] == game_key,
            order=("designation_order", "report_modified_at desc", "player_key"),
            tag="game_availability",
        )
        availability = [status_board.StatusRow(**r) for r in avail_rows]

    allowed: list[teams.AllowedRow] = []
    allowed_sql = ""
    if profile.has(Capability.TEAM_ALLOWED):
        for season_try in (game.season, game.season - 1):
            allowed_rows, allowed_sql = source.select(
                profile,
                Capability.TEAM_ALLOWED,
                teams.ALLOWED_COLUMNS,
                where=(
                    "season = %(season)s and season_type_name = %(season_type_name)s"
                    " and team_key in (%(home)s, %(away)s)"
                ),
                params={
                    "season": season_try,
                    "season_type_name": "Regular Season",
                    "home": game.home_team_key,
                    "away": game.away_team_key,
                },
                matches=lambda r, s=season_try: (
                    r["season"] == s
                    and r["season_type_name"] == "Regular Season"
                    and r["team_key"] in (game.home_team_key, game.away_team_key)
                ),
                order=("team_key", "allowed_rank"),
                tag="game_allowed",
            )
            if allowed_rows:
                allowed = [teams.AllowedRow(**r) for r in allowed_rows]
                break

    parts = [game_sql, props_sql, avail_sql, allowed_sql]
    return GamePayload(
        sport=profile.key,
        season=game.season,
        as_of=config.now(),
        game=game,
        vendors=vendors,
        away=[p for p in rows if not p.is_home],
        home=[p for p in rows if p.is_home],
        availability=availability,
        allowed=allowed,
        query="\n\n".join(p for p in parts if p),
    )
