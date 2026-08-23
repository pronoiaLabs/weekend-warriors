"""Every table a profile points at has a schema fixture, and the columns a tile
reads exist in it. The fixture form runs in CI; the live form describes the real
tables and is the early warning for a dbt rename.

The contract is each tile's COLUMNS tuple (the columns its select names), so a
mart column that disappears upstream fails here before any page does, and a new
field on a row model is checked against the schema the moment it is added.
"""

import os

import pytest

from app.sports import fixtures
from app.sports.capabilities import Capability as C
from app.sports.registry import PROFILES
from app.sports.tiles import game_board, players, slate, teams

REQUIRED: dict[str, set[str]] = {
    "app_game_slate": set(slate.COLUMNS),
    "app_game_prop_board": set(game_board.COLUMNS),
    "app_team_standings": set(teams.STANDINGS_COLUMNS),
    "app_team_weeks": set(teams.WEEK_COLUMNS),
    "app_team_allowed": set(teams.ALLOWED_COLUMNS),
    "app_team_ats": set(teams.ATS_COLUMNS),
    "app_player_leaders": set(players.LEADERS_COLUMNS),
    "app_player_weeks": set(players.WEEK_COLUMNS),
    "app_player_week_stats": set(players.STAT_COLUMNS),
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
