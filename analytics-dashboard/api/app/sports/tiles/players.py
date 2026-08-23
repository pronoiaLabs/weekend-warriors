"""Players: the leaderboards and one player's season.

The leaderboard is the leaders mart for one season type, optionally one
position and one team (a team's roster is the same select with the team
bound). Ranks are mart columns, so the page sorts by whichever one it likes
without another round trip. A player page is three selects on the player's
key: every season he has in the leaders mart (the career table, and where the
default season comes from), his games in the chosen season, and the long
stat rows for the same season with the trailing and prior-season columns the
chart and the year-over-year numbers read. The defensive mart is declared as
a capability for the Explorer; no page tile reads it yet.
"""

import datetime as dt
from typing import Any

from pydantic import BaseModel

from app import config
from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.payloads import Envelope
from app.sports.profile import SportProfile
from app.sports.seasons import pick_season_type, season_types


class LeadersRow(BaseModel):
    app_player_leaders_key: str
    player_key: str
    player_id: int | None = None
    player_name: str
    position: str | None = None
    position_name: str | None = None
    position_group: str | None = None
    team_key: str | None = None
    team_label: str | None = None
    team_name: str | None = None
    teams_count: int
    season: int
    season_type: int
    season_type_name: str
    is_postseason: bool | None = None
    games: int
    first_game_date: dt.date
    last_game_date: dt.date
    passing_attempts: int | None = None
    passing_completions: int | None = None
    passing_yards: int | None = None
    passing_touchdowns: int | None = None
    passing_interceptions: int | None = None
    times_sacked: int | None = None
    completion_pct: float | None = None
    yards_per_pass_attempt: float | None = None
    rushing_attempts: int | None = None
    rushing_yards: int | None = None
    rushing_touchdowns: int | None = None
    long_rushing: int | None = None
    yards_per_rush_attempt: float | None = None
    receiving_targets: int | None = None
    receptions: int | None = None
    receiving_yards: int | None = None
    receiving_touchdowns: int | None = None
    long_reception: int | None = None
    yards_per_reception: float | None = None
    catch_rate: float | None = None
    fumbles: int | None = None
    fumbles_lost: int | None = None
    scrimmage_yards: int | None = None
    scrimmage_touchdowns: int | None = None
    scoring_touchdowns: int | None = None
    touches: int | None = None
    two_point_conversions: int | None = None
    fanduel_points: float | None = None
    draftkings_points: float | None = None
    games_with_passing: int
    games_with_rushing: int
    games_with_receiving: int
    passing_yards_per_game: float | None = None
    rushing_yards_per_game: float | None = None
    receiving_yards_per_game: float | None = None
    receptions_per_game: float | None = None
    targets_per_game: float | None = None
    scrimmage_yards_per_game: float | None = None
    touches_per_game: float | None = None
    fanduel_points_per_game: float | None = None
    draftkings_points_per_game: float | None = None
    rank_passing_yards: int
    rank_passing_touchdowns: int
    rank_rushing_yards: int
    rank_rushing_touchdowns: int
    rank_receiving_yards: int
    rank_receptions: int
    rank_receiving_touchdowns: int
    rank_scrimmage_yards: int
    rank_scoring_touchdowns: int
    rank_fanduel_points: int
    rank_draftkings_points: int
    rank_fanduel_points_per_game: int
    rank_draftkings_points_per_game: int
    players_at_position: int


class PlayerWeekRow(BaseModel):
    app_player_weeks_key: str
    player_game_key: str
    game_key: str
    game_id: int
    player_key: str
    player_id: int | None = None
    player_name: str
    position: str | None = None
    position_name: str | None = None
    position_group: str | None = None
    team_key: str | None = None
    team_id: int | None = None
    team_label: str | None = None
    team_name: str | None = None
    opponent_team_key: str | None = None
    opponent_label: str | None = None
    opponent_name: str | None = None
    is_home: bool | None = None
    season: int
    week: int
    season_type: int
    season_type_name: str
    is_postseason: bool | None = None
    game_date: dt.date
    game_datetime_et: dt.datetime
    is_completed: bool
    team_result: str | None = None
    team_points: int | None = None
    opponent_points: int | None = None
    games_to_date: int
    passing_attempts: int | None = None
    passing_completions: int | None = None
    passing_yards: int | None = None
    yards_per_pass_attempt: float | None = None
    passing_touchdowns: int | None = None
    passing_interceptions: int | None = None
    times_sacked: int | None = None
    sack_yards_lost: int | None = None
    qb_rating: float | None = None
    qbr: float | None = None
    rushing_attempts: int | None = None
    rushing_yards: int | None = None
    yards_per_rush_attempt: float | None = None
    rushing_touchdowns: int | None = None
    long_rushing: int | None = None
    receiving_targets: int | None = None
    receptions: int | None = None
    receiving_yards: int | None = None
    yards_per_reception: float | None = None
    receiving_touchdowns: int | None = None
    long_reception: int | None = None
    fumbles: int | None = None
    fumbles_lost: int | None = None
    scrimmage_yards: int | None = None
    scrimmage_touchdowns: int | None = None
    scoring_touchdowns: int | None = None
    touches: int | None = None
    has_passing: bool | None = None
    has_rushing: bool | None = None
    has_receiving: bool | None = None
    two_point_conversions: int | None = None
    two_point_conversions_thrown: int | None = None
    fanduel_points: float | None = None
    draftkings_points: float | None = None
    fanduel_points_to_date: float | None = None
    draftkings_points_to_date: float | None = None
    scrimmage_yards_to_date: int | None = None


class PlayerStatRow(BaseModel):
    app_player_week_stats_key: str
    player_game_key: str
    game_key: str
    player_key: str
    player_name: str
    position: str | None = None
    team_key: str | None = None
    team_label: str | None = None
    season: int
    week: int
    season_type: int
    season_type_name: str
    game_date: dt.date
    stat_key: str
    value: float
    games_through: int
    trailing3_avg: float | None = None
    season_avg_through: float | None = None
    season_total_through: float | None = None
    prior_season_same_week: float | None = None
    prior_season_avg: float | None = None
    prior_season_games: int | None = None
    avg_vs_prior_season: float | None = None


LEADERS_COLUMNS: tuple[str, ...] = tuple(LeadersRow.model_fields)
WEEK_COLUMNS: tuple[str, ...] = tuple(PlayerWeekRow.model_fields)
STAT_COLUMNS: tuple[str, ...] = tuple(PlayerStatRow.model_fields)
SEASON_TYPE_COLUMNS: tuple[str, ...] = ("season_type", "season_type_name", "last_game_date")


class LeadersPayload(Envelope[LeadersRow]):
    season_type_name: str
    season_types: list[str]
    position: str | None
    team: str | None


class PlayerPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    player: LeadersRow
    seasons: list[LeadersRow]
    season_type_name: str
    season_types: list[str]
    weeks: list[PlayerWeekRow]
    stats: list[PlayerStatRow]
    query: str | None = None


def leaders(
    profile: SportProfile,
    *,
    season: int | None,
    season_type_name: str | None,
    position: str | None,
    team: str | None,
) -> LeadersPayload | None:
    """Every player with a game in the season type, one position or team when
    asked. None when the season has no games, or the named season type none."""
    season = season or profile.default_season
    type_rows, types_sql = source.select(
        profile,
        C.PLAYER_LEADERS,
        SEASON_TYPE_COLUMNS,
        where="season = %(season)s",
        params={"season": season},
        matches=lambda r: r["season"] == season,
        order=("season_type",),
        tag="leaders_season_types",
    )
    chosen = pick_season_type(type_rows, season_type_name)
    if chosen is None:
        return None

    pos = position.upper() if position else None
    team_label = team.upper() if team else None
    params: dict[str, Any] = {"season": season, "season_type_name": chosen}
    where = "season = %(season)s and season_type_name = %(season_type_name)s"
    if pos is not None:
        params["position"] = pos
        where += " and position = %(position)s"
    if team_label is not None:
        params["team"] = team_label
        where += " and team_label = %(team)s"

    def matches(r: dict[str, Any]) -> bool:
        return (
            r["season"] == season
            and r["season_type_name"] == chosen
            and (pos is None or r["position"] == pos)
            and (team_label is None or r["team_label"] == team_label)
        )

    rows, sql = source.select(
        profile,
        C.PLAYER_LEADERS,
        LEADERS_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("position", "rank_fanduel_points", "player_name"),
        tag="leaders",
    )
    return LeadersPayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        season_type_name=chosen,
        season_types=season_types(type_rows),
        position=pos,
        team=team_label,
        rows=[LeadersRow(**r) for r in rows],
        query=f"{types_sql}\n\n{sql}",
    )


def player(
    profile: SportProfile,
    *,
    player_key: str,
    season: int | None,
    season_type_name: str | None,
) -> PlayerPayload | None:
    """One player's season. The season defaults to his latest; the season type
    to the one in progress within it. None when the key has no games, or none
    in the asked-for season or season type."""
    params: dict[str, Any] = {"player": player_key}
    career, career_sql = source.select(
        profile,
        C.PLAYER_LEADERS,
        LEADERS_COLUMNS,
        where="player_key = %(player)s",
        params=params,
        matches=lambda r: r["player_key"] == player_key,
        order=("season", "season_type"),
        tag="player_career",
    )
    if not career:
        return None
    season = season or max(r["season"] for r in career)
    in_season = [r for r in career if r["season"] == season]
    chosen = pick_season_type(in_season, season_type_name)
    if chosen is None:
        return None

    params["season"] = season
    where = "player_key = %(player)s and season = %(season)s"

    def matches(r: dict[str, Any]) -> bool:
        return r["player_key"] == player_key and r["season"] == season

    weeks, weeks_sql = source.select(
        profile,
        C.PLAYER_WEEKS,
        WEEK_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("game_datetime_et", "game_key"),
        tag="player_weeks",
    )
    stats, stats_sql = source.select(
        profile,
        C.PLAYER_WEEK_STATS,
        STAT_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("stat_key", "game_date", "game_key"),
        tag="player_week_stats",
    )
    return PlayerPayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        player=LeadersRow(**next(r for r in in_season if r["season_type_name"] == chosen)),
        seasons=[LeadersRow(**r) for r in career],
        season_type_name=chosen,
        season_types=season_types(in_season),
        weeks=[PlayerWeekRow(**r) for r in weeks if r["season_type_name"] == chosen],
        stats=[PlayerStatRow(**r) for r in stats if r["season_type_name"] == chosen],
        query=f"{career_sql}\n\n{weeks_sql}\n\n{stats_sql}",
    )
