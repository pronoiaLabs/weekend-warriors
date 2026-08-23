"""Every table a profile points at has a schema fixture, and the columns a tile
reads exist in it. The fixture form runs in CI; the live form describes the real
tables and is the early warning for a dbt rename.

The column lists below are the contract tiles rely on. Add to them as tiles land;
a mart column that disappears upstream fails here before any page does.
"""

import os

import pytest

from app.sports import fixtures
from app.sports.capabilities import Capability as C
from app.sports.registry import PROFILES

REQUIRED: dict[str, set[str]] = {
    "app_game_slate": {
        "app_game_slate_key", "game_key", "season", "week", "season_type", "season_type_name",
        "game_date", "game_datetime_et", "kickoff_slot_et", "is_completed",
        "home_team_label", "home_team_name", "away_team_label", "away_team_name",
        "stadium_name", "roof", "is_weather_relevant",
        "kickoff_temp_f", "wind_mph", "precip_in",
        "vendor", "home_spread", "total_line", "home_spread_movement", "total_line_movement",
        "implied_home_team_total", "implied_away_team_total",
        "home_score", "away_score", "props_open", "news_mentions_7d",
    },
    "app_game_prop_board": {
        "app_game_prop_board_key", "game_key", "season", "week", "game_datetime_et", "is_completed",
        "player_key", "player_name", "position", "position_group",
        "team_label", "opponent_label", "is_home",
        "vendor", "prop_type", "market_type", "stat_key", "stat_label",
        "line_value", "opening_line_value", "line_movement", "over_odds", "under_odds", "market_odds",
        "trailing_games", "trailing_avg", "stat_last3", "trailing_over_line", "trailing_hit_rate",
        "gap_to_line", "games_played_to_date", "stat_avg_to_date", "hit_rate_over_line",
        "opponent_allowed_per_game", "opponent_allowed_rank", "opponent_allowed_teams_ranked",
        "news_headline", "news_context", "actual_value", "outcome",
    },
}


def _profile_tables() -> list[tuple[str, C, str]]:
    return [(p.key, cap, table) for p in PROFILES.values() for cap, table in p.tables.items()]


@pytest.mark.parametrize("sport,cap,table", _profile_tables())
def test_every_profile_table_has_a_schema_fixture(sport: str, cap: C, table: str) -> None:
    assert fixtures.schema(table) is not None, f"{sport} {cap}: no fixtures/app/schema/{table}.json"


@pytest.mark.parametrize("table,required", sorted(REQUIRED.items()))
def test_required_columns_exist_in_fixture_schema(table: str, required: set[str]) -> None:
    missing = required - fixtures.columns(table)
    assert not missing, f"{table} fixture schema lacks {sorted(missing)}"


@pytest.mark.live
@pytest.mark.parametrize("sport,cap,table", _profile_tables())
def test_required_columns_exist_live(sport: str, cap: C, table: str) -> None:
    assert os.environ.get("ANALYTICS_DASHBOARD_LIVE") == "1"
    from app import db

    profile = PROFILES[sport]
    rows = db.query(f"describe table {profile.fqn(cap)}", ttl=0, tag={"sport": sport, "tile": "contract"})
    live_cols = {r["name"].lower() for r in rows}
    missing = REQUIRED.get(table, set()) - live_cols
    assert not missing, f"{profile.fqn(cap)} lacks {sorted(missing)}"
