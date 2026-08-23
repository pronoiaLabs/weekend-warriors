"""Teams: the standings table and one team's season.

Four marts, read as they are. The standings tile is one select of the season
(every season type and split, at most 32 x 3 x 3 rows) filtered here to the
chosen season type and split, so the chips switch without another round trip.
A team page is four selects on the team's label: its standings rows (every
split), its weeks across every book collapsed to the chosen book the way the
slate collapses games, what its defense allows by position and stat, and its
record against the number per book. The season type defaults to the one in
progress: the one whose last game is the most recent.
"""

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field, field_validator

from app import config, db
from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.payloads import Envelope
from app.sports.profile import SportProfile

SPLITS = ("all", "home", "away")


class StandingsRow(BaseModel):
    app_team_standings_key: str
    team_key: str
    team_id: int
    team_label: str
    team_name: str
    conference: str | None = None
    division: str | None = None
    season: int
    season_type: int
    season_type_name: str
    is_postseason: bool | None = None
    split: str
    games: int
    wins: int
    losses: int
    ties: int
    win_pct: float | None = None
    points_for: int | None = None
    points_against: int | None = None
    point_diff: int | None = None
    points_for_per_game: float | None = None
    points_against_per_game: float | None = None
    point_diff_per_game: float | None = None
    total_yards: int | None = None
    plays: int | None = None
    yards_per_play: float | None = None
    yards_per_game: float | None = None
    net_passing_yards: int | None = None
    rushing_yards: int | None = None
    third_down_conversions: int | None = None
    third_down_attempts: int | None = None
    third_down_pct: float | None = None
    red_zone_scores: int | None = None
    red_zone_attempts: int | None = None
    red_zone_pct: float | None = None
    turnovers: int | None = None
    takeaways: int | None = None
    turnover_margin: int | None = None
    sacks_allowed: int | None = None
    sacks_recorded: int | None = None
    opp_total_yards: int | None = None
    opp_plays: int | None = None
    opp_yards_per_play: float | None = None
    opp_yards_per_game: float | None = None
    opp_net_passing_yards: int | None = None
    opp_rushing_yards: int | None = None
    penalties: int | None = None
    penalty_yards: int | None = None
    last_game_date: dt.date | None = None
    last_results: list[str] | None = None
    rank_overall: int
    rank_conference: int
    rank_division: int

    @field_validator("last_results", mode="before")
    @classmethod
    def _parse_array(cls, value: Any) -> Any:
        return db.parse_variant(value)


class TeamWeekRow(BaseModel):
    app_team_weeks_key: str
    team_game_key: str
    game_key: str
    game_id: int
    team_key: str
    team_id: int
    team_label: str
    team_name: str
    conference: str | None = None
    division: str | None = None
    opponent_team_key: str | None = None
    opponent_label: str | None = None
    opponent_name: str | None = None
    season: int
    week: int
    season_type: int
    season_type_name: str
    is_postseason: bool | None = None
    game_date: dt.date
    game_datetime_et: dt.datetime
    kickoff_slot_et: str
    is_home: bool
    is_completed: bool
    went_to_overtime: bool | None = None
    result: str | None = None
    season_game_number: int
    wins_to_date: int
    losses_to_date: int
    ties_to_date: int
    point_diff_to_date: int
    points_for: int
    points_against: int
    point_margin: int
    total_points: int
    points_q1: int | None = None
    points_q2: int | None = None
    points_q3: int | None = None
    points_q4: int | None = None
    points_ot: int | None = None
    first_downs: int | None = None
    total_yards: int | None = None
    plays: int | None = None
    yards_per_play: float | None = None
    net_passing_yards: int | None = None
    passing_completions: int | None = None
    passing_attempts: int | None = None
    yards_per_pass: float | None = None
    rushing_yards: int | None = None
    rushing_attempts: int | None = None
    yards_per_rush_attempt: float | None = None
    third_down_conversions: int | None = None
    third_down_attempts: int | None = None
    third_down_pct: float | None = None
    fourth_down_conversions: int | None = None
    fourth_down_attempts: int | None = None
    red_zone_scores: int | None = None
    red_zone_attempts: int | None = None
    red_zone_pct: float | None = None
    total_drives: int | None = None
    possession_time_seconds: int | None = None
    turnovers: int | None = None
    takeaways: int | None = None
    turnover_margin: int | None = None
    fumbles_lost: int | None = None
    interceptions_thrown: int | None = None
    sacks_allowed: int | None = None
    sacks_recorded: int | None = None
    penalties: int | None = None
    penalty_yards: int | None = None
    opp_total_yards: int | None = None
    opp_yards_per_play: float | None = None
    opp_net_passing_yards: int | None = None
    opp_rushing_yards: int | None = None
    opp_third_down_conversions: int | None = None
    opp_third_down_attempts: int | None = None
    opp_red_zone_scores: int | None = None
    opp_red_zone_attempts: int | None = None
    opp_turnovers: int | None = None
    has_box_score: bool | None = None
    # the line from this team's side; all None when the requested book has none
    vendor: str | None = None
    spread: float | None = None
    spread_odds: float | None = None
    moneyline_odds: float | None = None
    moneyline_devig_probability: float | None = None
    opening_spread: float | None = None
    spread_movement: float | None = None
    total_line: float | None = None
    opening_total_line: float | None = None
    total_line_movement: float | None = None
    over_odds: float | None = None
    under_odds: float | None = None
    implied_team_total: float | None = None
    line_selected_at: dt.datetime | None = None
    spread_result: str | None = None
    margin_vs_spread: float | None = None
    total_result: str | None = None
    # derived here, not a mart column: every book with a line for this game
    vendors_available: list[str] = Field(default_factory=list)


class AllowedRow(BaseModel):
    app_team_allowed_key: str
    team_key: str
    team_id: int
    team_label: str
    team_name: str
    conference: str | None = None
    division: str | None = None
    season: int
    season_type: int
    season_type_name: str
    is_postseason: bool | None = None
    position: str
    stat_key: str
    defense_games: int
    allowed_total: float
    allowed_per_game: float
    league_avg_per_game: float
    allowed_vs_league: float
    allowed_rank: int
    teams_ranked: int


class AtsRow(BaseModel):
    app_team_ats_key: str
    team_key: str
    team_id: int
    team_label: str
    team_name: str
    season: int
    season_type: int
    season_type_name: str
    vendor: str
    games_with_line: int
    ats_wins: int
    ats_losses: int
    ats_pushes: int
    ats_pct: float | None = None
    overs: int
    unders: int
    total_pushes: int
    over_pct: float | None = None
    favourite_games: int
    favourite_ats_wins: int
    underdog_games: int
    underdog_ats_wins: int
    home_ats_wins: int
    home_ats_losses: int
    away_ats_wins: int
    away_ats_losses: int
    avg_spread: float | None = None
    avg_total_line: float | None = None
    avg_margin_vs_spread: float | None = None
    avg_total_vs_line: float | None = None


STANDINGS_COLUMNS: tuple[str, ...] = tuple(StandingsRow.model_fields)
WEEK_COLUMNS: tuple[str, ...] = tuple(
    f for f in TeamWeekRow.model_fields if f != "vendors_available"
)
ALLOWED_COLUMNS: tuple[str, ...] = tuple(AllowedRow.model_fields)
ATS_COLUMNS: tuple[str, ...] = tuple(AtsRow.model_fields)

# Fields that belong to the vendor row, blanked when the requested book has no line.
LINE_FIELDS: tuple[str, ...] = tuple(
    WEEK_COLUMNS[WEEK_COLUMNS.index("vendor") : WEEK_COLUMNS.index("total_result") + 1]
)


class StandingsPayload(Envelope[StandingsRow]):
    season_type_name: str
    split: str
    season_types: list[str]


class TeamPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    team: StandingsRow
    splits: list[StandingsRow]
    season_type_name: str
    season_types: list[str]
    vendor: str | None
    vendors: list[str]
    weeks: list[TeamWeekRow]
    allowed: list[AllowedRow]
    ats: list[AtsRow]
    query: str | None = None


def standings(
    profile: SportProfile,
    *,
    season: int | None,
    season_type_name: str | None,
    split: str,
) -> StandingsPayload | None:
    """The table for one season type and split. None when the season has no
    completed games, or when the named season type has none."""
    season = season or profile.default_season
    rows, sql = source.select(
        profile,
        C.TEAM_STANDINGS,
        STANDINGS_COLUMNS,
        where="season = %(season)s",
        params={"season": season},
        matches=lambda r: r["season"] == season,
        order=("season_type", "split", "rank_overall", "team_label"),
        tag="standings",
    )
    chosen = pick_season_type(rows, season_type_name)
    if chosen is None:
        return None
    return StandingsPayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        season_type_name=chosen,
        split=split,
        season_types=season_types(rows),
        rows=[
            StandingsRow(**r)
            for r in rows
            if r["season_type_name"] == chosen and r["split"] == split
        ],
        query=sql,
    )


def team(
    profile: SportProfile,
    *,
    team_label: str,
    season: int | None,
    season_type_name: str | None,
    vendor: str | None,
) -> TeamPayload | None:
    """One team's season. None when the team has no completed games in the
    season, or none in the named season type."""
    season = season or profile.default_season
    label = team_label.upper()
    params = {"season": season, "team": label}
    where = "season = %(season)s and team_label = %(team)s"

    def matches(r: dict[str, Any]) -> bool:
        return r["season"] == season and r["team_label"] == label

    st_rows, st_sql = source.select(
        profile,
        C.TEAM_STANDINGS,
        STANDINGS_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("season_type", "split"),
        tag="team_standings",
    )
    chosen = pick_season_type(st_rows, season_type_name)
    if chosen is None:
        return None
    book = vendor if vendor is not None else profile.default_vendor

    wk_rows, wk_sql = source.select(
        profile,
        C.TEAM_WEEKS,
        WEEK_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("game_datetime_et", "game_key", "vendor"),
        tag="team_weeks",
    )
    al_rows, al_sql = source.select(
        profile,
        C.TEAM_ALLOWED,
        ALLOWED_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("season_type", "position", "stat_key"),
        tag="team_allowed",
    )
    ats_rows, ats_sql = source.select(
        profile,
        C.TEAM_ATS,
        ATS_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("season_type", "vendor"),
        tag="team_ats",
    )

    splits = sorted(
        (StandingsRow(**r) for r in st_rows if r["season_type_name"] == chosen),
        key=lambda s: SPLITS.index(s.split),
    )
    in_type = [r for r in wk_rows if r["season_type_name"] == chosen]
    return TeamPayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        team=next(s for s in splits if s.split == "all"),
        splits=splits,
        season_type_name=chosen,
        season_types=season_types(st_rows),
        vendor=book,
        vendors=sorted({r["vendor"] for r in in_type if r["vendor"]}),
        weeks=collapse(in_type, book),
        allowed=[AllowedRow(**r) for r in al_rows if r["season_type_name"] == chosen],
        ats=[AtsRow(**r) for r in ats_rows if r["season_type_name"] == chosen],
        query=f"{st_sql}\n\n{wk_sql}\n\n{al_sql}\n\n{ats_sql}",
    )


def collapse(rows: list[dict[str, Any]], vendor: str | None) -> list[TeamWeekRow]:
    """One row per game, in kickoff order, carrying `vendor`'s line or none."""
    by_game: dict[str, list[dict[str, Any]]] = {}
    for r in rows:
        by_game.setdefault(r["game_key"], []).append(r)
    out: list[TeamWeekRow] = []
    for game_rows in by_game.values():
        available = sorted({r["vendor"] for r in game_rows if r["vendor"]})
        match = next((r for r in game_rows if r["vendor"] == vendor), None)
        if match is None:
            match = {**game_rows[0], **dict.fromkeys(LINE_FIELDS)}
        out.append(TeamWeekRow(**match, vendors_available=available))
    return out


def season_types(rows: list[dict[str, Any]]) -> list[str]:
    """The season types present, in calendar order (preseason first)."""
    seen: dict[str, int] = {}
    for r in rows:
        seen.setdefault(r["season_type_name"], r["season_type"])
    return sorted(seen, key=lambda name: seen[name])


def pick_season_type(rows: list[dict[str, Any]], name: str | None) -> str | None:
    """`name` when the rows have it; else the season type in progress, the one
    whose most recent game is latest; None when there is nothing."""
    if not rows:
        return None
    if name is not None:
        return name if any(r["season_type_name"] == name for r in rows) else None
    latest = max(rows, key=lambda r: (str(r.get("last_game_date") or ""), r["season_type"]))
    return latest["season_type_name"]
