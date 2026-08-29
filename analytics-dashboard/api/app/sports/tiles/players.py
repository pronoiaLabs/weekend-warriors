"""Players: the finder's leaderboard and one player's rooms.

The leaderboard is the leaders mart for one season type, optionally one
position and one team (a team's roster is the same select with the team
bound). Ranks, the usage aggregates and the riser window are mart columns,
so the page sorts by whichever it likes without another round trip -- the
Risers rail is a client-side sort of the same rows. A player page is four
selects on the player's key: his seasons in the leaders mart (the career
rows, and where the default season comes from), his profile header row, his
games in the chosen season and type, and the long stat rows with the
trailing and prior-season columns the chart reads. Situational usage and
the prop history are sub-routes (the game family's precedent): usage reads
its own mart, props reads the game prop board player-scoped -- same mart the
game page reads, so the two pages agree. The defensive mart is declared as
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
    # vendor coverage: how many of the games carry the nflverse / Sleeper blocks
    games_with_nflverse: int
    games_with_sleeper: int
    headshot_url: str | None = None
    # usage aggregates, each with its honest computation (see the mart header):
    # target_share and snap_share are ratios of sums, air_yards_share_avg is a
    # marked average-of-shares convention
    target_share: float | None = None
    air_yards_share_avg: float | None = None
    snap_share: float | None = None
    passing_epa: float | None = None
    rushing_epa: float | None = None
    receiving_epa: float | None = None
    ppr_points: float | None = None
    ppr_points_per_game: float | None = None
    sleeper_ppr_points: float | None = None
    # the riser window: last three games' target share vs the season before it;
    # delta NULL unless both windows hold two observations
    target_share_last3: float | None = None
    last3_share_games: int | None = None
    target_share_prior: float | None = None
    prior_share_games: int | None = None
    target_share_delta: float | None = None
    # current-state next game: populated only when the team's next game falls
    # in this row's own season and season type
    next_game_key: str | None = None
    next_opponent_team_key: str | None = None
    next_opponent_label: str | None = None
    next_is_home: bool | None = None
    next_game_datetime_et: dt.datetime | None = None
    next_opp_allowed_rank: int | None = None
    next_opp_allowed_teams_ranked: int | None = None
    next_opp_allowed_season: int | None = None
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
    rank_target_share: int
    rank_snap_share: int
    rank_ppr_points: int
    rank_ppr_points_per_game: int
    rank_receiving_epa: int
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
    # vendor blocks: NULL means no vendor match (has_nflverse / has_sleeper
    # say which), never zero
    target_share: float | None = None
    air_yards_share: float | None = None
    receiving_air_yards: int | None = None
    team_targets: int | None = None
    snap_pct: float | None = None
    offense_pct: float | None = None
    off_snaps: int | None = None
    team_off_snaps: int | None = None
    passing_epa: float | None = None
    rushing_epa: float | None = None
    receiving_epa: float | None = None
    ppr_points: float | None = None
    sleeper_ppr_points: float | None = None
    sleeper_ppr_pos_rank: int | None = None
    has_nflverse: bool | None = None
    has_sleeper: bool | None = None
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
    value: float | None = None
    games_through: int
    values_through: int
    trailing3_avg: float | None = None
    season_avg_through: float | None = None
    season_total_through: float | None = None
    prior_season_same_week: float | None = None
    prior_season_avg: float | None = None
    prior_season_games: int | None = None
    avg_vs_prior_season: float | None = None


class ProfileRow(BaseModel):
    """The identity header: bio, draft, headshot, the Sleeper live block
    (current state, as-of news_updated_at) and the resolved current team."""

    app_player_profile_key: str
    player_key: str
    player_id: int | None = None
    player_name: str
    first_name: str | None = None
    last_name: str | None = None
    position: str | None = None
    position_name: str | None = None
    position_group: str | None = None
    jersey_number: str | None = None
    headshot_url: str | None = None
    age: int | None = None
    birth_date: dt.date | None = None
    height_inches: int | None = None
    weight_lbs: int | None = None
    college_display: str | None = None
    draft_year: int | None = None
    draft_round: int | None = None
    draft_pick: int | None = None
    draft_team: str | None = None
    seasons_experience: int | None = None
    is_rookie: bool | None = None
    rookie_season: int | None = None
    injury_status: str | None = None
    injury_body_part: str | None = None
    injury_notes: str | None = None
    practice_participation: str | None = None
    practice_description: str | None = None
    news_updated_at: dt.datetime | None = None
    team_key: str | None = None
    team_label: str | None = None
    team_name: str | None = None
    team_source: str | None = None
    next_game_key: str | None = None
    next_opponent_team_key: str | None = None
    next_opponent_label: str | None = None
    next_is_home: bool | None = None
    next_game_datetime_et: dt.datetime | None = None
    next_season: int | None = None
    next_week: int | None = None
    next_season_type_name: str | None = None


class UsageRow(BaseModel):
    """One situational cell: targets over team targets in the player's own
    games, with team dropbacks as the routes stand-in and the qualified
    same-position league share as the baseline."""

    app_player_situation_usage_key: str
    player_key: str
    player_name: str
    position: str | None = None
    season: int
    season_type: int
    season_type_name: str
    bucket_type: str
    bucket: str
    bucket_label: str
    bucket_order: int
    targets: int
    team_targets: int | None = None
    team_dropbacks: int | None = None
    games: int
    target_share: float | None = None
    league_pos_avg_share: float | None = None
    league_qualifying_players: int | None = None
    share_vs_league: float | None = None


class PlayerPropRow(BaseModel):
    """The market's history on this player: one prop at one book for one game,
    a subset of the prop board's columns (same mart, player-scoped)."""

    app_game_prop_board_key: str
    game_key: str
    season: int
    week: int
    season_type_name: str
    game_datetime_et: dt.datetime
    is_completed: bool
    player_key: str
    player_name: str
    opponent_label: str | None = None
    is_home: bool | None = None
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
    projection_value: float | None = None
    projection_vs_line: float | None = None
    has_projection: bool = False
    actual_value: float | None = None
    outcome: str | None = None


LEADERS_COLUMNS: tuple[str, ...] = tuple(LeadersRow.model_fields)
WEEK_COLUMNS: tuple[str, ...] = tuple(PlayerWeekRow.model_fields)
STAT_COLUMNS: tuple[str, ...] = tuple(PlayerStatRow.model_fields)
PROFILE_COLUMNS: tuple[str, ...] = tuple(ProfileRow.model_fields)
USAGE_COLUMNS: tuple[str, ...] = tuple(UsageRow.model_fields)
PROP_COLUMNS: tuple[str, ...] = tuple(PlayerPropRow.model_fields)
SEASON_TYPE_COLUMNS: tuple[str, ...] = ("season", "season_type", "season_type_name", "last_game_date")


class LeadersPayload(Envelope[LeadersRow]):
    season_type_name: str
    season_types: list[str]
    seasons: list[int]
    position: str | None
    team: str | None


class PlayerPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    player: LeadersRow
    profile: ProfileRow | None = None
    seasons: list[LeadersRow]
    season_type_name: str
    season_types: list[str]
    weeks: list[PlayerWeekRow]
    stats: list[PlayerStatRow]
    query: str | None = None


class PlayerUsagePayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    player_key: str
    player_name: str
    position: str | None
    season_type_name: str
    rows: list[UsageRow]
    query: str | None = None


class PlayerPropsPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    player_key: str
    player_name: str
    position: str | None
    vendor: str | None
    stat_key: str | None
    history: list[PlayerPropRow]
    current: list[PlayerPropRow]
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
    # one unbound probe serves two needs: the season list for the finder's
    # Season control, and the chosen season's types (the same over-fetch class
    # the per-season probe already accepted -- one thin row per player-season)
    type_rows, types_sql = source.select(
        profile,
        C.PLAYER_LEADERS,
        SEASON_TYPE_COLUMNS,
        where="1 = 1",
        params={},
        matches=lambda r: True,
        order=("season", "season_type"),
        tag="leaders_season_types",
    )
    seasons_list = sorted({r["season"] for r in type_rows}, reverse=True)
    in_season = [r for r in type_rows if r["season"] == season]
    chosen = pick_season_type(in_season, season_type_name)
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
        season_types=season_types(in_season),
        seasons=seasons_list,
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

    profile_rows, profile_sql = source.select(
        profile,
        C.PLAYER_PROFILE,
        PROFILE_COLUMNS,
        where="player_key = %(player)s",
        params={"player": player_key},
        matches=lambda r: r["player_key"] == player_key,
        order=("player_key",),
        tag="player_profile",
    )

    params["season"] = season
    params["season_type_name"] = chosen
    where = (
        "player_key = %(player)s and season = %(season)s"
        " and season_type_name = %(season_type_name)s"
    )

    def matches(r: dict[str, Any]) -> bool:
        return (
            r["player_key"] == player_key
            and r["season"] == season
            and r["season_type_name"] == chosen
        )

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
        profile=ProfileRow(**profile_rows[0]) if profile_rows else None,
        seasons=[LeadersRow(**r) for r in career],
        season_type_name=chosen,
        season_types=season_types(in_season),
        weeks=[PlayerWeekRow(**r) for r in weeks],
        stats=[PlayerStatRow(**r) for r in stats],
        query=f"{career_sql}\n\n{profile_sql}\n\n{weeks_sql}\n\n{stats_sql}",
    )


def _career(
    profile: SportProfile, player_key: str, tag: str
) -> tuple[list[dict[str, Any]], str]:
    """The player's leaders rows: identity, his seasons, and the default-season
    source for the sub-routes. Same select the player payload starts with."""
    return source.select(
        profile,
        C.PLAYER_LEADERS,
        LEADERS_COLUMNS,
        where="player_key = %(player)s",
        params={"player": player_key},
        matches=lambda r: r["player_key"] == player_key,
        order=("season", "season_type"),
        tag=tag,
    )


def usage(
    profile: SportProfile,
    *,
    player_key: str,
    season: int | None,
    season_type_name: str | None,
) -> PlayerUsagePayload | None:
    """One player's situational usage for a season. None when the key has no
    games or the asked-for season type none; an empty rows list is honest --
    preseason has no play-by-play."""
    career, career_sql = _career(profile, player_key, "usage_player")
    if not career:
        return None
    season = season or max(r["season"] for r in career)
    in_season = [r for r in career if r["season"] == season]
    chosen = pick_season_type(in_season, season_type_name)
    if chosen is None:
        return None

    rows, sql = source.select(
        profile,
        C.PLAYER_SITUATION_USAGE,
        USAGE_COLUMNS,
        where=(
            "player_key = %(player)s and season = %(season)s"
            " and season_type_name = %(season_type_name)s"
        ),
        params={"player": player_key, "season": season, "season_type_name": chosen},
        matches=lambda r: (
            r["player_key"] == player_key
            and r["season"] == season
            and r["season_type_name"] == chosen
        ),
        order=("bucket_type", "bucket_order"),
        tag="player_usage",
    )
    latest = career[-1]
    return PlayerUsagePayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        player_key=player_key,
        player_name=latest["player_name"],
        position=latest["position"],
        season_type_name=chosen,
        rows=[UsageRow(**r) for r in rows],
        query=f"{career_sql}\n\n{sql}",
    )


# the prop the market writes most for each position: the props sub-route's
# default stat when the caller names none
POSITION_STAT_KEY = {
    "QB": "passing_yards",
    "RB": "rushing_yards",
    "WR": "receiving_yards",
    "TE": "receiving_yards",
}


def props(
    profile: SportProfile,
    *,
    player_key: str,
    season: int | None,
    vendor: str | None,
    stat_key: str | None,
) -> PlayerPropsPayload | None:
    """The market's history on this player: his props at one book for one
    season, split into completed games (the track record) and pending ones.
    None when the key has no games; empty lists are honest -- the odds feed
    starts in 2026."""
    career, career_sql = _career(profile, player_key, "props_player")
    if not career:
        return None
    latest = career[-1]
    # the market is about now: props default to the sport's current season, not
    # the player's latest completed one (lines post before he has a game in it)
    season = season or profile.default_season
    book = vendor if vendor is not None else profile.default_vendor
    stat = stat_key or POSITION_STAT_KEY.get(latest["position"] or "")

    params: dict[str, Any] = {"player": player_key, "season": season}
    where = "player_key = %(player)s and season = %(season)s"
    if book is not None:
        params["vendor"] = book
        where += " and vendor = %(vendor)s"
    if stat is not None:
        params["stat_key"] = stat
        where += " and stat_key = %(stat_key)s"

    def matches(r: dict[str, Any]) -> bool:
        return (
            r["player_key"] == player_key
            and r["season"] == season
            and (book is None or r["vendor"] == book)
            and (stat is None or r["stat_key"] == stat)
        )

    rows, sql = source.select(
        profile,
        C.GAME_PROP_BOARD,
        PROP_COLUMNS,
        where=where,
        params=params,
        matches=matches,
        order=("week", "prop_type", "game_key"),
        tag="player_props",
    )
    return PlayerPropsPayload(
        sport=profile.key,
        season=season,
        as_of=config.now(),
        player_key=player_key,
        player_name=latest["player_name"],
        position=latest["position"],
        vendor=book,
        stat_key=stat,
        history=[PlayerPropRow(**r) for r in rows if r["is_completed"]],
        current=[PlayerPropRow(**r) for r in rows if not r["is_completed"]],
        query=f"{career_sql}\n\n{sql}",
    )
