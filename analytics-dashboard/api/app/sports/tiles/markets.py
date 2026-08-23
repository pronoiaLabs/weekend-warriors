"""Markets: a week's line movement at one book, and one game's full history.

The board reads the line history mart for the chosen week and book (every
pregame snapshot where the line moved, in kickoff and snapshot order); the
page groups the rows by game and draws the path. The week list and the
default week come from the same mart through the slate tile's helper, so a
week appears only once a book has priced it. A game page reads every book's
path for the game plus the chosen book's prop paths; the prop rows can run to
thousands for a book that re-snapshots every tick, which is why they are
bound to one book rather than served for all.
"""

import datetime as dt
from typing import Any

from pydantic import BaseModel

from app import config
from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.payloads import Envelope
from app.sports.profile import SportProfile
from app.sports.tiles import slate


class LineRow(BaseModel):
    app_line_history_key: str
    game_vendor_odds_key: str
    game_key: str
    game_id: int
    season: int
    week: int
    season_type: int
    season_type_name: str
    game_date: dt.date
    game_datetime_et: dt.datetime
    is_completed: bool
    home_team_key: str
    home_team_label: str | None = None
    home_team_name: str | None = None
    away_team_key: str
    away_team_label: str | None = None
    away_team_name: str | None = None
    vendor: str
    snapshot_number: int
    snapshots_before_kickoff: int
    is_opening: bool
    is_closing: bool
    snapshot_observed_at: dt.datetime
    prev_snapshot_observed_at: dt.datetime | None = None
    minutes_before_kickoff: float | None = None
    hours_before_kickoff: float | None = None
    home_spread: float | None = None
    home_spread_odds: float | None = None
    away_spread: float | None = None
    away_spread_odds: float | None = None
    home_moneyline_odds: float | None = None
    away_moneyline_odds: float | None = None
    total_line: float | None = None
    over_odds: float | None = None
    under_odds: float | None = None
    home_spread_change: float | None = None
    total_line_change: float | None = None
    home_moneyline_odds_change: float | None = None
    away_moneyline_odds_change: float | None = None
    home_spread_since_open: float | None = None
    total_line_since_open: float | None = None


class PropLineRow(BaseModel):
    app_prop_line_history_key: str
    game_player_vendor_prop_key: str
    game_key: str
    game_id: int
    player_key: str
    player_id: int | None = None
    player_name: str | None = None
    position: str | None = None
    season: int
    week: int
    season_type: int
    season_type_name: str
    game_date: dt.date
    game_datetime_et: dt.datetime
    is_completed: bool
    home_team_key: str
    home_team_label: str | None = None
    away_team_key: str
    away_team_label: str | None = None
    vendor: str
    prop_type: str
    market_type: str
    stat_key: str | None = None
    stat_label: str | None = None
    snapshot_number: int
    snapshots_before_kickoff: int
    is_opening: bool
    is_closing: bool
    snapshot_observed_at: dt.datetime
    prev_snapshot_observed_at: dt.datetime | None = None
    minutes_before_kickoff: float | None = None
    hours_before_kickoff: float | None = None
    line_value: float | None = None
    market_odds: float | None = None
    over_odds: float | None = None
    under_odds: float | None = None
    line_value_change: float | None = None
    market_odds_change: float | None = None
    over_odds_change: float | None = None
    under_odds_change: float | None = None
    line_value_since_open: float | None = None


LINE_COLUMNS: tuple[str, ...] = tuple(LineRow.model_fields)
PROP_COLUMNS: tuple[str, ...] = tuple(PropLineRow.model_fields)


class MarketsPayload(Envelope[LineRow]):
    season_type_name: str
    week: int
    vendor: str | None
    weeks: list[slate.WeekRef]


class GameRef(BaseModel):
    game_key: str
    season: int
    week: int
    season_type_name: str
    game_date: dt.date
    game_datetime_et: dt.datetime
    is_completed: bool
    home_team_label: str | None = None
    home_team_name: str | None = None
    away_team_label: str | None = None
    away_team_name: str | None = None


class GameMarketsPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    game: GameRef
    vendor: str | None
    vendors: list[str]
    lines: list[LineRow]
    props: list[PropLineRow]
    query: str | None = None


def board(
    profile: SportProfile,
    *,
    season: int | None,
    season_type_name: str | None,
    week: int | None,
    vendor: str | None,
) -> MarketsPayload | None:
    """One week's line movement at one book. None when no week of the season
    has a line, or the named week has none."""
    season = season or profile.default_season
    refs, weeks_sql = slate.weeks(profile, season, cap=C.LINE_HISTORY, tag="markets_weeks")
    chosen = slate.pick_week(refs, season_type_name, week, config.now())
    if chosen is None:
        return None
    book = vendor if vendor is not None else profile.default_vendor
    params = {
        "season": season,
        "season_type_name": chosen.season_type_name,
        "week": chosen.week,
        "vendor": book,
    }
    rows, sql = source.select(
        profile,
        C.LINE_HISTORY,
        LINE_COLUMNS,
        where=(
            "season = %(season)s and season_type_name = %(season_type_name)s"
            " and week = %(week)s and vendor = %(vendor)s"
        ),
        params=params,
        matches=lambda r: (
            r["season"] == season
            and r["season_type_name"] == chosen.season_type_name
            and r["week"] == chosen.week
            and r["vendor"] == book
        ),
        order=("game_datetime_et", "game_key", "snapshot_number"),
        tag="markets",
    )
    return MarketsPayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        season_type_name=chosen.season_type_name,
        week=chosen.week,
        vendor=book,
        weeks=refs,
        rows=[LineRow(**r) for r in rows],
        query=f"{weeks_sql}\n\n{sql}",
    )


def game(profile: SportProfile, *, game_key: str, vendor: str | None) -> GameMarketsPayload | None:
    """Every book's line path for one game, and the chosen book's prop paths.
    None when no book has priced the game."""
    lines, lines_sql = source.select(
        profile,
        C.LINE_HISTORY,
        LINE_COLUMNS,
        where="game_key = %(game_key)s",
        params={"game_key": game_key},
        matches=lambda r: r["game_key"] == game_key,
        order=("vendor", "snapshot_number"),
        tag="market_lines",
    )
    if not lines:
        return None
    book = vendor if vendor is not None else profile.default_vendor
    props, props_sql = source.select(
        profile,
        C.PROP_LINE_HISTORY,
        PROP_COLUMNS,
        where="game_key = %(game_key)s and vendor = %(vendor)s",
        params={"game_key": game_key, "vendor": book},
        matches=lambda r: r["game_key"] == game_key and r["vendor"] == book,
        order=("player_name", "prop_type", "snapshot_number"),
        tag="market_props",
    )
    first: dict[str, Any] = lines[0]
    return GameMarketsPayload(
        sport=profile.key,
        season=first["season"],
        as_of=config.now(),
        game=GameRef(**{k: first[k] for k in GameRef.model_fields}),
        vendor=book,
        vendors=sorted({r["vendor"] for r in lines}),
        lines=[LineRow(**r) for r in lines],
        props=[PropLineRow(**r) for r in props],
        query=f"{lines_sql}\n\n{props_sql}",
    )
