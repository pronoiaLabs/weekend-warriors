"""The Play Log: every play, drive by drive, at the grain where patterns live.

One anchored, bound select on the play feed. The anchor rule is the honest
volume cap: at least one of game_key / player_key / team must bind (a game is
~165 rows, a player-season tops out near 1,100, a team-season near 2,000), so
each response is one shot -- no paging, and the mart's drive rollup columns
mean the page groups rows by (game_key, drive_number) and rolls nothing up.
A player anchors any of the three role columns. When a player anchors, the
payload also carries his situational-usage rows (the pinned strip); a game or
team arrival has no subject, so the strip stays empty -- the two arrival
shapes. The session-agent write-back (filters as Postgres session state) is a
later arc; every filter here is a plain query param.
"""

import datetime as dt
from typing import Any

from pydantic import BaseModel, Field

from app import config
from app.sports import source
from app.sports.capabilities import Capability as C
from app.sports.profile import SportProfile
from app.sports.tiles import players

LIMIT = 2000


class PlayRow(BaseModel):
    app_play_log_key: str
    play_key: str
    game_key: str
    team_key: str | None = None
    opponent_team_key: str | None = None
    season: int
    week: int
    season_type: int
    season_type_name: str | None = None
    is_postseason: bool | None = None
    game_date: dt.date
    team_label: str | None = None
    opponent_label: str | None = None
    is_home_possession: bool | None = None
    quarter: int | None = None
    clock_display: str | None = None
    clock_seconds_remaining: int | None = None
    score_differential: int | None = None
    game_script: str | None = None
    home_score_after_play: int | None = None
    away_score_after_play: int | None = None
    drive_number: int | None = None
    play_in_drive: int | None = None
    series_result: str | None = None
    drive_play_count: int | None = None
    drive_yards: int | None = None
    drive_time_of_possession: str | None = None
    drive_result: str | None = None
    down: int | None = None
    distance: int | None = None
    yards_to_endzone: int | None = None
    down_bucket: str | None = None
    distance_bucket: str | None = None
    field_zone: str | None = None
    is_red_zone: bool | None = None
    is_third_down: bool | None = None
    is_fourth_down: bool | None = None
    is_two_minute: bool | None = None
    shotgun: bool | None = None
    no_huddle: bool | None = None
    play_type: str | None = None
    play_category: str | None = None
    play_family: str | None = None
    pass_length: str | None = None
    pass_location: str | None = None
    run_location: str | None = None
    run_gap: str | None = None
    passer_player_key: str | None = None
    passer_name: str | None = None
    rusher_player_key: str | None = None
    rusher_name: str | None = None
    receiver_player_key: str | None = None
    receiver_name: str | None = None
    yards_gained: int | None = None
    epa: float | None = None
    wpa: float | None = None
    success: bool | None = None
    achieved_first_down: bool | None = None
    is_touchdown: bool | None = None
    is_scoring_play: bool | None = None
    air_yards: int | None = None
    yards_after_catch: int | None = None
    play_description: str | None = None
    has_nflverse: bool | None = None
    is_epa_play: bool | None = None


COLUMNS: tuple[str, ...] = tuple(PlayRow.model_fields)

# the situational filters a page or an arrival can bind, each a mart column
SITUATION_PARAMS = ("down_bucket", "distance_bucket", "field_zone", "script", "play_family")


class PlaysPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    rows: list[PlayRow]
    has_more: bool
    # the pinned strip: populated only when a player anchors the request
    player_key: str | None = None
    player_name: str | None = None
    usage: list[players.UsageRow] = Field(default_factory=list)
    query: str | None = None


def load(
    profile: SportProfile,
    *,
    season: int | None,
    week: int | None,
    game_key: str | None,
    player_key: str | None,
    team: str | None,
    down_bucket: str | None,
    distance_bucket: str | None,
    field_zone: str | None,
    script: str | None,
    play_family: str | None,
    shotgun: bool | None,
    no_huddle: bool | None,
) -> PlaysPayload | None:
    """The anchored play feed. The router enforces the anchor rule before
    calling; season defaults to the sport's current one when only a player or
    team anchors (a bare game_key needs no season)."""
    season = season if season is not None else (None if game_key else profile.default_season)

    clauses: list[str] = []
    params: dict[str, Any] = {}

    def bind(clause: str, name: str, value: Any) -> None:
        clauses.append(clause)
        params[name] = value

    if game_key is not None:
        bind("game_key = %(game_key)s", "game_key", game_key)
    if season is not None:
        bind("season = %(season)s", "season", season)
    if week is not None:
        bind("week = %(week)s", "week", week)
    if team is not None:
        bind("team_label = %(team)s", "team", team.upper())
    if player_key is not None:
        bind(
            "(passer_player_key = %(player_key)s or rusher_player_key = %(player_key)s"
            " or receiver_player_key = %(player_key)s)",
            "player_key",
            player_key,
        )
    if down_bucket is not None:
        bind("down_bucket = %(down_bucket)s", "down_bucket", down_bucket)
    if distance_bucket is not None:
        bind("distance_bucket = %(distance_bucket)s", "distance_bucket", distance_bucket)
    if field_zone is not None:
        bind("field_zone = %(field_zone)s", "field_zone", field_zone)
    if script is not None:
        bind("game_script = %(script)s", "script", script)
    if play_family is not None:
        bind("play_family = %(play_family)s", "play_family", play_family)
    if shotgun is not None:
        bind("shotgun = %(shotgun)s", "shotgun", shotgun)
    if no_huddle is not None:
        bind("no_huddle = %(no_huddle)s", "no_huddle", no_huddle)

    def matches(r: dict[str, Any]) -> bool:
        if game_key is not None and r["game_key"] != game_key:
            return False
        if season is not None and r["season"] != season:
            return False
        if week is not None and r["week"] != week:
            return False
        if team is not None and r["team_label"] != team.upper():
            return False
        if player_key is not None and player_key not in (
            r["passer_player_key"],
            r["rusher_player_key"],
            r["receiver_player_key"],
        ):
            return False
        if down_bucket is not None and r["down_bucket"] != down_bucket:
            return False
        if distance_bucket is not None and r["distance_bucket"] != distance_bucket:
            return False
        if field_zone is not None and r["field_zone"] != field_zone:
            return False
        if script is not None and r["game_script"] != script:
            return False
        if play_family is not None and r["play_family"] != play_family:
            return False
        if shotgun is not None and r["shotgun"] != shotgun:
            return False
        return no_huddle is None or r["no_huddle"] == no_huddle

    rows, sql = source.select(
        profile,
        C.PLAY_LOG,
        COLUMNS,
        where=" and ".join(clauses),
        params=params,
        matches=matches,
        order=(
            "game_date",
            "game_key",
            "drive_number",
            "play_in_drive",
            "quarter",
            "clock_seconds_remaining desc",
            "play_key",
        ),
        tag="plays",
        limit=LIMIT + 1,
    )
    has_more = len(rows) > LIMIT
    rows = rows[:LIMIT]
    if not rows and game_key is not None:
        return None

    usage_rows: list[players.UsageRow] = []
    player_name: str | None = None
    usage_sql = ""
    if player_key is not None:
        for r in rows:
            for role_key, role_name in (
                ("passer_player_key", "passer_name"),
                ("rusher_player_key", "rusher_name"),
                ("receiver_player_key", "receiver_name"),
            ):
                if r[role_key] == player_key:
                    player_name = r[role_name]
                    break
            if player_name:
                break
        usage_season = season or profile.default_season
        u_rows, usage_sql = source.select(
            profile,
            C.PLAYER_SITUATION_USAGE,
            players.USAGE_COLUMNS,
            where=(
                "player_key = %(player)s and season = %(season)s"
                " and season_type_name = %(season_type_name)s"
            ),
            params={
                "player": player_key,
                "season": usage_season,
                "season_type_name": "Regular Season",
            },
            matches=lambda r: (
                r["player_key"] == player_key
                and r["season"] == usage_season
                and r["season_type_name"] == "Regular Season"
            ),
            order=("bucket_type", "bucket_order"),
            tag="plays_usage",
        )
        usage_rows = [players.UsageRow(**r) for r in u_rows]

    return PlaysPayload(
        sport=profile.key,
        season=season or (rows[0].get("season") if rows else profile.default_season) or profile.default_season,
        as_of=config.now(),
        rows=[PlayRow(**r) for r in rows],
        has_more=has_more,
        player_key=player_key,
        player_name=player_name,
        usage=usage_rows,
        query=f"{sql}\n\n{usage_sql}" if usage_sql else sql,
    )
