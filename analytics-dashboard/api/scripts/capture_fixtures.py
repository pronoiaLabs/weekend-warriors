"""Record rows from a dev build of the APP marts into fixtures/app/<sport>/<table>.json,
and each mart's DESCRIBE TABLE into fixtures/app/schema/<table>.json (the column
contract the tiles are tested against).

Goes through app.db.query, so the fixtures have exactly the shape live tiles see
(lowercase keys, Decimal and timestamp values serialised here). Point the sport at
the dev build and use a role that can read it:

    cd analytics-dashboard/api
    ANALYTICS_DASHBOARD_ROLE=SYSADMIN ANALYTICS_DASHBOARD_WAREHOUSE=DEVELOPMENT_WH \
    NFL_APP_DB=NFL_DEV_DB NFL_APP_SCHEMA=DEV_<user> \
      uv run python scripts/capture_fixtures.py nfl

The selection per table is deliberate and small: enough weeks to exercise every
branch a page has (an upcoming week with lines, a second week for the picker, a
preseason week that is partly played, a completed week with scores), not a copy
of the mart. Rerun after a mart change and commit the result.
"""

import datetime as dt
import decimal
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import db
from app.sports.capabilities import Capability as C
from app.sports.fixtures import FIXTURES
from app.sports.registry import PROFILES

SELECTION: dict[str, dict[C, str]] = {
    "nfl": {
        C.SCHEDULE: (
            "(season = 2026 and season_type_name = 'Regular Season' and week in (1, 2))"
            " or (season = 2026 and season_type_name = 'Preseason' and week = 3)"
            " or (season = 2025 and season_type_name = 'Regular Season' and week = 18)"
        ),
        C.GAME_PROP_BOARD: "season = 2026",
        # a completed season with every split, and the season in progress
        C.TEAM_STANDINGS: "season in (2025, 2026)",
        # two teams' seasons: no 2025 lines (the odds feed starts in 2026), so the
        # vendor collapse is exercised by a unit test rather than by these rows
        C.TEAM_WEEKS: "season in (2025, 2026) and team_label in ('KC', 'DET')",
        C.TEAM_ALLOWED: "season in (2025, 2026) and team_label in ('KC', 'DET')",
        C.TEAM_ATS: "season in (2025, 2026)",
        # a completed season's regulars at the four skill positions (the
        # leaderboard), the skill positions in the season in progress, and the
        # two sample players' every season (the player page's career table)
        C.PLAYER_LEADERS: (
            "(season = 2025 and season_type_name = 'Regular Season'"
            " and position in ('QB', 'RB', 'WR', 'TE') and games >= 8)"
            " or (season = 2026 and position in ('QB', 'RB', 'WR', 'TE') and games >= 3)"
            " or player_name in ('Puka Nacua', 'Patrick Mahomes')"
        ),
        # two players' seasons, 2024 included so the prior-season columns on
        # their 2025 rows have something behind them in the same fixture set
        C.PLAYER_WEEKS: "season in (2024, 2025, 2026) and player_name in ('Puka Nacua', 'Patrick Mahomes')",
        C.PLAYER_WEEK_STATS: "season in (2025, 2026) and player_name in ('Puka Nacua', 'Patrick Mahomes')",
        # the defender sheet is Explorer-only; a small sample keeps the table shape
        C.PLAYER_DEFENSE_WEEKS: "season = 2025 and season_type_name = 'Regular Season' and team_label = 'KC' and week = 1",
        # two lined weeks (every book in week 1, fewer in week 2)
        C.LINE_HISTORY: "season = 2026 and week in (1, 2)",
        # DraftKings' week 1 props, and FanDuel's QB props for one game: FanDuel
        # re-snapshots every tick, so one full game at that book is 3,000 rows
        C.PROP_LINE_HISTORY: (
            "season = 2026 and week = 1 and (vendor = 'draftkings'"
            " or (vendor = 'fanduel' and game_key = '56776ceb2af5a3b9fcfe711da4f84c05'"
            " and position = 'QB'))"
        ),
        # every mention; the feeds began on 2026-08-20
        C.NEWS: "published_date >= '2026-08-01'",
    },
}


def _json_default(value: object) -> object:
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, dt.datetime | dt.date):
        return value.isoformat()
    raise TypeError(f"unserialisable {type(value).__name__}")


def main(sport: str) -> None:
    profile = PROFILES[sport]
    for cap, where in SELECTION[sport].items():
        table = profile.tables[cap]
        fqn = profile.fqn(cap)
        rows = db.query(
            f"select * from {fqn} where {where}",
            ttl=0,
            tag={"sport": sport, "tile": "capture"},
        )
        out = FIXTURES / sport / f"{table}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        # one row per line: diffable, and a third of the size of indented JSON
        head = json.dumps({"table": table, "captured_from": fqn, "where": where})[:-1]
        body = ",\n".join(json.dumps(r, default=_json_default, separators=(",", ":")) for r in rows)
        out.write_text(f'{head}, "rows": [\n{body}\n]}}\n')
        print(f"{out.relative_to(FIXTURES.parents[1])}: {len(rows)} rows from {fqn}")
        write_schema(sport, table, fqn)


def write_schema(sport: str, table: str, fqn: str) -> None:
    """DESCRIBE TABLE as the contract test reads it. The source is named by
    database only: the dev schema carries a username and the file is public."""
    described = db.query(f"describe table {fqn}", ttl=0, tag={"sport": sport, "tile": "capture"})
    db_name = fqn.split(".")[0]
    spec = {
        "table": table,
        "captured_from": f"{db_name}.DEV_<user> dev build",
        "columns": [
            {"name": r["name"].lower(), "type": r["type"], "nullable": r["null?"] == "Y"}
            for r in described
        ],
    }
    out = FIXTURES / "schema" / f"{table}.json"
    out.write_text(json.dumps(spec, indent=2) + "\n")
    print(f"{out.relative_to(FIXTURES.parents[1])}: {len(spec['columns'])} columns")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "nfl")
