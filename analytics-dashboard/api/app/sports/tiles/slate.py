"""The game day board: one row per game for one week, with the line from one book.

Two selects on app_game_slate. The first lists the season's weeks (for the
picker and to resolve the default week); the second reads the chosen week across
every vendor, and the rows are collapsed here to one per game carrying the
requested vendor's line, or no line when that book has none for the game. That
collapse is the only shaping: a game with lines from other books keeps its card.
"""

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field

from app import config
from app.sports import source
from app.sports.capabilities import Capability
from app.sports.payloads import Envelope
from app.sports.profile import SportProfile

CAP = Capability.SCHEDULE


class SlateRow(BaseModel):
    app_game_slate_key: str
    game_key: str
    game_id: int
    season: int
    week: int
    season_type: int
    season_type_name: str
    game_date: dt.date
    game_datetime_et: dt.datetime
    kickoff_slot_et: str
    game_status: str | None = None
    is_completed: bool
    went_to_overtime: bool | None = None
    home_team_key: str
    home_team_label: str
    home_team_name: str
    home_conference: str | None = None
    home_division: str | None = None
    away_team_key: str
    away_team_label: str
    away_team_name: str
    away_conference: str | None = None
    away_division: str | None = None
    venue: str | None = None
    stadium_name: str | None = None
    roof: str | None = None
    surface: str | None = None
    is_weather_relevant: bool | None = None
    is_international: bool | None = None
    kickoff_temp_f: float | None = None
    wind_mph: float | None = None
    gust_mph: float | None = None
    precip_in: float | None = None
    weather_code: int | None = None
    forecast_hours_before_kickoff: int | None = None
    # the line, from the requested vendor; all None when that book has no line
    vendor: str | None = None
    home_spread: float | None = None
    away_spread: float | None = None
    home_spread_odds: float | None = None
    away_spread_odds: float | None = None
    total_line: float | None = None
    over_odds: float | None = None
    under_odds: float | None = None
    home_moneyline_odds: float | None = None
    away_moneyline_odds: float | None = None
    opening_home_spread: float | None = None
    opening_total_line: float | None = None
    home_spread_movement: float | None = None
    total_line_movement: float | None = None
    implied_home_team_total: float | None = None
    implied_away_team_total: float | None = None
    home_moneyline_devig_probability: float | None = None
    away_moneyline_devig_probability: float | None = None
    line_selected_at: dt.datetime | None = None
    home_spread_result: str | None = None
    total_result: str | None = None
    # result and readiness
    home_score: int | None = None
    away_score: int | None = None
    props_open: int = 0
    players_with_props: int = 0
    props_open_all_books: int = 0
    players_with_props_all_books: int = 0
    news_mentions_7d: int = 0
    players_in_news_7d: int = 0
    # derived here, not a mart column: every book with a line for this game
    vendors_available: list[str] = Field(default_factory=list)


# The mart columns the tile selects: every model field except the derived one.
COLUMNS: tuple[str, ...] = tuple(f for f in SlateRow.model_fields if f != "vendors_available")

# Fields that belong to the vendor row, blanked when the requested book has no line.
LINE_FIELDS: tuple[str, ...] = tuple(
    COLUMNS[COLUMNS.index("vendor") : COLUMNS.index("total_result") + 1]
)

WEEK_COLUMNS: tuple[str, ...] = ("season", "season_type", "season_type_name", "week")


class WeekRef(BaseModel):
    season: int
    season_type: int
    season_type_name: str
    week: int
    games: int
    completed: int
    first_kickoff: dt.datetime
    last_kickoff: dt.datetime


class SlatePayload(Envelope[SlateRow]):
    season_type_name: str
    week: int
    vendor: str | None
    weeks: list[WeekRef]


def weeks(profile: SportProfile, season: int) -> tuple[list[WeekRef], str]:
    """Every (season type, week) in the season with its game count, kickoff span
    and completed count, ordered by first kickoff."""
    rows, sql = source.select(
        profile,
        CAP,
        ("game_key", "is_completed", "game_datetime_et", *WEEK_COLUMNS),
        where="season = %(season)s",
        params={"season": season},
        matches=lambda r: r["season"] == season,
        order=("game_datetime_et", "game_key"),
        tag="slate_weeks",
    )
    grouped: dict[tuple[int, int], dict[str, Any]] = {}
    seen: set[tuple[int, int, str]] = set()
    for r in rows:
        k = (r["season_type"], r["week"])
        kick = _ts(r["game_datetime_et"])
        entry = grouped.setdefault(
            k,
            {
                "season": season,
                "season_type": r["season_type"],
                "season_type_name": r["season_type_name"],
                "week": r["week"],
                "games": 0,
                "completed": 0,
                "first_kickoff": kick,
                "last_kickoff": kick,
            },
        )
        if (*k, r["game_key"]) in seen:
            continue  # one row per vendor; count the game once
        seen.add((*k, r["game_key"]))
        entry["games"] += 1
        entry["completed"] += int(bool(r["is_completed"]))
        entry["first_kickoff"] = min(entry["first_kickoff"], kick)
        entry["last_kickoff"] = max(entry["last_kickoff"], kick)
    ordered = sorted(grouped.values(), key=lambda e: e["first_kickoff"])
    return [WeekRef(**e) for e in ordered], sql


def current_week(refs: list[WeekRef], now: dt.datetime) -> WeekRef | None:
    """The first week whose last kickoff is still ahead of `now`; after the season,
    its last week."""
    if not refs:
        return None
    for ref in refs:
        if ref.last_kickoff >= now:
            return ref
    return refs[-1]


def load(
    profile: SportProfile,
    *,
    season: int | None,
    season_type_name: str | None,
    week: int | None,
    vendor: str | None,
) -> SlatePayload | None:
    """The board for one week. None when the season has no games at all."""
    season = season or profile.default_season
    refs, weeks_sql = weeks(profile, season)
    chosen = _pick_week(refs, season_type_name, week, config.now())
    if chosen is None:
        return None
    book = vendor if vendor is not None else profile.default_vendor

    params = {"season": season, "season_type_name": chosen.season_type_name, "week": chosen.week}
    rows, sql = source.select(
        profile,
        CAP,
        COLUMNS,
        where="season = %(season)s and season_type_name = %(season_type_name)s and week = %(week)s",
        params=params,
        matches=lambda r: (
            r["season"] == season
            and r["season_type_name"] == chosen.season_type_name
            and r["week"] == chosen.week
        ),
        order=("game_datetime_et", "game_key", "vendor"),
        tag="slate",
    )
    return SlatePayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        season_type_name=chosen.season_type_name,
        week=chosen.week,
        vendor=book,
        weeks=refs,
        rows=collapse(rows, book),
        query=weeks_sql + "\n\n" + sql,
    )


def collapse(rows: list[dict[str, Any]], vendor: str | None) -> list[SlateRow]:
    """One row per game, in kickoff order, carrying `vendor`'s line or none."""
    by_game: dict[str, list[dict[str, Any]]] = {}
    for r in rows:
        by_game.setdefault(r["game_key"], []).append(r)
    out: list[SlateRow] = []
    for game_rows in by_game.values():
        available = sorted({r["vendor"] for r in game_rows if r["vendor"]})
        match = next((r for r in game_rows if r["vendor"] == vendor), None)
        if match is None:
            match = {**game_rows[0], **dict.fromkeys(LINE_FIELDS)}
        out.append(SlateRow(**match, vendors_available=available))
    return out


def _pick_week(
    refs: list[WeekRef], season_type_name: str | None, week: int | None, now: dt.datetime
) -> WeekRef | None:
    if season_type_name is None and week is None:
        return current_week(refs, now)
    pool = [r for r in refs if season_type_name is None or r.season_type_name == season_type_name]
    if week is None:
        return current_week(pool, now)
    return next((r for r in pool if r.week == week), None)


def _ts(value: Any) -> dt.datetime:
    if isinstance(value, dt.datetime):
        return value
    return dt.datetime.fromisoformat(str(value))
