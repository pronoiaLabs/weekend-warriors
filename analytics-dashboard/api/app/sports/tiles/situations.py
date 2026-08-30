"""The game page's situations tab: what each unit does, and allows, in the
situations that decide games.

Two selects. The first resolves the game on the slate (its teams, season and
season type); the second reads app_team_situation for both teams in one bound
query -- the mart's `side` column already carries both readings (a defense row
IS the allowed reading), so pairing an offense with the opposing defense in the
same situation is a client-side zip, no aggregation here. The rows come back
split four ways (home/away x offense/defense), each ordered by situation_order.

A postseason game reads the REGULAR SEASON splits -- the same convention as the
slate's records column (a playoff team is "12-5"), and the postseason sample
would be a handful of games. Preseason has no play-by-play, so a preseason
game's panel is honestly empty.
"""

import datetime as dt

from pydantic import BaseModel

from app import config
from app.sports import source
from app.sports.capabilities import Capability
from app.sports.profile import SportProfile
from app.sports.tiles import slate

CAP = Capability.TEAM_SITUATION

GAME_COLUMNS: tuple[str, ...] = (
    "game_key",
    "season",
    "season_type_name",
    "week",
    "is_completed",
    "home_team_key",
    "home_team_label",
    "away_team_key",
    "away_team_label",
)


class SituationRow(BaseModel):
    app_team_situation_key: str
    team_key: str
    team_label: str
    team_name: str | None = None
    season: int
    season_type: int
    season_type_name: str
    side: str
    situation_group: str
    situation_key: str
    situation_label: str
    situation_order: int
    plays: int
    epa_per_play: float | None = None
    success_rate: float | None = None
    explosive_rate: float | None = None
    league_epa_per_play: float | None = None
    epa_vs_league: float | None = None
    league_success_rate: float | None = None
    success_rate_vs_league: float | None = None
    situation_rank: int | None = None
    teams_ranked: int | None = None


COLUMNS: tuple[str, ...] = tuple(SituationRow.model_fields)


class GameSituationsPayload(BaseModel):
    sport: str
    season: int
    as_of: dt.datetime
    game_key: str
    season_type_name: str
    situation_season_type_name: str
    home_team_key: str
    home_team_label: str
    away_team_key: str
    away_team_label: str
    home_offense: list[SituationRow]
    home_defense: list[SituationRow]
    away_offense: list[SituationRow]
    away_defense: list[SituationRow]
    query: str | None = None


def load(profile: SportProfile, game_key: str) -> GameSituationsPayload | None:
    """Both teams' situation splits for one game. None when the game is unknown."""
    game_rows, game_sql = source.select(
        profile,
        slate.CAP,
        GAME_COLUMNS,
        where="game_key = %(game_key)s",
        params={"game_key": game_key},
        matches=lambda r: r["game_key"] == game_key,
        order=("game_key",),
        limit=1,
        tag="situations_game",
    )
    if not game_rows:
        return None
    game = game_rows[0]

    # a playoff game reads the regular-season splits (the "12-5" convention)
    season_type_name = game["season_type_name"]
    if season_type_name == "Postseason":
        season_type_name = "Regular Season"

    params = {
        "season": game["season"],
        "season_type_name": season_type_name,
        "home": game["home_team_key"],
        "away": game["away_team_key"],
    }
    rows, sql = source.select(
        profile,
        CAP,
        COLUMNS,
        where=(
            "season = %(season)s and season_type_name = %(season_type_name)s"
            " and team_key in (%(home)s, %(away)s)"
        ),
        params=params,
        matches=lambda r: (
            r["season"] == game["season"]
            and r["season_type_name"] == season_type_name
            and r["team_key"] in (game["home_team_key"], game["away_team_key"])
        ),
        order=("team_key", "side", "situation_order"),
        tag="situations",
    )

    def pick(team_key: str, side: str) -> list[SituationRow]:
        return [
            SituationRow(**r)
            for r in rows
            if r["team_key"] == team_key and r["side"] == side
        ]

    return GameSituationsPayload(
        sport=profile.key,
        season=game["season"],
        as_of=config.now(),
        game_key=game_key,
        season_type_name=game["season_type_name"],
        situation_season_type_name=season_type_name,
        home_team_key=game["home_team_key"],
        home_team_label=game["home_team_label"],
        away_team_key=game["away_team_key"],
        away_team_label=game["away_team_label"],
        home_offense=pick(game["home_team_key"], "offense"),
        home_defense=pick(game["home_team_key"], "defense"),
        away_offense=pick(game["away_team_key"], "offense"),
        away_defense=pick(game["away_team_key"], "defense"),
        query=game_sql + "\n\n" + sql,
    )
